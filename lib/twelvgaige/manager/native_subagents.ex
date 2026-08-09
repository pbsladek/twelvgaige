defmodule Twelvgaige.Manager.NativeSubagents do
  @moduledoc "Observes runtime-native subagents while enforcing that they remain inside the parent boundary."

  alias Twelvgaige.Manager.Budget

  @enforce_keys [
    :id,
    :parent_session_id,
    :runtime_id,
    :workspace_id,
    :sandbox_resource_id,
    :auth_profile_id,
    :budget,
    :deadline
  ]
  defstruct [
    :id,
    :parent_session_id,
    :runtime_id,
    :workspace_id,
    :sandbox_resource_id,
    :auth_profile_id,
    :budget,
    :deadline,
    capabilities: [],
    usage: Budget.zero(),
    status: :observed
  ]

  def admit(parent, proposal) when is_map(parent) and is_map(proposal) do
    with {:ok, budget} <- Budget.new(value(proposal, :budget, %{})),
         {:ok, usage} <- Budget.new(value(proposal, :usage, %{})),
         {:ok, parent_budget} <- Budget.new(value(parent, :budget, %{})) do
      reasons =
        []
        |> required_identity(parent, :session_id)
        |> required_identity(proposal, :runtime_id)
        |> mismatch(parent, proposal, :workspace_id)
        |> mismatch(parent, proposal, :sandbox_resource_id)
        |> mismatch(parent, proposal, :auth_profile_id)
        |> subset(parent, proposal, :capabilities)
        |> budget_reason(budget, parent_budget)
        |> usage_reason(usage, budget, parent_budget)
        |> deadline_reason(value(proposal, :deadline), value(parent, :deadline))

      if reasons == [] do
        {:ok,
         %__MODULE__{
           id: Twelvgaige.ID.new(:manager_child),
           parent_session_id: value(parent, :session_id),
           runtime_id: value(proposal, :runtime_id),
           workspace_id: value(proposal, :workspace_id),
           sandbox_resource_id: value(proposal, :sandbox_resource_id),
           auth_profile_id: value(proposal, :auth_profile_id),
           capabilities: value(proposal, :capabilities, []),
           budget: budget,
           usage: usage,
           deadline: value(proposal, :deadline)
         }}
      else
        {:error, {:twelvgaige_child_required, Enum.sort(reasons)}}
      end
    end
  end

  @doc "Adds observed native-subagent usage while enforcing its inherited budget."
  def observe_usage(%__MODULE__{} = native, delta) do
    with {:ok, delta} <- Budget.new(delta) do
      usage = Budget.add(native.usage, delta)

      if Budget.within?(usage, native.budget),
        do: {:ok, %{native | usage: usage}},
        else:
          {:error,
           {:manager_native_subagent_budget_exceeded, Budget.exceeded(usage, native.budget)}}
    end
  end

  defp required_identity(reasons, map, field) do
    case value(map, field) do
      value when is_binary(value) and value != "" -> reasons
      _other -> [field | reasons]
    end
  end

  defp mismatch(reasons, parent, child, field) do
    if value(parent, field) == value(child, field), do: reasons, else: [field | reasons]
  end

  defp subset(reasons, parent, child, field) do
    parent_values = MapSet.new(value(parent, field, []))
    child_values = MapSet.new(value(child, field, []))
    if MapSet.subset?(child_values, parent_values), do: reasons, else: [field | reasons]
  end

  defp budget_reason(reasons, budget, parent_budget),
    do: if(Budget.within?(budget, parent_budget), do: reasons, else: [:budget | reasons])

  defp usage_reason(reasons, usage, budget, parent_budget) do
    if Budget.within?(usage, budget) and Budget.within?(usage, parent_budget),
      do: reasons,
      else: [:usage | reasons]
  end

  defp deadline_reason(reasons, child, parent) do
    if match?(%DateTime{}, child) and match?(%DateTime{}, parent) and
         DateTime.compare(child, parent) in [:lt, :eq],
       do: reasons,
       else: [:deadline | reasons]
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
