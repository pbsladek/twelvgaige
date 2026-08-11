defmodule Twelvgaige.Manager.Scheduler do
  @moduledoc """
  Durable, fair, bounded scheduler for Twelvgaige-managed child sessions.

  The scheduler persists child identity before execution, allocates a distinct
  workspace at dispatch, propagates cancellation/deadlines, and treats the
  injected runtime executor as a worker—not as the scheduling authority.
  """

  use GenServer

  alias Twelvgaige.Handoff
  alias Twelvgaige.Manager.{Budget, ChildFactory, ChildRecord, CompiledPlan, PlanRecord, Verifier}
  alias Twelvgaige.Manager.Store.Memory, as: DefaultStore

  defstruct [
    :store,
    :store_server,
    :executor,
    :cancel_fun,
    :reserve_fun,
    :release_fun,
    :reservation_recovery_fun,
    :child_admit_fun,
    :child_release_fun,
    :recovery_fun,
    :workspace_finalize_fun,
    :child_factory,
    :child_factory_opts,
    max_running: 4,
    max_queue_children: 64,
    queues: %{},
    plan_timers: %{},
    plan_order: [],
    cursor: 0,
    last_plan_id: nil,
    running: %{},
    refs: %{}
  ]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, opts),
      else: GenServer.start_link(__MODULE__, opts, name: name)
  end

  def submit(%CompiledPlan{} = plan, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:submit, plan}, :infinity)

  def cancel(plan_id, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:cancel, plan_id}, :infinity)

  def status(plan_id, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:status, plan_id})

  def review(plan_id, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:review, plan_id})

  def child(child_id, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:child, child_id})

  def capacity_available(opts \\ []),
    do: GenServer.cast(Keyword.get(opts, :server, __MODULE__), :capacity_available)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %__MODULE__{
      store: Keyword.get(opts, :store, DefaultStore),
      store_server: Keyword.get(opts, :store_server, DefaultStore),
      executor: Keyword.fetch!(opts, :executor),
      cancel_fun: Keyword.get(opts, :cancel_fun, fn _child -> :ok end),
      reserve_fun: Keyword.get(opts, :reserve_fun, fn _budget -> {:ok, nil} end),
      release_fun: Keyword.get(opts, :release_fun, fn _lease -> :ok end),
      reservation_recovery_fun:
        Keyword.get(opts, :reservation_recovery_fun, fn lease, _budget, _plan ->
          if is_nil(lease),
            do: {:error, :manager_reservation_missing},
            else: {:ok, lease}
        end),
      child_admit_fun: Keyword.get(opts, :child_admit_fun, fn _child -> {:ok, nil} end),
      child_release_fun: Keyword.get(opts, :child_release_fun, fn _permit -> :ok end),
      recovery_fun: Keyword.get(opts, :recovery_fun, fn _child -> :quarantine end),
      workspace_finalize_fun:
        Keyword.get(opts, :workspace_finalize_fun, fn _child, result -> result end),
      child_factory: Keyword.get(opts, :child_factory, &ChildFactory.prepare/2),
      child_factory_opts: Keyword.get(opts, :child_factory_opts, []),
      max_running: Keyword.get(opts, :max_running, 4),
      max_queue_children: Keyword.get(opts, :max_queue_children, 64)
    }

    case recover(state) do
      {:ok, state} ->
        send(self(), :dispatch)
        {:ok, state}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:submit, compiled}, _from, state) do
    case store(state, :get_plan, [compiled.plan.id]) do
      {:ok, existing} ->
        if existing.compiled_plan.digest == compiled.digest,
          do: {:reply, {:ok, compiled.plan.id, :already_submitted}, state},
          else: {:reply, {:error, :manager_plan_conflict}, state}

      {:error, :not_found} ->
        submit_new(compiled, state)
    end
  end

  def handle_call({:cancel, plan_id}, _from, state) do
    case store(state, :get_plan, [plan_id]) do
      {:ok, plan} when plan.status in [:completed, :failed, :cancelled, :awaiting_review] ->
        {:reply, :already_stopped, state}

      {:ok, plan} ->
        {:reply, :ok, stop_plan(plan, :cancelled, :parent_cancelled, :plan_cancelled, state)}

      {:error, :not_found} ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:status, plan_id}, _from, state) do
    {:reply, status_view(plan_id, state), state}
  end

  def handle_call({:review, plan_id}, _from, state) do
    {:reply, review_view(plan_id, state), state}
  end

  def handle_call({:child, child_id}, _from, state),
    do: {:reply, store(state, :get_child, [child_id]), state}

  @impl true
  def handle_cast(:capacity_available, state) do
    send(self(), :dispatch)
    {:noreply, state}
  end

  @impl true
  def handle_info(:dispatch, state), do: {:noreply, dispatch_available(state)}

  def handle_info({:plan_deadline, plan_id}, state) do
    state = %{state | plan_timers: Map.delete(state.plan_timers, plan_id)}

    case store(state, :get_plan, [plan_id]) do
      {:ok, plan} when plan.status in [:queued, :running] ->
        state =
          stop_plan(
            plan,
            :failed,
            :plan_deadline_exceeded,
            :plan_deadline_exceeded,
            state
          )

        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:child_prepared, child_id, prepared, worker}, state) do
    case Map.fetch(state.running, child_id) do
      {:ok, %{pid: ^worker, phase: :preparing} = entry} ->
        {:ok, stored} = store(state, :get_child, [child_id])

        attrs = %{
          delegated_session_id: prepared.delegated_session_id,
          workspace_id: prepared.workspace_id,
          status: :running,
          started_at: DateTime.utc_now()
        }

        {:ok, running_child} = store(state, :update_child, [child_id, stored.version, attrs])
        send(worker, {:execute, child_id})
        event(state, running_child.plan_id, :child_started, child_event(running_child))
        entry = %{entry | phase: :running, child: running_child}
        {:noreply, put_in(state.running[child_id], entry)}

      _other ->
        Process.exit(worker, :kill)
        {:noreply, state}
    end
  end

  def handle_info({:child_prepare_failed, child_id, reason, worker}, state) do
    handle_worker_result(
      child_id,
      {:error, {:workspace_preparation_failed, reason}},
      worker,
      state
    )
  end

  def handle_info({:child_result, child_id, result, worker}, state) do
    handle_worker_result(child_id, result, worker, state)
  end

  def handle_info({:child_deadline, child_id}, state) do
    case Map.fetch(state.running, child_id) do
      {:ok, entry} ->
        result = terminal_result(entry, :deadline_exceeded, state)
        Process.exit(entry.pid, :kill)
        handle_worker_result(child_id, result, entry.pid, state)

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.refs, ref) do
      {nil, refs} ->
        {:noreply, %{state | refs: refs}}

      {child_id, refs} ->
        state = %{state | refs: refs}

        case Map.get(state.running, child_id) do
          nil ->
            {:noreply, state}

          entry ->
            result = terminal_result(entry, {:worker_exit, reason}, state)
            handle_worker_result(child_id, result, nil, state)
        end
    end
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  defp submit_new(compiled, state) do
    queued = queued_count(state)

    cond do
      queued + length(compiled.tasks) > state.max_queue_children ->
        {:reply, {:error, :manager_queue_backpressure}, state}

      length(compiled.tasks) > compiled.plan.max_children ->
        {:reply, {:error, :manager_max_children_exceeded}, state}

      true ->
        case state.reserve_fun.(compiled.plan.budget) do
          {:ok, lease} -> persist_submission(compiled, lease, state)
          {:error, reason} -> {:reply, {:error, {:manager_reservation_failed, reason}}, state}
        end
    end
  end

  defp persist_submission(compiled, lease, state) do
    plan_record = PlanRecord.new(compiled, %{reservation_lease: lease})
    children = Enum.map(compiled.tasks, &ChildRecord.new(compiled, &1))

    with :ok <- accepted(store(state, :put_submission, [plan_record, children])) do
      ready = children |> Enum.filter(&(&1.status == :queued)) |> Enum.map(& &1.id)
      queues = Map.put(state.queues, compiled.plan.id, ready)

      order =
        if compiled.plan.id in state.plan_order,
          do: state.plan_order,
          else: state.plan_order ++ [compiled.plan.id]

      state = %{state | queues: queues, plan_order: order}
      state = schedule_plan_deadline(state, plan_record)

      event(state, compiled.plan.id, :plan_submitted, %{
        children: length(children),
        reserved_budget: compiled.plan.budget
      })

      send(self(), :dispatch)
      {:reply, {:ok, compiled.plan.id, :submitted}, state}
    else
      {:error, reason} ->
        _ = state.release_fun.(lease)
        {:reply, {:error, reason}, state}
    end
  end

  defp accepted(:ok), do: :ok
  defp accepted(:already_present), do: :ok
  defp accepted({:error, _reason} = error), do: error

  defp dispatch_available(state) when map_size(state.running) >= state.max_running, do: state

  defp dispatch_available(state) do
    case next_child(state) do
      {:ok, child, permit, state} ->
        child |> start_child(permit, state) |> dispatch_available()

      {:skip, plan_id, state} ->
        state
        |> unlock_dependents(plan_id)
        |> settle_plan(plan_id)
        |> dispatch_available()

      :empty ->
        state
    end
  end

  defp next_child(%{plan_order: []}), do: :empty

  defp next_child(state) do
    size = length(state.plan_order)

    start_index =
      case Enum.find_index(state.plan_order, &(&1 == state.last_plan_id)) do
        nil -> state.cursor
        index -> rem(index + 1, size)
      end

    Enum.reduce_while(0..(size - 1), :empty, fn offset, _acc ->
      index = rem(start_index + offset, size)
      plan_id = Enum.at(state.plan_order, index)
      queue = Map.get(state.queues, plan_id, [])

      if queue != [] and running_for_plan(state, plan_id) < plan_fanout(state, plan_id) do
        [child_id | rest] = queue

        case store(state, :get_child, [child_id]) do
          {:ok, child} ->
            case state.child_admit_fun.(child) do
              {:ok, permit} ->
                case store(state, :update_child, [
                       child.id,
                       child.version,
                       %{status: :admitted, resource_permit: permit}
                     ]) do
                  {:ok, admitted} ->
                    state = %{
                      state
                      | queues: Map.put(state.queues, plan_id, rest),
                        cursor: rem(index + 1, size),
                        last_plan_id: plan_id
                    }

                    {:halt, {:ok, admitted, permit, state}}

                  {:error, reason} ->
                    release_permit(permit, state)
                    raise "manager child admission persistence failed: #{inspect(reason)}"
                end

              {:wait, _reason} ->
                {:cont, :empty}

              {:error, reason} ->
                {:ok, denied} =
                  store(state, :update_child, [
                    child.id,
                    child.version,
                    %{
                      status: :awaiting_review,
                      error: {:manager_child_admission_failed, reason},
                      finished_at: DateTime.utc_now()
                    }
                  ])

                state = %{
                  state
                  | queues: Map.put(state.queues, plan_id, rest),
                    cursor: rem(index + 1, size),
                    last_plan_id: plan_id
                }

                event(state, plan_id, :child_admission_failed, child_event(denied))
                {:halt, {:skip, plan_id, state}}
            end

          {:error, :not_found} ->
            {:cont, :empty}
        end
      else
        {:cont, :empty}
      end
    end)
  end

  defp start_child(child, permit, state) do
    scheduler = self()
    factory = state.child_factory
    factory_opts = state.child_factory_opts
    executor = state.executor
    workspace_finalize_fun = state.workspace_finalize_fun

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          case factory.(child, factory_opts) do
            {:ok, prepared} ->
              send(scheduler, {:child_prepared, child.id, prepared, self()})

              receive do
                {:execute, child_id} ->
                  result = executor.(prepared)
                  result = workspace_finalize_fun.(prepared, result)
                  send(scheduler, {:child_result, child_id, result, self()})
              end

            {:error, reason} ->
              send(scheduler, {:child_prepare_failed, child.id, reason, self()})
          end
        end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:child_deadline, child.id}, deadline_ms(child.deadline))

    entry = %{
      pid: pid,
      ref: ref,
      timer: timer,
      phase: :preparing,
      child: child,
      permit: permit,
      started_mono: System.monotonic_time(:millisecond)
    }

    state
    |> put_in([Access.key!(:running), child.id], entry)
    |> put_in([Access.key!(:refs), ref], child.id)
  end

  defp handle_worker_result(child_id, result, worker, state) do
    case Map.fetch(state.running, child_id) do
      {:ok, entry} when is_nil(worker) or entry.pid == worker ->
        Process.cancel_timer(entry.timer)
        Process.demonitor(entry.ref, [:flush])
        release_permit(entry.permit, state)
        state = remove_running(child_id, state)
        {:ok, child} = store(state, :get_child, [child_id])
        {attrs, usage} = result_attrs(result, child)
        usage = observe_wall_time(usage, entry.started_mono)
        attrs = Map.put(attrs, :usage, usage)
        attrs = Map.put(attrs, :resource_permit, nil)
        attrs = enforce_verifier_independence(attrs, child, state)
        plan = fetch_plan!(state, child.plan_id)
        aggregate_usage = Budget.add(plan.usage, usage)

        {attrs, aggregate_usage} =
          if Budget.within?(usage, child.budget) and
               Budget.within?(aggregate_usage, plan.reserved_budget) do
            {attrs, aggregate_usage}
          else
            {%{
               status: :failed,
               error: :manager_budget_exceeded,
               finished_at: DateTime.utc_now(),
               usage: usage
             }, aggregate_usage}
          end

        {:ok, child} = store(state, :update_child, [child.id, child.version, attrs])

        {:ok, plan} =
          update_plan(state, plan, %{
            usage: aggregate_usage,
            status: :running,
            updated_at: DateTime.utc_now()
          })

        event(state, child.plan_id, :child_finished, child_event(child))

        state =
          state
          |> maybe_repair(plan, child)
          |> unlock_dependents(child.plan_id)
          |> settle_plan(child.plan_id)
          |> dispatch_available()

        {:noreply, state}

      _other ->
        {:noreply, state}
    end
  end

  defp result_attrs({:ok, %Handoff{} = handoff}, _child),
    do: usage_missing_attrs(:success, handoff)

  defp result_attrs({:ok, %{handoff: %Handoff{} = handoff} = result}, _child) do
    case Map.fetch(result, :usage) do
      {:ok, raw_usage} ->
        case Budget.new(raw_usage) do
          {:ok, usage} ->
            {%{
               status: :completed,
               handoff: handoff,
               usage: usage,
               principal: Map.get(result, :principal),
               verification: Map.get(result, :verification),
               finished_at: DateTime.utc_now()
             }, usage}

          {:error, reason} ->
            invalid_usage_attrs(reason)
        end

      :error ->
        usage_missing_attrs(:success, handoff)
    end
  end

  defp result_attrs({:error, reason, %{usage: raw_usage} = evidence}, _child) do
    case Budget.new(raw_usage) do
      {:ok, usage} ->
        {%{
           status: :failed,
           error: reason,
           usage: usage,
           handoff: Map.get(evidence, :handoff),
           verification: Map.get(evidence, :verification),
           finished_at: DateTime.utc_now()
         }, usage}

      {:error, usage_reason} ->
        invalid_usage_attrs(usage_reason)
    end
  end

  defp result_attrs({:error, reason, usage}, _child) do
    case Budget.new(usage) do
      {:ok, usage} ->
        {%{status: :failed, error: reason, usage: usage, finished_at: DateTime.utc_now()}, usage}

      {:error, usage_reason} ->
        invalid_usage_attrs(usage_reason)
    end
  end

  defp result_attrs({:error, reason}, _child),
    do: usage_missing_attrs({:error, reason}, nil)

  defp result_attrs(other, _child),
    do:
      {%{
         status: :failed,
         error: {:manager_child_result_invalid, other},
         usage: Budget.zero(),
         finished_at: DateTime.utc_now()
       }, Budget.zero()}

  defp usage_missing_attrs(outcome, handoff) do
    usage = Budget.zero()

    {%{
       status: :failed,
       error: {:manager_child_usage_missing, outcome},
       handoff: handoff,
       usage: usage,
       finished_at: DateTime.utc_now()
     }, usage}
  end

  defp invalid_usage_attrs(reason) do
    usage = Budget.zero()

    {%{
       status: :failed,
       error: {:manager_child_usage_invalid, reason},
       usage: usage,
       finished_at: DateTime.utc_now()
     }, usage}
  end

  defp enforce_verifier_independence(
         %{status: :completed, principal: principal} = attrs,
         %{task: %{role: :verifier}} = child,
         state
       ) do
    {:ok, children} = store(state, :list_children, [child.plan_id])

    worker_principals =
      children
      |> Enum.filter(&(&1.task_id in child.task.depends_on))
      |> Enum.map(& &1.principal)
      |> Enum.reject(&is_nil/1)

    if is_nil(principal) or principal in worker_principals do
      Map.merge(attrs, %{status: :failed, error: :manager_verifier_not_independent})
    else
      attrs
    end
  end

  defp enforce_verifier_independence(attrs, _child, _state), do: attrs

  defp maybe_repair(
         state,
         _plan,
         %{task: %{role: :verifier}, status: :failed, error: :manager_verifier_not_independent} =
           verifier
       ) do
    update_child!(state, verifier, %{status: :awaiting_review})
    state
  end

  defp maybe_repair(state, plan, %{task: %{role: :verifier}, status: :failed} = verifier) do
    if verifier.attempt >= 1 or plan.repair_attempts >= 1 do
      update_child!(state, verifier, %{status: :awaiting_review})
      state
    else
      enqueue_repair_pair(plan, verifier, state)
    end
  end

  defp maybe_repair(state, _plan, %{task: %{role: :repair}, status: :completed} = repair) do
    enqueue_verifier_retry(repair, state)
  end

  defp maybe_repair(state, _plan, _child), do: state

  defp enqueue_repair_pair(plan, verifier, state) do
    {:ok, children} = store(state, :list_children, [plan.id])
    source_id = List.first(verifier.task.depends_on)
    source = Enum.find(children, &(&1.task_id == source_id and &1.attempt == 0))
    remaining = Budget.remaining(plan.reserved_budget, plan.allocated_budget)

    cond do
      is_nil(source) ->
        update_child!(state, verifier, %{
          status: :awaiting_review,
          error: :manager_repair_source_missing
        })

        state

      length(children) + 2 > plan.compiled_plan.plan.max_children ->
        update_child!(state, verifier, %{
          status: :awaiting_review,
          error: :manager_repair_child_limit
        })

        state

      queued_count(state) + 2 > state.max_queue_children ->
        update_child!(state, verifier, %{
          status: :awaiting_review,
          error: :manager_queue_backpressure
        })

        state

      true ->
        needed = Budget.add(source.budget, verifier.budget)

        if Budget.within?(needed, remaining) do
          {:ok, repair} =
            Verifier.repair_child(plan.compiled_plan, source, remaining, plan.repair_attempts)

          :ok = accepted(store(state, :put_child, [repair]))

          allocated = Budget.add(plan.allocated_budget, needed)

          {:ok, _plan} =
            update_plan(state, plan, %{repair_attempts: 1, allocated_budget: allocated})

          event(state, plan.id, :repair_queued, %{child_id: repair.id, source_child_id: source.id})

          enqueue(state, repair)
        else
          update_child!(state, verifier, %{
            status: :awaiting_review,
            error: :manager_repair_budget_exhausted
          })

          state
        end
    end
  end

  defp enqueue_verifier_retry(repair, state) do
    plan = fetch_plan!(state, repair.plan_id)
    {:ok, children} = store(state, :list_children, [repair.plan_id])

    original = Enum.find(children, &(&1.task.role == :verifier and &1.attempt == 0))

    if original do
      task = %{
        original.task
        | id: original.task.id <> ":retry:1",
          attempt: 1,
          retry_of_task_id: original.task.id,
          depends_on: Enum.uniq(original.task.depends_on ++ [repair.task.id])
      }

      retry = ChildRecord.new(plan.compiled_plan, task, %{attempt: 1, status: :queued})

      case queued_count(state) + 1 > state.max_queue_children do
        true ->
          update_child!(state, repair, %{
            status: :awaiting_review,
            error: :manager_queue_backpressure
          })

          state

        false ->
          persist_verifier_retry(plan, repair, retry, state)
      end
    else
      state
    end
  end

  defp persist_verifier_retry(plan, repair, retry, state) do
    case accepted(store(state, :put_child, [retry])) do
      :ok ->
        event(state, plan.id, :verifier_retry_queued, %{
          child_id: retry.id,
          repair_child_id: repair.id
        })

        enqueue(state, retry)

      {:error, _reason} ->
        state
    end
  end

  defp unlock_dependents(state, plan_id) do
    {:ok, children} = store(state, :list_children, [plan_id])
    by_task = Map.new(children, &{&1.task_id, &1})

    Enum.reduce(children, state, fn child, acc ->
      if child.status == :blocked do
        dependencies = Enum.map(child.task.depends_on, &Map.get(by_task, &1))

        cond do
          Enum.all?(dependencies, &match?(%ChildRecord{status: :completed}, &1)) ->
            {:ok, queued} =
              store(acc, :update_child, [child.id, child.version, %{status: :queued}])

            enqueue(acc, queued)

          Enum.any?(
            dependencies,
            &match?(
              %ChildRecord{status: status} when status in [:failed, :cancelled, :awaiting_review],
              &1
            )
          ) ->
            update_child!(acc, child, %{
              status: :awaiting_review,
              error: :manager_dependency_failed
            })

            acc

          true ->
            acc
        end
      else
        acc
      end
    end)
  end

  defp settle_plan(state, plan_id) do
    plan = fetch_plan!(state, plan_id)
    {:ok, children} = store(state, :list_children, [plan_id])

    active? =
      Enum.any?(children, &(&1.status in [:blocked, :queued, :admitted, :running])) or
        running_for_plan(state, plan_id) > 0

    status =
      cond do
        plan.status == :cancelled -> :cancelled
        active? -> :running
        Enum.any?(children, &(&1.status == :awaiting_review)) -> :awaiting_review
        Enum.any?(children, &(&1.status == :failed)) -> :failed
        Enum.all?(children, &(&1.status == :completed)) -> :completed
        true -> :awaiting_review
      end

    state =
      if status != plan.status do
        {:ok, plan} = update_plan(state, plan, %{status: status, updated_at: DateTime.utc_now()})

        if status in [:completed, :failed, :cancelled, :awaiting_review] do
          _ = state.release_fun.(plan.reservation_lease)
          event(state, plan_id, :plan_finished, %{status: status})
          cancel_plan_timer(state, plan_id)
        else
          state
        end
      else
        if status in [:completed, :failed, :cancelled, :awaiting_review],
          do: cancel_plan_timer(state, plan_id),
          else: state
      end

    state
  end

  defp recover(state) do
    with {:ok, plans} <- store(state, :list_plans, []) do
      result =
        Enum.reduce_while(plans, {:ok, state}, fn plan, {:ok, acc} ->
          if plan.status in [:queued, :running] do
            case recover_plan(plan, acc) do
              {:ok, acc} -> {:cont, {:ok, acc}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          else
            {:cont, {:ok, acc}}
          end
        end)

      case result do
        {:ok, recovered} ->
          active_ids = for plan <- plans, plan.status in [:queued, :running], do: plan.id
          {:ok, Enum.reduce(active_ids, recovered, &settle_plan(&2, &1))}

        error ->
          error
      end
    end
  end

  defp recover_plan(plan, state) do
    with {:ok, plan} <- recover_reservation(plan, state),
         {:ok, children} <- store(state, :list_children, [plan.id]) do
      {state, ready} =
        Enum.reduce(children, {state, []}, fn child, {acc, queue} ->
          cond do
            child.status in [:admitted, :running] ->
              release_permit(child.resource_permit, acc)

              decision =
                if child.status == :admitted,
                  do: :retry,
                  else: acc.recovery_fun.(child)

              case decision do
                decision when decision in [:resume, :retry] ->
                  {:ok, recovered} =
                    store(acc, :update_child, [
                      child.id,
                      child.version,
                      %{
                        status: :queued,
                        resource_permit: nil,
                        error: {:scheduler_recovered, decision}
                      }
                    ])

                  {acc, [recovered.id | queue]}

                _quarantine ->
                  {:ok, _quarantined} =
                    store(acc, :update_child, [
                      child.id,
                      child.version,
                      %{
                        status: :awaiting_review,
                        resource_permit: nil,
                        error: :scheduler_recovery_quarantined
                      }
                    ])

                  {acc, queue}
              end

            child.status == :queued ->
              {acc, [child.id | queue]}

            true ->
              {acc, queue}
          end
        end)

      order =
        if plan.id in state.plan_order, do: state.plan_order, else: state.plan_order ++ [plan.id]

      event(state, plan.id, :plan_recovered, %{queued_children: length(ready)})

      state = %{
        state
        | queues: Map.put(state.queues, plan.id, Enum.reverse(ready)),
          plan_order: order
      }

      {:ok, schedule_plan_deadline(state, plan)}
    end
  end

  defp recover_reservation(plan, state) do
    case state.reservation_recovery_fun.(plan.reservation_lease, plan.reserved_budget, plan) do
      {:ok, lease} when lease == plan.reservation_lease ->
        {:ok, plan}

      {:ok, lease} ->
        update_plan(state, plan, %{reservation_lease: lease, updated_at: DateTime.utc_now()})

      {:error, reason} ->
        {:error, {:manager_reservation_recovery_failed, plan.id, reason}}

      other ->
        {:error, {:manager_reservation_recovery_invalid, plan.id, other}}
    end
  end

  defp status_view(plan_id, state) do
    with {:ok, plan} <- store(state, :get_plan, [plan_id]),
         {:ok, children} <- store(state, :list_children, [plan_id]),
         {:ok, events} <- store(state, :list_events, [plan_id]) do
      counts = Enum.frequencies_by(children, & &1.status)
      disagreements = Enum.count(children, &match?(%{verification: %{disagreement: true}}, &1))

      {:ok,
       %{
         id: plan.id,
         status: plan.status,
         progress: %{total: length(children), by_status: counts},
         running: running_for_plan(state, plan_id),
         queued: length(Map.get(state.queues, plan_id, [])),
         budget: %{
           reserved: plan.reserved_budget,
           allocated: plan.allocated_budget,
           used: plan.usage,
           remaining: Budget.remaining(plan.reserved_budget, plan.usage)
         },
         repair_attempts: plan.repair_attempts,
         disagreements: disagreements,
         error: plan.error,
         cancellation: if(plan.cancelled_at, do: %{cancelled_at: plan.cancelled_at}, else: nil),
         last_event: List.last(events)
       }}
    end
  end

  defp review_view(plan_id, state) do
    with {:ok, plan} <- store(state, :get_plan, [plan_id]),
         {:ok, children} <- store(state, :list_children, [plan_id]),
         {:ok, events} <- store(state, :list_events, [plan_id]) do
      {:ok,
       json_safe(%{
         plan_id: plan.id,
         status: plan.status,
         error: plan.error,
         repair_attempts: plan.repair_attempts,
         budget: %{reserved: plan.reserved_budget, used: plan.usage},
         children:
           Enum.map(children, fn child ->
             Map.take(child, [
               :id,
               :task_id,
               :attempt,
               :status,
               :principal,
               :workspace_id,
               :handoff,
               :verification,
               :usage,
               :error,
               :started_at,
               :finished_at
             ])
           end),
         events: events,
         mutates_state: false
       })}
    end
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%_{} = value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, json_safe(item)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value), do: value

  defp update_plan(state, plan, attrs),
    do: store(state, :update_plan, [plan.id, plan.version, attrs])

  defp update_child!(state, child, attrs) do
    case store(state, :update_child, [child.id, child.version, attrs]) do
      {:ok, _updated} -> :ok
      {:error, :manager_version_conflict} -> :ok
      {:error, reason} -> raise "manager child update failed: #{inspect(reason)}"
    end
  end

  defp enqueue(state, child) do
    queue = Map.get(state.queues, child.plan_id, [])
    %{state | queues: Map.put(state.queues, child.plan_id, queue ++ [child.id])}
  end

  defp remove_running(child_id, state) do
    case Map.pop(state.running, child_id) do
      {nil, running} -> %{state | running: running}
      {entry, running} -> %{state | running: running, refs: Map.delete(state.refs, entry.ref)}
    end
  end

  defp stop_running_process(child_id, state) do
    case Map.get(state.running, child_id) do
      %{pid: pid, timer: timer, ref: ref} ->
        Process.cancel_timer(timer)
        Process.demonitor(ref, [:flush])
        Process.exit(pid, :kill)

      nil ->
        :ok
    end
  end

  defp release_child_permit(child_id, state) do
    case Map.get(state.running, child_id) do
      %{permit: permit} -> release_permit(permit, state)
      nil -> :ok
    end
  end

  defp release_permit(nil, _state), do: :ok

  defp release_permit(permit, state) do
    try do
      state.child_release_fun.(permit)
    catch
      _kind, _reason -> :ok
    end
  end

  defp stop_plan(plan, plan_status, child_error, event_type, state) do
    now = DateTime.utc_now()
    {:ok, children} = store(state, :list_children, [plan.id])

    {state, stopped_usage} =
      Enum.reduce(children, {state, Budget.zero()}, fn child, {acc, usage_acc} ->
        if ChildRecord.terminal?(child) do
          {acc, usage_acc}
        else
          {attrs, usage} = cancelled_child_attrs(child, child_error, now, acc)
          stop_running_process(child.id, acc)
          release_child_permit(child.id, acc)
          update_child!(acc, child, attrs)

          {remove_running(child.id, acc), Budget.add(usage_acc, usage)}
        end
      end)

    {:ok, plan} =
      update_plan(state, plan, %{
        status: plan_status,
        error: child_error,
        usage: Budget.add(plan.usage, stopped_usage),
        cancelled_at: now,
        updated_at: now
      })

    _ = state.release_fun.(plan.reservation_lease)

    state = %{
      state
      | queues: Map.put(state.queues, plan.id, [])
    }

    state = cancel_plan_timer(state, plan.id)
    event(state, plan.id, event_type, %{children: length(children), reason: child_error})
    state
  end

  defp schedule_plan_deadline(state, plan) do
    state = cancel_plan_timer(state, plan.id)
    deadline = plan.compiled_plan.plan.deadline
    timer = Process.send_after(self(), {:plan_deadline, plan.id}, deadline_ms(deadline))
    %{state | plan_timers: Map.put(state.plan_timers, plan.id, timer)}
  end

  defp cancel_plan_timer(state, plan_id) do
    case Map.pop(state.plan_timers, plan_id) do
      {nil, timers} ->
        %{state | plan_timers: timers}

      {timer, timers} ->
        Process.cancel_timer(timer)
        %{state | plan_timers: timers}
    end
  end

  defp observe_wall_time(%Budget{} = usage, started_mono) do
    observed = max(System.monotonic_time(:millisecond) - started_mono, 0)
    %{usage | time_ms: max(usage.time_ms, observed)}
  end

  defp cancelled_child_attrs(child, reason, now, state) do
    case Map.get(state.running, child.id) do
      %{phase: :running} = entry ->
        {attrs, usage} = result_attrs(terminal_result(entry, reason, state), child)
        usage = observe_wall_time(usage, entry.started_mono)

        {attrs
         |> Map.put(:status, :cancelled)
         |> Map.put(:error, reason)
         |> Map.put(:usage, usage)
         |> Map.put(:resource_permit, nil)
         |> Map.put(:finished_at, now), usage}

      _entry ->
        {%{
           status: :cancelled,
           error: reason,
           usage: Budget.zero(),
           resource_permit: nil,
           finished_at: now
         }, Budget.zero()}
    end
  end

  defp terminal_result(%{phase: :running, child: child}, reason, state) do
    evidence =
      case cancel_runtime(child, state) do
        {:ok, %{runtime_stopped: true} = quiescence} ->
          %{usage: Budget.zero(), runtime_quiescence: quiescence}

        %{runtime_stopped: true} = quiescence ->
          %{usage: Budget.zero(), runtime_quiescence: quiescence}

        _other ->
          %{usage: Budget.zero()}
      end

    safe_workspace_finalize(child, {:error, reason, evidence}, state)
  end

  defp terminal_result(%{child: _child}, reason, _state),
    do: {:error, reason, Budget.zero()}

  defp safe_workspace_finalize(child, result, state) do
    try do
      state.workspace_finalize_fun.(child, result)
    catch
      kind, reason ->
        {:error, {:manager_workspace_finalizer_crashed, {kind, reason}}, Budget.zero()}
    end
  end

  defp cancel_runtime(child, state) do
    try do
      state.cancel_fun.(child)
    catch
      kind, reason -> {:error, {:manager_runtime_cancel_crashed, {kind, reason}}}
    end
  end

  defp queued_count(state), do: state.queues |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

  defp running_for_plan(state, plan_id),
    do: state.running |> Map.values() |> Enum.count(&(&1.child.plan_id == plan_id))

  defp plan_fanout(state, plan_id), do: fetch_plan!(state, plan_id).compiled_plan.plan.max_fanout

  defp fetch_plan!(state, plan_id) do
    {:ok, plan} = store(state, :get_plan, [plan_id])
    plan
  end

  defp deadline_ms(%DateTime{} = deadline),
    do: max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0)

  defp deadline_ms(_deadline), do: 0

  defp child_event(child),
    do: %{
      child_id: child.id,
      task_id: child.task_id,
      attempt: child.attempt,
      status: child.status,
      usage: child.usage
    }

  defp event(state, plan_id, type, data) do
    event = %{
      id: Twelvgaige.ID.new(:event),
      type: type,
      plan_id: plan_id,
      data: data,
      occurred_at: DateTime.utc_now()
    }

    _ = store(state, :append_event, [plan_id, event])
    :ok
  end

  defp store(state, function, args),
    do: apply(state.store, function, args ++ [[server: state.store_server]])
end
