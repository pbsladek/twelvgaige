defmodule Twelvgaige.Manager.Plan do
  @moduledoc "Typed, provider-neutral proposal for bounded manager-created child sessions."

  alias Twelvgaige.Manager.Budget
  alias Twelvgaige.Manager.Plan.Task, as: ChildTask

  @enforce_keys [
    :id,
    :manager_principal,
    :manager_session_id,
    :round_id,
    :shot_id,
    :repository,
    :base_ref,
    :budget,
    :deadline,
    :tasks,
    :created_at
  ]
  defstruct [
    :id,
    :manager_principal,
    :manager_session_id,
    :round_id,
    :shot_id,
    :repository,
    :base_ref,
    :auth_profile_id,
    :sandbox_profile,
    :network_mode,
    :budget,
    :deadline,
    :created_at,
    :policy_revision,
    tasks: [],
    capabilities: [],
    allowed_paths: [],
    max_depth: 1,
    max_children: 16,
    max_fanout: 4,
    schema_version: 1,
    encoding_version: 1
  ]

  @type t :: %__MODULE__{}

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, budget} <- Budget.new(value(attrs, :budget, %{})),
         {:ok, tasks} <- child_tasks(value(attrs, :tasks, [])) do
      {:ok,
       %__MODULE__{
         id: value(attrs, :id, Twelvgaige.ID.new(:manager_plan)),
         manager_principal: required(attrs, :manager_principal),
         manager_session_id: required(attrs, :manager_session_id),
         round_id: required(attrs, :round_id),
         shot_id: required(attrs, :shot_id),
         repository: required(attrs, :repository),
         base_ref: required(attrs, :base_ref),
         auth_profile_id: value(attrs, :auth_profile_id),
         sandbox_profile: value(attrs, :sandbox_profile),
         network_mode: value(attrs, :network_mode),
         capabilities: value(attrs, :capabilities, []),
         allowed_paths: value(attrs, :allowed_paths, []),
         budget: budget,
         deadline: required(attrs, :deadline),
         max_depth: value(attrs, :max_depth, 1),
         max_children: value(attrs, :max_children, 16),
         max_fanout: value(attrs, :max_fanout, 4),
         tasks: tasks,
         policy_revision: value(attrs, :policy_revision),
         created_at: value(attrs, :created_at, DateTime.utc_now())
       }}
    end
  rescue
    KeyError -> {:error, :manager_plan_required_field_missing}
  end

  def new(_attrs), do: {:error, :manager_plan_invalid}

  def digest(%__MODULE__{} = plan) do
    plan
    |> Map.from_struct()
    |> Map.delete(:created_at)
    |> canonical()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp child_tasks(tasks) when is_list(tasks) do
    Enum.reduce_while(tasks, {:ok, []}, fn attrs, {:ok, acc} ->
      case ChildTask.new(attrs) do
        {:ok, task} -> {:cont, {:ok, [task | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, tasks} -> {:ok, Enum.reverse(tasks)}
      error -> error
    end
  end

  defp child_tasks(_tasks), do: {:error, :manager_tasks_invalid}

  defp canonical(%DateTime{} = date), do: DateTime.to_iso8601(date)
  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {key, val} -> {to_string(key), canonical(val)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp required(attrs, key) do
    case value(attrs, key, :missing) do
      :missing -> raise KeyError, key: key, term: attrs
      value -> value
    end
  end

  defp value(attrs, key, default \\ nil)
  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end

defmodule Twelvgaige.Manager.Plan.Task do
  @moduledoc "One governed Twelvgaige child-session request."

  alias Twelvgaige.Manager.Budget

  @roles [:worker, :integrator, :verifier, :repair]
  @enforce_keys [:id, :agent, :workflow, :objective, :budget]
  defstruct [
    :id,
    :agent,
    :workflow,
    :objective,
    :repository,
    :base_ref,
    :auth_profile_id,
    :sandbox_profile,
    :network_mode,
    :budget,
    :deadline,
    :parent_task_id,
    :retry_of_task_id,
    role: :worker,
    depth: 1,
    capabilities: [],
    allowed_paths: [],
    mounts: [],
    depends_on: [],
    write: true,
    external_effects: [],
    destructive: false,
    attempt: 0
  ]

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, budget} <- Budget.new(value(attrs, :budget, %{})),
         role when role in @roles <- value(attrs, :role, :worker) do
      {:ok,
       %__MODULE__{
         id: required(attrs, :id),
         agent: required(attrs, :agent),
         workflow: required(attrs, :workflow),
         objective: required(attrs, :objective),
         repository: value(attrs, :repository),
         base_ref: value(attrs, :base_ref),
         auth_profile_id: value(attrs, :auth_profile_id),
         sandbox_profile: value(attrs, :sandbox_profile),
         network_mode: value(attrs, :network_mode),
         capabilities: value(attrs, :capabilities, []),
         allowed_paths: value(attrs, :allowed_paths, []),
         mounts: value(attrs, :mounts, []),
         budget: budget,
         deadline: value(attrs, :deadline),
         parent_task_id: value(attrs, :parent_task_id),
         retry_of_task_id: value(attrs, :retry_of_task_id),
         depends_on: value(attrs, :depends_on, []),
         role: role,
         depth: value(attrs, :depth, 1),
         write: value(attrs, :write, true),
         external_effects: value(attrs, :external_effects, []),
         destructive: value(attrs, :destructive, false),
         attempt: value(attrs, :attempt, 0)
       }}
    else
      role when is_atom(role) -> {:error, {:manager_task_role_invalid, role}}
      {:error, reason} -> {:error, reason}
    end
  rescue
    KeyError -> {:error, :manager_task_required_field_missing}
  end

  defp required(attrs, key) do
    case value(attrs, key, :missing) do
      :missing -> raise KeyError, key: key, term: attrs
      value -> value
    end
  end

  defp value(attrs, key, default \\ nil)
  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
