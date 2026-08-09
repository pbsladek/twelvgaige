defmodule Twelvgaige.Manager.Compiler do
  @moduledoc "Compiles manager proposals against registries and an already approved parent envelope."

  alias Twelvgaige.Manager.{Approval, Budget, CompiledPlan, Envelope, Plan}

  @registry_fields [
    agent: :agents,
    workflow: :workflows,
    repository: :repositories,
    auth_profile_id: :auth_profiles,
    sandbox_profile: :sandbox_profiles,
    network_mode: :network_modes
  ]

  def compile(%Plan{} = plan, opts) do
    with {:ok, envelope} <- envelope(opts),
         {:ok, catalog} <- catalog(opts),
         {:ok, plan} <- inherit_and_validate_shape(plan),
         :ok <- validate_registrations(plan, catalog),
         :ok <- validate_dag(plan.tasks),
         :ok <- validate_tree(plan.tasks),
         :ok <- validate_aggregate_limits(plan),
         reasons <- expansion_reasons(plan, envelope),
         {:ok, approval_status} <- authorize_expansion(plan, reasons, opts) do
      {:ok,
       %CompiledPlan{
         plan: plan,
         digest: Plan.digest(plan),
         tasks: plan.tasks,
         reserved_budget: Budget.sum(Enum.map(plan.tasks, & &1.budget)),
         approval_status: approval_status,
         compiled_at: DateTime.utc_now()
       }}
    end
  end

  def compile(attrs, opts) do
    with {:ok, plan} <- Plan.new(attrs), do: compile(plan, opts)
  end

  defp envelope(opts) do
    case Keyword.get(opts, :parent_envelope) do
      %Envelope{} = envelope -> {:ok, envelope}
      attrs when is_map(attrs) or is_list(attrs) -> Envelope.new(attrs)
      _other -> {:error, :manager_parent_envelope_required}
    end
  end

  defp catalog(opts) do
    case Keyword.get(opts, :catalog) do
      catalog when is_map(catalog) -> {:ok, catalog}
      _other -> {:error, :manager_catalog_required}
    end
  end

  defp inherit_and_validate_shape(plan) do
    tasks = Enum.map(plan.tasks, &inherit(&1, plan))
    plan = %{plan | tasks: tasks}
    ids = Enum.map(tasks, & &1.id)

    cond do
      not valid_plan_shape?(plan) -> {:error, :manager_plan_invalid}
      tasks == [] -> {:error, :manager_plan_empty}
      Enum.any?(ids, &(not is_binary(&1) or &1 == "")) -> {:error, :manager_task_id_invalid}
      length(ids) != MapSet.size(MapSet.new(ids)) -> {:error, :manager_task_id_duplicate}
      not positive_bound?(plan.max_depth) -> {:error, :manager_max_depth_invalid}
      not positive_bound?(plan.max_children) -> {:error, :manager_max_children_invalid}
      not positive_bound?(plan.max_fanout) -> {:error, :manager_max_fanout_invalid}
      length(tasks) > plan.max_children -> {:error, :manager_max_children_exceeded}
      plan.max_fanout > plan.max_children -> {:error, :manager_fanout_exceeds_children}
      not Enum.all?(tasks, &valid_task_shape?/1) -> {:error, :manager_task_invalid}
      true -> {:ok, plan}
    end
  end

  defp inherit(task, plan) do
    %{
      task
      | repository: task.repository || plan.repository,
        base_ref: task.base_ref || plan.base_ref,
        auth_profile_id: task.auth_profile_id || plan.auth_profile_id,
        sandbox_profile: task.sandbox_profile || plan.sandbox_profile,
        network_mode: task.network_mode || plan.network_mode,
        deadline: task.deadline || plan.deadline
    }
  end

  defp valid_task_shape?(task) do
    nonempty?(task.agent) and nonempty?(task.workflow) and nonempty?(task.objective) and
      positive_bound?(task.depth) and match?(%DateTime{}, task.deadline) and
      is_list(task.capabilities) and is_list(task.allowed_paths) and is_list(task.depends_on) and
      is_list(task.mounts) and is_list(task.external_effects) and
      is_boolean(task.write) and is_boolean(task.destructive) and
      is_integer(task.attempt) and task.attempt >= 0 and
      optional_id?(task.parent_task_id) and optional_id?(task.retry_of_task_id) and
      Enum.all?(task.allowed_paths, &safe_relative_path?/1)
  end

  defp valid_plan_shape?(plan) do
    Enum.all?(
      [
        plan.id,
        plan.manager_principal,
        plan.manager_session_id,
        plan.round_id,
        plan.shot_id,
        plan.repository,
        plan.base_ref
      ],
      &nonempty?/1
    ) and match?(%DateTime{}, plan.deadline) and is_list(plan.capabilities) and
      is_list(plan.allowed_paths) and Enum.all?(plan.allowed_paths, &safe_relative_path?/1)
  end

  defp nonempty?(value), do: is_binary(value) and value != ""
  defp optional_id?(nil), do: true
  defp optional_id?(value), do: nonempty?(value)

  defp safe_relative_path?(path) when is_binary(path) and path != "" do
    Path.type(path) == :relative and not Enum.member?(Path.split(path), "..")
  end

  defp safe_relative_path?(_path), do: false

  defp validate_registrations(plan, catalog) do
    failures =
      Enum.flat_map(plan.tasks, fn task ->
        fields =
          Enum.flat_map(@registry_fields, fn {field, registry} ->
            value = Map.fetch!(task, field)
            if registered?(catalog, registry, value), do: [], else: [{task.id, registry, value}]
          end)

        capabilities =
          Enum.reject(task.capabilities, &registered?(catalog, :capabilities, &1))
          |> Enum.map(&{task.id, :capabilities, &1})

        mounts =
          Enum.reject(task.mounts, &registered?(catalog, :mounts, &1))
          |> Enum.map(&{task.id, :mounts, &1})

        fields ++ capabilities ++ mounts
      end)

    if failures == [], do: :ok, else: {:error, {:manager_unregistered_authority, failures}}
  end

  defp registered?(catalog, registry, value) do
    values = Map.get(catalog, registry, Map.get(catalog, Atom.to_string(registry), []))

    case values do
      %MapSet{} = set -> MapSet.member?(set, value)
      map when is_map(map) -> Map.has_key?(map, value) or Map.has_key?(map, to_string(value))
      list when is_list(list) -> value in list
      _other -> false
    end
  end

  defp validate_dag(tasks) do
    ids = MapSet.new(Enum.map(tasks, & &1.id))

    cond do
      Enum.any?(tasks, fn task -> Enum.any?(task.depends_on, &(not MapSet.member?(ids, &1))) end) ->
        {:error, :manager_dependency_unknown}

      cyclic?(tasks) ->
        {:error, :manager_dependency_cycle}

      true ->
        :ok
    end
  end

  defp cyclic?(tasks) do
    dependencies = Map.new(tasks, &{&1.id, MapSet.new(&1.depends_on)})
    consume_acyclic(dependencies) != %{}
  end

  defp validate_tree(tasks) do
    by_id = Map.new(tasks, &{&1.id, &1})

    Enum.reduce_while(tasks, :ok, fn task, :ok ->
      case tree_depth(task.id, by_id, []) do
        {:ok, expected} when expected == task.depth ->
          {:cont, :ok}

        {:ok, expected} ->
          {:halt, {:error, {:manager_tree_depth_mismatch, task.id, expected, task.depth}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp tree_depth(id, by_id, visiting) do
    cond do
      id in visiting ->
        {:error, :manager_parent_cycle}

      true ->
        task = Map.fetch!(by_id, id)

        case task.parent_task_id do
          nil ->
            {:ok, 1}

          parent_id ->
            case Map.fetch(by_id, parent_id) do
              :error ->
                {:error, {:manager_parent_unknown, task.id, parent_id}}

              {:ok, _parent} ->
                with {:ok, parent_depth} <-
                       tree_depth(parent_id, by_id, [id | visiting]) do
                  {:ok, parent_depth + 1}
                end
            end
        end
    end
  end

  defp consume_acyclic(dependencies) do
    ready = for {id, deps} <- dependencies, MapSet.size(deps) == 0, do: id

    if ready == [] do
      dependencies
    else
      ready_set = MapSet.new(ready)

      dependencies
      |> Map.drop(ready)
      |> Map.new(fn {id, deps} -> {id, MapSet.difference(deps, ready_set)} end)
      |> consume_acyclic()
    end
  end

  defp validate_aggregate_limits(plan) do
    aggregate = Budget.sum(Enum.map(plan.tasks, & &1.budget))
    late = Enum.filter(plan.tasks, &(DateTime.compare(&1.deadline, plan.deadline) == :gt))
    too_deep = Enum.filter(plan.tasks, &(&1.depth > plan.max_depth))

    cond do
      not Budget.within?(aggregate, plan.budget) ->
        {:error, {:manager_aggregate_budget_exceeded, Budget.exceeded(aggregate, plan.budget)}}

      late != [] ->
        {:error, {:manager_deadline_exceeded, Enum.map(late, & &1.id)}}

      too_deep != [] ->
        {:error, {:manager_depth_exceeded, Enum.map(too_deep, & &1.id)}}

      true ->
        :ok
    end
  end

  defp expansion_reasons(plan, envelope) do
    task_reasons =
      Enum.flat_map(plan.tasks, fn task ->
        authority =
          Enum.flat_map(@registry_fields, fn {field, envelope_field} ->
            value = Map.fetch!(task, field)

            if MapSet.member?(Map.fetch!(envelope, envelope_field), value),
              do: [],
              else: [{task.id, envelope_field, value}]
          end)

        capabilities =
          if MapSet.subset?(MapSet.new(task.capabilities), envelope.capabilities),
            do: [],
            else: [{task.id, :capabilities}]

        mounts =
          if MapSet.subset?(MapSet.new(task.mounts), envelope.mounts),
            do: [],
            else: [{task.id, :mounts}]

        paths =
          if paths_within?(task.allowed_paths, envelope.allowed_paths),
            do: [],
            else: [{task.id, :allowed_paths}]

        effects =
          if task.external_effects == [],
            do: [],
            else: [{task.id, :external_effects, task.external_effects}]

        destructive = if task.destructive, do: [{task.id, :destructive}], else: []
        authority ++ capabilities ++ mounts ++ paths ++ effects ++ destructive
      end)

    plan_reasons =
      []
      |> maybe_reason(plan.max_depth > envelope.max_depth, :max_depth)
      |> maybe_reason(plan.max_children > envelope.max_children, :max_children)
      |> maybe_reason(plan.max_fanout > envelope.max_fanout, :max_fanout)
      |> maybe_reason(not Budget.within?(plan.budget, envelope.budget), :budget)
      |> maybe_reason(deadline_after?(plan.deadline, envelope.deadline), :deadline)

    Enum.sort(task_reasons ++ plan_reasons)
  end

  defp paths_within?(paths, allowed) do
    Enum.all?(paths, fn path ->
      Enum.any?(
        allowed,
        &(path == &1 or String.starts_with?(path, String.trim_trailing(&1, "/") <> "/"))
      )
    end)
  end

  defp authorize_expansion(_plan, [], _opts), do: {:ok, :within_envelope}

  defp authorize_expansion(plan, reasons, opts) do
    signing_key = Keyword.get(opts, :approval_signing_key)
    intent = Keyword.get(opts, :approval_intent)
    receipt = Keyword.get(opts, :approval_receipt)

    cond do
      not is_binary(signing_key) ->
        {:error, {:manager_approval_required, reasons, Plan.digest(plan)}}

      is_nil(intent) or is_nil(receipt) ->
        generated =
          Approval.intent(Plan.digest(plan), reasons, plan.manager_principal, signing_key)

        {:error, {:manager_approval_required, reasons, generated}}

      intent.plan_digest != Plan.digest(plan) or intent.reasons != Enum.sort(reasons) ->
        {:error, :manager_approval_scope_mismatch}

      true ->
        case Approval.verify(intent, receipt, plan.manager_principal, signing_key) do
          :ok -> {:ok, :independently_approved}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp deadline_after?(_deadline, nil), do: false
  defp deadline_after?(deadline, limit), do: DateTime.compare(deadline, limit) == :gt

  defp maybe_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp positive_bound?(value), do: is_integer(value) and value > 0
end
