defmodule Twelvgaige.Manager.CompiledPlan do
  @moduledoc "Immutable manager plan after registry, policy, DAG, and aggregate-budget validation."

  @enforce_keys [:plan, :digest, :tasks, :reserved_budget, :compiled_at]
  defstruct [
    :plan,
    :digest,
    :tasks,
    :reserved_budget,
    :compiled_at,
    approval_status: :within_envelope
  ]
end
