defmodule Twelvgaige.Tool.Idempotency do
  @moduledoc """
  Idempotency metadata for tool retry and reconciliation decisions.

  Read-only tools can be retried freely. Write-capable tools must describe
  whether they require an idempotency key and how a caller can reconcile an
  ambiguous result.
  """

  @classes [:read_only, :idempotent, :non_idempotent]
  @reconciliation_strategies [:none, :read_after_write, :external_id, :manual]
  @side_effect_phases [:none, :before_result, :after_result, :unknown]

  @type class :: :read_only | :idempotent | :non_idempotent
  @type reconciliation_strategy :: :none | :read_after_write | :external_id | :manual
  @type side_effect_phase :: :none | :before_result | :after_result | :unknown

  @type t :: %__MODULE__{
          class: class(),
          requires_key?: boolean(),
          reconciliation_strategy: reconciliation_strategy(),
          side_effect_phase: side_effect_phase()
        }

  @enforce_keys [:class, :requires_key?, :reconciliation_strategy, :side_effect_phase]
  defstruct [:class, :requires_key?, :reconciliation_strategy, :side_effect_phase]

  @spec classes() :: [class()]
  def classes, do: @classes

  @spec reconciliation_strategies() :: [reconciliation_strategy()]
  def reconciliation_strategies, do: @reconciliation_strategies

  @spec side_effect_phases() :: [side_effect_phase()]
  def side_effect_phases, do: @side_effect_phases

  @spec read_only() :: t()
  def read_only do
    %__MODULE__{
      class: :read_only,
      requires_key?: false,
      reconciliation_strategy: :none,
      side_effect_phase: :none
    }
  end

  @spec idempotent(keyword()) :: t()
  def idempotent(opts \\ []) do
    new(:idempotent,
      requires_key?: Keyword.get(opts, :requires_key?, false),
      reconciliation_strategy: Keyword.get(opts, :reconciliation_strategy, :read_after_write),
      side_effect_phase: Keyword.get(opts, :side_effect_phase, :unknown)
    )
  end

  @spec non_idempotent(keyword()) :: t()
  def non_idempotent(opts \\ []) do
    new(:non_idempotent,
      requires_key?: Keyword.get(opts, :requires_key?, false),
      reconciliation_strategy: Keyword.get(opts, :reconciliation_strategy, :manual),
      side_effect_phase: Keyword.get(opts, :side_effect_phase, :unknown)
    )
  end

  @spec new(class(), keyword()) :: t()
  def new(class, opts) when class in @classes do
    reconciliation_strategy = Keyword.fetch!(opts, :reconciliation_strategy)
    side_effect_phase = Keyword.fetch!(opts, :side_effect_phase)

    unless reconciliation_strategy in @reconciliation_strategies do
      raise ArgumentError,
            "unknown idempotency reconciliation strategy: #{inspect(reconciliation_strategy)}"
    end

    unless side_effect_phase in @side_effect_phases do
      raise ArgumentError, "unknown idempotency side effect phase: #{inspect(side_effect_phase)}"
    end

    %__MODULE__{
      class: class,
      requires_key?: Keyword.get(opts, :requires_key?, false),
      reconciliation_strategy: reconciliation_strategy,
      side_effect_phase: side_effect_phase
    }
  end

  @spec retryable_without_key?(t()) :: boolean()
  def retryable_without_key?(%__MODULE__{class: :read_only}), do: true

  def retryable_without_key?(%__MODULE__{class: :idempotent, requires_key?: requires_key?}) do
    not requires_key?
  end

  def retryable_without_key?(%__MODULE__{class: :non_idempotent}), do: false
end
