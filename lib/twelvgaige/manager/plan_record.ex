defmodule Twelvgaige.Manager.PlanRecord do
  @moduledoc "Durable scheduler state and aggregate accounting for one compiled manager plan."

  alias Twelvgaige.Manager.Budget

  @enforce_keys [:id, :compiled_plan, :reserved_budget, :created_at]
  defstruct [
    :id,
    :compiled_plan,
    :reserved_budget,
    :allocated_budget,
    :reservation_lease,
    :created_at,
    :updated_at,
    :cancelled_at,
    :error,
    status: :queued,
    usage: Budget.zero(),
    disagreement_count: 0,
    repair_attempts: 0,
    version: 0,
    schema_version: 1,
    encoding_version: 1
  ]

  def new(compiled, attrs \\ %{}) do
    %__MODULE__{
      id: compiled.plan.id,
      compiled_plan: compiled,
      reserved_budget: compiled.plan.budget,
      allocated_budget: compiled.reserved_budget,
      reservation_lease: value(attrs, :reservation_lease, nil),
      created_at: value(attrs, :created_at, DateTime.utc_now())
    }
  end

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
