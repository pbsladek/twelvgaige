defmodule Twelvgaige.Scheduler.Cron do
  @moduledoc """
  Small five-field cron parser for local scheduler jobs.

  This intentionally supports the portable subset Twelvgaige needs for daemon
  jobs: `*`, numbers, comma lists, inclusive ranges, and stepped ranges such as
  `*/15` or `9-17/2`. Seconds are not supported; schedules fire on minute
  boundaries in UTC.
  """

  alias Twelvgaige.Error

  @max_search_minutes 366 * 24 * 60

  @type t :: %__MODULE__{
          expression: String.t(),
          minutes: MapSet.t(non_neg_integer()),
          hours: MapSet.t(non_neg_integer()),
          days: MapSet.t(pos_integer()),
          months: MapSet.t(pos_integer()),
          weekdays: MapSet.t(non_neg_integer()),
          day_wildcard?: boolean(),
          weekday_wildcard?: boolean()
        }

  @enforce_keys [
    :expression,
    :minutes,
    :hours,
    :days,
    :months,
    :weekdays,
    :day_wildcard?,
    :weekday_wildcard?
  ]
  defstruct @enforce_keys

  @spec parse(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def parse(expression) when is_binary(expression) do
    fields = String.split(expression, ~r/\s+/, trim: true)

    with [minute, hour, day, month, weekday] <- fields,
         {:ok, minutes, _minute_wildcard?} <- parse_field(minute, 0..59, :minute),
         {:ok, hours, _hour_wildcard?} <- parse_field(hour, 0..23, :hour),
         {:ok, days, day_wildcard?} <- parse_field(day, 1..31, :day),
         {:ok, months, _month_wildcard?} <- parse_field(month, 1..12, :month),
         {:ok, weekdays, weekday_wildcard?} <- parse_field(weekday, 0..7, :weekday) do
      {:ok,
       %__MODULE__{
         expression: expression,
         minutes: minutes,
         hours: hours,
         days: days,
         months: months,
         weekdays: normalize_weekdays(weekdays),
         day_wildcard?: day_wildcard?,
         weekday_wildcard?: weekday_wildcard?
       }}
    else
      {:error, _reason} = error ->
        error

      [_one, _two, _three, _four, _five | _extra] ->
        {:error, cron_error("cron expression must have exactly five fields")}

      _not_five_fields ->
        {:error, cron_error("cron expression must have exactly five fields")}
    end
  end

  def parse(_expression), do: {:error, cron_error("cron expression must be a string")}

  @spec next_delay_ms(t(), DateTime.t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def next_delay_ms(%__MODULE__{} = cron, %DateTime{} = now) do
    with {:ok, next_run} <- next_run_after(cron, now) do
      delay =
        next_run
        |> DateTime.to_unix(:millisecond)
        |> Kernel.-(DateTime.to_unix(now, :millisecond))
        |> max(0)

      {:ok, delay}
    end
  end

  @spec next_run_after(t(), DateTime.t()) :: {:ok, DateTime.t()} | {:error, Error.t()}
  def next_run_after(%__MODULE__{} = cron, %DateTime{} = now) do
    now
    |> next_minute()
    |> find_next_run(cron, @max_search_minutes)
  end

  defp find_next_run(_candidate, _cron, 0) do
    {:error, cron_error("cron expression has no matching time within one year")}
  end

  defp find_next_run(candidate, cron, remaining) do
    if matches?(cron, candidate) do
      {:ok, candidate}
    else
      candidate
      |> DateTime.add(60, :second)
      |> find_next_run(cron, remaining - 1)
    end
  end

  defp matches?(cron, %DateTime{} = candidate) do
    date = DateTime.to_date(candidate)
    weekday = cron_weekday(date)

    MapSet.member?(cron.minutes, candidate.minute) and
      MapSet.member?(cron.hours, candidate.hour) and
      MapSet.member?(cron.months, candidate.month) and
      day_matches?(cron, date.day, weekday)
  end

  defp day_matches?(cron, day, weekday) do
    day_match? = MapSet.member?(cron.days, day)
    weekday_match? = MapSet.member?(cron.weekdays, weekday)

    cond do
      cron.day_wildcard? and cron.weekday_wildcard? -> true
      cron.day_wildcard? -> weekday_match?
      cron.weekday_wildcard? -> day_match?
      true -> day_match? or weekday_match?
    end
  end

  defp next_minute(%DateTime{} = now) do
    next_ms = div(DateTime.to_unix(now, :millisecond), 60_000) * 60_000 + 60_000
    DateTime.from_unix!(next_ms, :millisecond)
  end

  defp parse_field("*", range, _field), do: {:ok, MapSet.new(range), true}

  defp parse_field(field, range, field_name) do
    field
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, MapSet.new()}, fn part, {:ok, acc} ->
      case parse_part(part, range, field_name) do
        {:ok, values} -> {:cont, {:ok, MapSet.union(acc, values)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} ->
        if MapSet.size(values) > 0 do
          {:ok, values, false}
        else
          {:error, cron_error("cron #{field_name} field is empty")}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_part(part, range, field_name) do
    case String.split(part, "/", parts: 2) do
      [base] ->
        parse_base(base, range, field_name)

      [base, step] ->
        with {:ok, step} <- parse_step(step, field_name),
             {:ok, values} <- parse_base(base, range, field_name) do
          values
          |> Enum.sort()
          |> Enum.take_every(step)
          |> MapSet.new()
          |> then(&{:ok, &1})
        end
    end
  end

  defp parse_base("*", range, _field_name), do: {:ok, MapSet.new(range)}

  defp parse_base(base, range, field_name) do
    case String.split(base, "-", parts: 2) do
      [number] ->
        with {:ok, value} <- parse_number(number, range, field_name) do
          {:ok, MapSet.new([value])}
        end

      [left, right] ->
        with {:ok, left} <- parse_number(left, range, field_name),
             {:ok, right} <- parse_number(right, range, field_name),
             true <- left <= right do
          {:ok, MapSet.new(left..right)}
        else
          false -> {:error, cron_error("cron #{field_name} range must be ascending")}
          {:error, _reason} = error -> error
        end
    end
  end

  defp parse_step(step, field_name) do
    case Integer.parse(step) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, cron_error("cron #{field_name} step must be positive")}
    end
  end

  defp parse_number(number, range, field_name) do
    case Integer.parse(number) do
      {integer, ""} ->
        if integer in range do
          {:ok, integer}
        else
          {:error, cron_error("cron #{field_name} value out of range")}
        end

      _other ->
        {:error, cron_error("cron #{field_name} value must be an integer")}
    end
  end

  defp normalize_weekdays(weekdays) do
    weekdays
    |> Enum.map(fn
      7 -> 0
      weekday -> weekday
    end)
    |> MapSet.new()
  end

  defp cron_weekday(date) do
    case Date.day_of_week(date) do
      7 -> 0
      weekday -> weekday
    end
  end

  defp cron_error(message) do
    Error.new(:input_error, :invalid_shell, message)
  end
end
