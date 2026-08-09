defmodule Twelvgaige.Manager.Budget do
  @moduledoc "Typed aggregate limits and usage arithmetic for a manager tree."

  @dimensions [:tokens, :cost_micros, :time_ms, :tool_calls]
  @enforce_keys @dimensions
  defstruct @dimensions

  @type t :: %__MODULE__{
          tokens: non_neg_integer(),
          cost_micros: non_neg_integer(),
          time_ms: non_neg_integer(),
          tool_calls: non_neg_integer()
        }

  def new(%__MODULE__{} = budget), do: {:ok, budget}

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, tokens} <- dimension(attrs, :tokens),
         {:ok, cost} <- dimension(attrs, :cost_micros),
         {:ok, time} <- time_dimension(attrs),
         {:ok, tools} <- dimension(attrs, :tool_calls) do
      {:ok, %__MODULE__{tokens: tokens, cost_micros: cost, time_ms: time, tool_calls: tools}}
    end
  end

  def new(_attrs), do: {:error, :manager_budget_invalid}

  def zero, do: %__MODULE__{tokens: 0, cost_micros: 0, time_ms: 0, tool_calls: 0}

  def add(%__MODULE__{} = left, %__MODULE__{} = right) do
    struct!(__MODULE__, Map.new(@dimensions, &{&1, Map.fetch!(left, &1) + Map.fetch!(right, &1)}))
  end

  def sum(budgets), do: Enum.reduce(budgets, zero(), &add/2)

  def within?(%__MODULE__{} = requested, %__MODULE__{} = limit),
    do: Enum.all?(@dimensions, &(Map.fetch!(requested, &1) <= Map.fetch!(limit, &1)))

  def exceeded(%__MODULE__{} = requested, %__MODULE__{} = limit),
    do: Enum.filter(@dimensions, &(Map.fetch!(requested, &1) > Map.fetch!(limit, &1)))

  def remaining(%__MODULE__{} = limit, %__MODULE__{} = used) do
    struct!(
      __MODULE__,
      Map.new(@dimensions, &{&1, max(Map.fetch!(limit, &1) - Map.fetch!(used, &1), 0)})
    )
  end

  defp dimension(attrs, key) do
    value = value(attrs, key, 0)

    if is_integer(value) and value >= 0,
      do: {:ok, value},
      else: {:error, {:manager_budget_invalid, key}}
  end

  defp time_dimension(attrs) do
    case value(attrs, :time_ms, value(attrs, :time, 0)) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      value when is_binary(value) -> parse_duration(value)
      _value -> {:error, {:manager_budget_invalid, :time_ms}}
    end
  end

  defp parse_duration(value) do
    case Regex.run(~r/^(\d+)(ms|s|m|h)$/, value, capture: :all_but_first) do
      [amount, unit] ->
        multiplier = %{"ms" => 1, "s" => 1_000, "m" => 60_000, "h" => 3_600_000}[unit]
        {:ok, String.to_integer(amount) * multiplier}

      _other ->
        {:error, {:manager_budget_invalid, :time_ms}}
    end
  end

  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
