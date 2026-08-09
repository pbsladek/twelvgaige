defmodule Twelvgaige.Operations.ProviderLimiter do
  @moduledoc "Durable provider RPM, TPM, cost, cooldown, and Retry-After control."

  use GenServer

  alias Twelvgaige.Operations.Store

  defstruct [:store, :now_fun, :limits, buckets: %{}]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, opts),
      else: GenServer.start_link(__MODULE__, opts, name: name)
  end

  def acquire(provider, account, requested_tokens, estimated_cost_micros, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:acquire, to_string(provider), to_string(account), requested_tokens, estimated_cost_micros}
    )
  end

  def complete(permit, usage, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:complete, permit, usage})
  end

  def observe_response(provider, account, response, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:observe_response, to_string(provider), to_string(account), response}
    )
  end

  def status(opts \\ []), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :status)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      store: Keyword.get(opts, :store, Store),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      limits: normalize_limits(Keyword.get(opts, :limits, %{}))
    }

    {:ok, load(state)}
  end

  @impl true
  def handle_call({:acquire, provider, account, tokens, cost}, _from, state) do
    key = {provider, account}
    now = state.now_fun.()

    with :ok <- validate_amounts(tokens, cost) do
      bucket = state.buckets |> Map.get(key, new_bucket(now)) |> advance_windows(now)
      limits = limits_for(state.limits, key)

      case admission(bucket, limits, tokens, cost, now) do
        :ok ->
          permit_id =
            "permit_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))

          permit = %{
            id: permit_id,
            provider: provider,
            account: account,
            reserved_tokens: tokens,
            reserved_cost_micros: cost,
            admitted_at: now
          }

          bucket = %{
            bucket
            | requests: bucket.requests + 1,
              tokens: bucket.tokens + tokens,
              day_cost_micros: bucket.day_cost_micros + cost,
              permits: Map.put(bucket.permits, permit_id, permit)
          }

          state = put_bucket(state, key, bucket)
          {:reply, {:ok, permit}, state}

        {:wait, reason, retry_after_ms} ->
          bucket = %{bucket | denials: bucket.denials + 1, last_denial: reason}
          state = put_bucket(state, key, bucket)
          {:reply, {:wait, %{reason: reason, retry_after_ms: retry_after_ms}}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:complete, permit, usage}, _from, state) do
    key = {permit.provider, permit.account}

    reply =
      case Map.fetch(state.buckets, key) do
        {:ok, bucket} ->
          case Map.pop(bucket.permits, permit.id) do
            {nil, _permits} ->
              {:error, :provider_permit_not_found}

            {stored, permits} ->
              actual_tokens = amount(usage, :tokens, stored.reserved_tokens)
              actual_cost = amount(usage, :cost_micros, stored.reserved_cost_micros)

              if actual_tokens >= 0 and actual_cost >= 0 do
                bucket = %{
                  bucket
                  | tokens: max(0, bucket.tokens - stored.reserved_tokens + actual_tokens),
                    day_cost_micros:
                      max(0, bucket.day_cost_micros - stored.reserved_cost_micros + actual_cost),
                    permits: permits
                }

                {:ok, put_bucket(state, key, bucket)}
              else
                {:error, :provider_usage_invalid}
              end
          end

        :error ->
          {:error, :provider_permit_not_found}
      end

    case reply do
      {:ok, next} -> {:reply, :ok, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:observe_response, provider, account, response}, _from, state) do
    key = {provider, account}
    now = state.now_fun.()
    status = amount(response, :status, 0)
    headers = value(response, :headers, %{})

    if status in [429, 503] do
      retry_after_ms = retry_after_ms(headers, now)
      fallback_ms = limits_for(state.limits, key).cooldown_ms
      cooldown_ms = retry_after_ms || fallback_ms
      bucket = state.buckets |> Map.get(key, new_bucket(now)) |> advance_windows(now)

      bucket = %{
        bucket
        | cooldown_until: DateTime.add(now, cooldown_ms, :millisecond),
          last_retry_after_ms: retry_after_ms,
          last_response_status: status
      }

      {:reply, {:ok, %{cooldown_ms: cooldown_ms, source: retry_source(retry_after_ms)}},
       put_bucket(state, key, bucket)}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:status, _from, state) do
    now = state.now_fun.()

    buckets =
      state.buckets
      |> Enum.map(fn {{provider, account}, bucket} ->
        bucket = advance_windows(bucket, now)
        limits = limits_for(state.limits, {provider, account})

        %{
          provider: provider,
          account: account,
          requests: bucket.requests,
          rpm_limit: limits.rpm,
          tokens: bucket.tokens,
          tpm_limit: limits.tpm,
          day_cost_micros: bucket.day_cost_micros,
          daily_cost_limit_micros: limits.daily_cost_micros,
          cooldown_until: bucket.cooldown_until,
          retry_after_ms: cooldown_remaining(bucket, now),
          pending_permits: map_size(bucket.permits),
          denials: bucket.denials,
          last_denial: bucket.last_denial,
          last_response_status: bucket.last_response_status
        }
      end)
      |> Enum.sort_by(&{&1.provider, &1.account})

    {:reply, %{providers: buckets}, state}
  end

  defp admission(bucket, limits, tokens, cost, now) do
    cond do
      cooldown_remaining(bucket, now) > 0 ->
        {:wait, :provider_cooldown, cooldown_remaining(bucket, now)}

      finite?(limits.rpm) and bucket.requests + 1 > limits.rpm ->
        {:wait, :provider_rpm_exhausted, window_remaining(bucket.minute_started_at, 60, now)}

      finite?(limits.tpm) and bucket.tokens + tokens > limits.tpm ->
        {:wait, :provider_tpm_exhausted, window_remaining(bucket.minute_started_at, 60, now)}

      finite?(limits.daily_cost_micros) and
          bucket.day_cost_micros + cost > limits.daily_cost_micros ->
        {:wait, :provider_cost_exhausted, window_remaining(bucket.day_started_at, 86_400, now)}

      true ->
        :ok
    end
  end

  defp normalize_limits(limits) when is_map(limits) do
    Map.new(limits, fn {key, config} -> {normalize_key(key), normalize_limit(config)} end)
  end

  defp normalize_key({provider, account}), do: {to_string(provider), to_string(account)}
  defp normalize_key(provider), do: {to_string(provider), "*"}

  defp normalize_limit(config) do
    %{
      rpm: positive_or_infinity(value(config, :rpm, :infinity)),
      tpm: positive_or_infinity(value(config, :tpm, :infinity)),
      daily_cost_micros: positive_or_infinity(value(config, :daily_cost_micros, :infinity)),
      cooldown_ms: positive(value(config, :cooldown_ms, 30_000))
    }
  end

  defp limits_for(limits, {provider, account}) do
    Map.get(limits, {provider, account}) || Map.get(limits, {provider, "*"}) ||
      normalize_limit(%{})
  end

  defp new_bucket(now) do
    %{
      minute_started_at: truncate_minute(now),
      day_started_at: truncate_day(now),
      requests: 0,
      tokens: 0,
      day_cost_micros: 0,
      cooldown_until: nil,
      permits: %{},
      denials: 0,
      last_denial: nil,
      last_retry_after_ms: nil,
      last_response_status: nil
    }
  end

  defp advance_windows(bucket, now) do
    bucket =
      if DateTime.diff(now, bucket.minute_started_at, :second) >= 60 do
        %{bucket | minute_started_at: truncate_minute(now), requests: 0, tokens: 0, permits: %{}}
      else
        bucket
      end

    if DateTime.diff(now, bucket.day_started_at, :second) >= 86_400 do
      %{bucket | day_started_at: truncate_day(now), day_cost_micros: 0}
    else
      bucket
    end
  end

  defp put_bucket(state, {provider, account} = key, bucket) do
    :ok =
      Store.put(:provider_rate, provider <> ":" <> account, bucket,
        server: state.store,
        retention_class: :security
      )

    %{state | buckets: Map.put(state.buckets, key, bucket)}
  end

  defp load(state) do
    case Store.list(:provider_rate, server: state.store) do
      {:ok, records} ->
        buckets =
          Map.new(records, fn record ->
            [provider, account] = String.split(record.key, ":", parts: 2)
            {{provider, account}, record.value}
          end)

        %{state | buckets: buckets}

      {:error, _reason} ->
        state
    end
  end

  defp retry_after_ms(headers, now) do
    value = header(headers, "retry-after")

    cond do
      is_integer(value) and value >= 0 -> value * 1_000
      is_binary(value) -> parse_retry_after(value, now)
      true -> nil
    end
  end

  defp parse_retry_after(value, now) do
    case Integer.parse(String.trim(value)) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _other -> parse_http_date(value, now)
    end
  end

  defp parse_http_date(value, now) do
    value
    |> String.to_charlist()
    |> then(&apply(:httpd_util, :convert_request_date, [&1]))
    |> case do
      :bad_date ->
        nil

      datetime ->
        retry = datetime |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")
        max(0, DateTime.diff(retry, now, :millisecond))
    end
  rescue
    _error -> nil
  end

  defp header(headers, name) when is_map(headers) do
    Enum.find_value(headers, fn {key, value} ->
      if key |> to_string() |> String.downcase() == name, do: value
    end)
  end

  defp header(headers, name) when is_list(headers), do: header(Map.new(headers), name)
  defp header(_headers, _name), do: nil

  defp cooldown_remaining(%{cooldown_until: nil}, _now), do: 0

  defp cooldown_remaining(bucket, now),
    do: max(0, DateTime.diff(bucket.cooldown_until, now, :millisecond))

  defp window_remaining(started_at, seconds, now) do
    max(0, seconds * 1_000 - DateTime.diff(now, started_at, :millisecond))
  end

  defp truncate_minute(now), do: DateTime.from_unix!(div(DateTime.to_unix(now), 60) * 60)
  defp truncate_day(now), do: DateTime.from_unix!(div(DateTime.to_unix(now), 86_400) * 86_400)
  defp retry_source(nil), do: :configured_cooldown
  defp retry_source(_retry_after_ms), do: :retry_after
  defp finite?(:infinity), do: false
  defp finite?(value), do: is_integer(value)

  defp validate_amounts(tokens, cost)
       when is_integer(tokens) and tokens >= 0 and is_integer(cost) and cost >= 0,
       do: :ok

  defp validate_amounts(_tokens, _cost), do: {:error, :provider_reservation_invalid}
  defp positive_or_infinity(:infinity), do: :infinity
  defp positive_or_infinity(value), do: positive(value)
  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: raise(ArgumentError, "provider limits must be positive")

  defp amount(map, key, default), do: value(map, key, default)
  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
