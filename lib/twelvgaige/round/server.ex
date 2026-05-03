defmodule Twelvgaige.Round.Server do
  @moduledoc """
  Phase 1 round coordinator process.

  The default path still delegates to `Round.Runner` so durable runner behavior
  remains stable. Passing `scheduler?: true` enables the GenServer-owned shot
  scheduler path: ready shots are admitted by `ResourceLimiter`, executed in
  monitored tasks, and applied back to live round state from task result, crash,
  timeout, and retry messages.
  """

  use GenServer, restart: :transient

  alias Twelvgaige.Error
  alias Twelvgaige.ID
  alias Twelvgaige.Loadout
  alias Twelvgaige.Metrics
  alias Twelvgaige.Pattern.Compiler
  alias Twelvgaige.ResourceLimiter
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.InputValidator
  alias Twelvgaige.Round.Manifest
  alias Twelvgaige.Round.Recovery
  alias Twelvgaige.Round.Runner
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Round.State, as: RoundState
  alias Twelvgaige.RuntimeProfile
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shot
  alias Twelvgaige.Shot.Attempt
  alias Twelvgaige.Shot.AttemptJournal
  alias Twelvgaige.Shot.Executor, as: ShotExecutor
  alias Twelvgaige.Shot.RetryPolicy

  defstruct [
    :workflow,
    :input,
    :opts,
    :result,
    :round_state,
    :round_permit,
    awaiters: []
  ]

  @type t :: %__MODULE__{
          workflow: Workflow.t(),
          input: map(),
          opts: keyword(),
          result: {:ok, Snapshot.t()} | {:error, Twelvgaige.Error.t()} | nil,
          round_state: RoundState.t() | nil,
          round_permit: ResourceLimiter.Permit.t() | nil,
          awaiters: [GenServer.from()]
        }

  @spec run_sync(Workflow.t(), map(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Twelvgaige.Error.t()}
  def run_sync(%Workflow{} = workflow, input, opts \\ []) when is_map(input) do
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, pid} <- start_round(workflow, input, opts) do
      result = GenServer.call(pid, :await, timeout)
      maybe_stop_after_await(pid, result, opts)
      result
    end
  end

  @spec recover_sync(Workflow.t(), Snapshot.t() | map(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Twelvgaige.Error.t()}
  def recover_sync(%Workflow{} = workflow, snapshot, opts \\ []) when is_list(opts) do
    snapshot = Snapshot.new(snapshot)

    case Recovery.reconcile(snapshot, Keyword.take(opts, [:journals, :now])) do
      {:keep, %Snapshot{} = snapshot} ->
        {:ok, snapshot}

      {:commit, %Snapshot{} = snapshot} ->
        commit_recovery_snapshot(snapshot, opts)

      {:resume, %Snapshot{} = snapshot} ->
        run_recovered_snapshot(workflow, snapshot, opts)

      {:commit_and_resume, %Snapshot{} = snapshot} ->
        with {:ok, snapshot} <- commit_recovery_snapshot(snapshot, opts) do
          run_recovered_snapshot(workflow, snapshot, opts)
        end
    end
  end

  @spec approve_safety_sync(Workflow.t(), Snapshot.t() | map(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Twelvgaige.Error.t()}
  def approve_safety_sync(%Workflow{} = workflow, snapshot, shot_id, opts \\ [])
      when is_binary(shot_id) and is_list(opts) do
    resume_safety_sync(workflow, snapshot, shot_id, :approved, opts)
  end

  @spec reject_safety_sync(Workflow.t(), Snapshot.t() | map(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Twelvgaige.Error.t()}
  def reject_safety_sync(%Workflow{} = workflow, snapshot, shot_id, opts \\ [])
      when is_binary(shot_id) and is_list(opts) do
    resume_safety_sync(workflow, snapshot, shot_id, :rejected, opts)
  end

  defp resume_safety_sync(workflow, snapshot, shot_id, decision, opts) do
    snapshot = Snapshot.new(snapshot)
    timeout = Keyword.get(opts, :timeout, 30_000)

    with {:ok, profile} <- RuntimeProfile.from_snapshot(snapshot, opts) do
      opts =
        opts
        |> Keyword.put(:scheduler?, true)
        |> Keyword.put(:round_id, snapshot.id)
        |> Keyword.put(:recovery_snapshot, snapshot)
        |> Keyword.put(:profile, profile)

      case start_round(workflow, snapshot.input, opts) do
        {:ok, pid} ->
          result =
            case GenServer.call(pid, {:safety_decision, shot_id, decision, opts}, timeout) do
              :ok -> GenServer.call(pid, :await, timeout)
              {:error, _reason} = error -> error
            end

          maybe_stop_after_await(pid, result, Keyword.put(opts, :stop_after_await?, true))
          result

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp run_recovered_snapshot(workflow, %Snapshot{} = snapshot, opts) do
    with {:ok, profile} <- RuntimeProfile.from_snapshot(snapshot, opts) do
      opts =
        opts
        |> Keyword.put(:scheduler?, true)
        |> Keyword.put(:round_id, snapshot.id)
        |> Keyword.put(:recovery_snapshot, snapshot)
        |> Keyword.put(:profile, profile)

      run_sync(workflow, snapshot.input, opts)
    end
  end

  defp commit_recovery_snapshot(%Snapshot{} = snapshot, opts) do
    case Keyword.get(opts, :store) do
      nil ->
        {:ok, snapshot}

      store ->
        transition_id = ID.transition_id()
        now = Twelvgaige.Clock.utc_now()

        event =
          Event.new(
            round_id: snapshot.id,
            transition_id: transition_id,
            round_version: snapshot.version + 1,
            event_type: event_type(snapshot.status),
            payload: %{status: snapshot.status, recovery: true},
            occurred_at: now
          )

        audit_event = %{
          event_type: :round_recovery_transition,
          round_id: snapshot.id,
          actor: "system",
          payload: %{
            transition_id: transition_id,
            round_version: snapshot.version + 1,
            status: snapshot.status
          },
          occurred_at: now
        }

        case store.commit_transition(
               snapshot.id,
               snapshot.version,
               transition_id,
               snapshot,
               [event],
               [audit_event]
             ) do
          status when status in [:ok, :already_committed] ->
            {:ok, %{snapshot | version: snapshot.version + 1, store_status: :ok}}

          {:error, reason} ->
            {:error, store_error("failed to commit recovery snapshot", snapshot.id, reason)}
        end
    end
  rescue
    error ->
      {:error, store_error("failed to commit recovery snapshot", snapshot.id, error)}
  end

  @spec cancel(GenServer.server(), keyword()) :: :ok | {:error, term()}
  def cancel(server, opts \\ []) when is_list(opts) do
    GenServer.call(server, {:cancel, opts})
  end

  @spec approve_safety(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def approve_safety(server, shot_id, opts \\ []) when is_binary(shot_id) and is_list(opts) do
    GenServer.call(server, {:safety_decision, shot_id, :approved, opts})
  end

  @spec reject_safety(GenServer.server(), String.t(), keyword()) :: :ok | {:error, term()}
  def reject_safety(server, shot_id, opts \\ []) when is_binary(shot_id) and is_list(opts) do
    GenServer.call(server, {:safety_decision, shot_id, :rejected, opts})
  end

  @spec snapshot(GenServer.server()) :: {:ok, Snapshot.t()} | {:error, term()}
  def snapshot(server) do
    GenServer.call(server, :snapshot)
  end

  @spec start_link({Workflow.t(), map(), keyword()}) :: GenServer.on_start()
  def start_link({%Workflow{} = workflow, input, opts}) when is_map(input) do
    GenServer.start_link(__MODULE__, {workflow, input, opts})
  end

  @impl true
  def init({workflow, input, opts}) do
    opts = Keyword.put_new_lazy(opts, :round_id, fn -> Twelvgaige.ID.new(:round) end)
    state = %__MODULE__{workflow: workflow, input: input, opts: opts}
    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    if Keyword.get(state.opts, :scheduler?, false) do
      case with_effective_profile(state) do
        {:ok, state} -> {:noreply, start_scheduled_round(state)}
        {:error, %Error{} = error} -> {:noreply, finish_result(state, {:error, error})}
      end
    else
      {:noreply, finish_result(state, run_with_round_permit(state))}
    end
  end

  @impl true
  def handle_call(
        :await,
        _from,
        %{result: nil, round_state: %RoundState{status: :awaiting_safety} = round_state} = state
      ) do
    {:reply, {:ok, RoundState.to_snapshot(round_state)}, state}
  end

  def handle_call(:await, from, %{result: nil} = state) do
    {:noreply, %{state | awaiters: [from | state.awaiters]}}
  end

  def handle_call(:await, _from, %{result: result} = state) do
    {:reply, result, state}
  end

  def handle_call({:cancel, _opts}, _from, %{result: result} = state) when not is_nil(result) do
    {:reply, :ok, state}
  end

  def handle_call({:cancel, opts}, _from, %{round_state: %RoundState{}} = state) do
    {:reply, :ok, cancel_scheduled_round(state, opts)}
  end

  def handle_call({:cancel, _opts}, _from, state) do
    {:reply, {:error, :not_started}, state}
  end

  def handle_call({:safety_decision, shot_id, decision, opts}, _from, state) do
    case apply_external_safety_decision(state, shot_id, decision, opts) do
      {:ok, state} -> {:reply, :ok, chamber(state)}
      {:terminal, state} -> {:reply, :ok, state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  def handle_call(:snapshot, _from, %{round_state: %RoundState{} = round_state} = state) do
    {:reply, {:ok, RoundState.to_snapshot(round_state)}, state}
  end

  def handle_call(:snapshot, _from, %{result: {:ok, %Snapshot{} = snapshot}} = state) do
    {:reply, {:ok, snapshot}, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply, {:error, :not_started}, state}
  end

  @impl true
  def handle_info({ref, {:shot_result, shot_id, attempt, result}}, state)
      when is_reference(ref) do
    case fetch_inflight_by_ref(state, ref) do
      {:ok, entry} ->
        state =
          if entry.shot_id == shot_id and entry.attempt == attempt do
            state
            |> drop_inflight(entry)
            |> apply_shot_result(entry, result)
            |> chamber()
          else
            state
          end

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case fetch_inflight_by_monitor(state, ref, pid) do
      {:ok, _entry} when reason == :normal ->
        {:noreply, state}

      {:ok, entry} ->
        error = shot_crash_error(entry, reason)

        state =
          state
          |> drop_inflight(entry)
          |> finish_attempt(entry, :failed, {:error, error})
          |> apply_attempt_error(entry.shot, entry.current, entry.attempt, error)
          |> chamber()

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:shot_timeout, shot_id, attempt, timeout_ref}, state) do
    case fetch_inflight_by_shot(state, shot_id, attempt) do
      {:ok, %{timeout_ref: ^timeout_ref} = entry} ->
        Process.exit(entry.pid, :kill)

        error =
          Error.new(:timeout_error, :shot_timeout, "shot execution timed out",
            retryable: true,
            details: %{round_id: entry.round_id, shot_id: shot_id, attempt: attempt}
          )

        state =
          state
          |> drop_inflight(entry, demonitor?: true)
          |> finish_attempt(entry, :failed, {:error, error})
          |> apply_attempt_error(entry.shot, entry.current, entry.attempt, error)
          |> chamber()

        {:noreply, state}

      _stale ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_ready, shot_id, attempt}, state) do
    case state.round_state do
      %RoundState{shot_states: shot_states} ->
        case Map.fetch(shot_states, shot_id) do
          {:ok, %{status: :retrying, attempt: ^attempt}} -> {:noreply, chamber(state)}
          _other -> {:noreply, state}
        end

      _other ->
        {:noreply, state}
    end
  end

  def handle_info({:resource_available, waiter_id, resource_kind}, state) do
    case fetch_waiter(state, waiter_id, resource_kind) do
      {:ok, %{start_mode: :committed_after_store} = entry} ->
        state =
          state
          |> drop_inflight(entry)
          |> start_committed_shot_after_store(
            entry.shot,
            entry.current,
            entry.attempt,
            entry.attempt_input
          )
          |> chamber()

        {:noreply, state}

      {:ok, entry} ->
        state =
          state
          |> drop_inflight(entry)
          |> start_executable_shot(entry.shot, entry.attempt)
          |> chamber()

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:resource_timeout, waiter_id, resource_kind}, state) do
    case fetch_waiter(state, waiter_id, resource_kind) do
      {:ok, entry} ->
        error = resource_queue_timeout_error(entry.context)

        state =
          state
          |> drop_inflight(entry)
          |> apply_attempt_error(entry.shot, entry.current, entry.attempt, error)
          |> chamber()

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_store_commit, transition_id}, state) do
    {:noreply, retry_pending_store_commit(state, transition_id)}
  end

  defp start_round(workflow, input, opts) do
    if Keyword.get(opts, :supervised?, true) == false do
      start_link({workflow, input, opts})
    else
      case Process.whereis(Twelvgaige.Round.Supervisor) do
        nil -> start_link({workflow, input, opts})
        _pid -> Twelvgaige.Round.Supervisor.start_round(workflow, input, opts)
      end
    end
  end

  defp maybe_stop_after_await(pid, result, opts) do
    if Keyword.get(opts, :stop_after_await?, false) and await_result_stoppable?(result) and
         Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end
  end

  defp await_result_stoppable?({:ok, %Snapshot{status: :awaiting_safety}}), do: true
  defp await_result_stoppable?({:ok, %Snapshot{} = snapshot}), do: Snapshot.terminal?(snapshot)
  defp await_result_stoppable?({:error, %Error{}}), do: true
  defp await_result_stoppable?(_result), do: false

  defp with_effective_profile(state) do
    case Keyword.get(state.opts, :recovery_snapshot) do
      nil -> RuntimeProfile.effective(state.workflow.policy, state.opts)
      snapshot -> RuntimeProfile.from_snapshot(Snapshot.new(snapshot), state.opts)
    end
    |> case do
      {:ok, profile} -> {:ok, %{state | opts: Keyword.put(state.opts, :profile, profile)}}
      {:error, _reason} = error -> error
    end
  end

  defp start_scheduled_round(state) do
    started_mono = monotonic_ms()

    result =
      with :ok <- InputValidator.validate(state.workflow, state.input),
           {:ok, compiled} <- Compiler.compile(state.workflow, compiler_opts(state.opts)),
           {:ok, round_state} <- initial_round_state(state, compiled),
           {:ok, permit} <- acquire_round_permit(state) do
        {:scheduled, permit, round_state}
      end

    case result do
      {:scheduled, permit, round_state} ->
        state = Map.merge(state, %{round_permit: permit, round_state: round_state})

        with {:ok, state} <- ensure_scheduler_store_round(state) do
          case state.round_state.status do
            status when status in [:queued, :chambered] ->
              firing = %{state.round_state | status: :firing}
              transition_round_state(state, firing, :round_started, :chamber)

            _status ->
              chamber(state)
          end
        else
          {:error, %Error{} = error} ->
            release_round_permit(permit)
            result = {:error, error}
            record_round_metrics(result, state.workflow.id, started_mono, state.opts)
            finish_result(state, result)
        end

      {:error, %Error{} = error} ->
        result = {:error, error}
        record_round_metrics(result, state.workflow.id, started_mono, state.opts)
        finish_result(state, result)
    end
  end

  defp chamber(%{result: result} = state) when not is_nil(result), do: state

  defp chamber(%{round_state: %RoundState{status: :blocked_on_store}} = state), do: state

  defp chamber(%{round_state: %RoundState{} = round_state} = state) do
    cond do
      RoundState.terminal?(round_state) ->
        complete_from_state(state)

      failed = failed_shot(round_state) ->
        fail_from_state(
          state,
          failed.error || Error.new(:internal_error, :shot_crash, "shot failed")
        )

      RoundState.all_shots_successful?(round_state) and inflight_empty?(round_state) ->
        complete_from_state(state)

      true ->
        schedule_ready_or_wait(state)
    end
  end

  defp schedule_ready_or_wait(state) do
    case Compiler.readiness(state.round_state.pattern, state.round_state.shot_states, %{
           input: state.round_state.input
         }) do
      {:ok, %{skipped: skipped_shots}} when skipped_shots != [] ->
        round_state = skip_shots(state.round_state, skipped_shots)
        transition_round_state(state, round_state, :shots_skipped, :chamber)

      {:ok, %{ready: ready_shots}} ->
        ready_shots =
          Enum.reject(ready_shots, fn shot ->
            shot.id in inflight_shot_ids(state.round_state)
          end)

        cond do
          ready_shots != [] ->
            ready_shots
            |> Enum.reduce(state, &start_ready_shot(&2, &1))
            |> chamber()

          awaiting_safety?(state.round_state) or not inflight_empty?(state.round_state) ->
            state

          true ->
            fail_from_state(
              state,
              Error.new(:internal_error, :shot_crash, "round made no progress")
            )
        end

      {:error, %Error{} = error} ->
        fail_from_state(state, error)
    end
  end

  defp skip_shots(%RoundState{} = round_state, shots) do
    now = Twelvgaige.Clock.utc_now()

    Enum.reduce(shots, round_state, fn shot, acc ->
      skipped =
        acc.shot_states
        |> Map.fetch!(shot.id)
        |> Map.merge(%{
          status: :skipped,
          output: %{"skipped" => true},
          completed_at: now
        })

      RoundState.put_shot(acc, skipped)
    end)
  end

  defp start_ready_shot(%{result: result} = state, _shot) when not is_nil(result), do: state

  defp start_ready_shot(%{round_state: %RoundState{status: :blocked_on_store}} = state, _shot),
    do: state

  defp start_ready_shot(state, %{kind: :safety} = shot), do: apply_safety_shot(state, shot)
  defp start_ready_shot(state, shot), do: start_executable_shot(state, shot)

  defp start_executable_shot(state, shot, forced_attempt \\ nil) do
    current = Map.fetch!(state.round_state.shot_states, shot.id)
    attempt = forced_attempt || current.attempt + 1

    case acquire_shot_permit(state.round_state, shot, attempt, state.opts) do
      {:ok, permit} ->
        start_admitted_shot(state, shot, current, attempt, permit)

      {:queued, waiter, context} ->
        put_resource_waiter(state, waiter, shot, current, attempt, context)

      {:error, %Error{} = error} ->
        apply_attempt_error(state, shot, current, attempt, error)
    end
  end

  defp start_admitted_shot(state, shot, current, attempt, permit) do
    running = %{
      current
      | status: :running,
        attempt: attempt,
        started_at: Twelvgaige.Clock.utc_now()
    }

    round_state = RoundState.put_shot(state.round_state, running)

    attempt_input =
      Attempt.new(
        round_id: round_state.id,
        shot_id: shot.id,
        attempt: attempt,
        definition: shot,
        loadout: Loadout.for_shot(shot, state.opts),
        input: round_state.input,
        dependency_outputs: dependency_outputs(round_state, shot)
      )

    transition_round_state(
      state,
      round_state,
      :shot_started,
      {:start_shot, shot, running, attempt, attempt_input, permit}
    )
  end

  defp start_shot_task(shot, attempt, attempt_input, opts) do
    fun = fn ->
      {:shot_result, shot.id, attempt,
       ShotExecutor.run(attempt_input, shot_executor_opts(opts, attempt))}
    end

    case Keyword.get(opts, :shot_task_starter) do
      starter when is_function(starter, 1) -> normalize_task_start(starter.(fun))
      starter when is_function(starter, 2) -> normalize_task_start(starter.(fun, opts))
      _other -> default_start_shot_task(fun, opts)
    end
  end

  defp default_start_shot_task(fun, opts) do
    supervisor = Keyword.get(opts, :task_supervisor, Twelvgaige.Breech.TaskSupervisor)

    if task_supervisor_available?(supervisor) do
      task = Task.Supervisor.async_nolink(supervisor, fun)
      {:ok, %{pid: task.pid, result_ref: task.ref, monitor_ref: task.ref}}
    else
      parent = self()
      result_ref = make_ref()

      pid =
        spawn(fn ->
          send(parent, {result_ref, fun.()})
        end)

      monitor_ref = Process.monitor(pid)
      {:ok, %{pid: pid, result_ref: result_ref, monitor_ref: monitor_ref}}
    end
  end

  defp normalize_task_start({:ok, %{pid: pid, result_ref: result_ref, monitor_ref: monitor_ref}})
       when is_pid(pid) and is_reference(result_ref) and is_reference(monitor_ref) do
    {:ok, %{pid: pid, result_ref: result_ref, monitor_ref: monitor_ref}}
  end

  defp normalize_task_start({:ok, %Task{} = task}) do
    {:ok, %{pid: task.pid, result_ref: task.ref, monitor_ref: task.ref}}
  end

  defp normalize_task_start({:error, _reason} = error), do: error
  defp normalize_task_start(other), do: {:error, other}

  defp task_supervisor_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp task_supervisor_available?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp task_supervisor_available?(_supervisor), do: false

  defp shot_timeout(%{timeout_ms: nil}, _attempt), do: nil

  defp shot_timeout(shot, attempt) do
    timeout_ref = make_ref()

    timer_ref =
      Process.send_after(self(), {:shot_timeout, shot.id, attempt, timeout_ref}, shot.timeout_ms)

    %{ref: timeout_ref, timer_ref: timer_ref}
  end

  defp put_resource_waiter(state, waiter, shot, current, attempt, context, extra \\ []) do
    entry =
      %{
        type: :resource_waiter,
        waiter: waiter,
        shot_id: shot.id,
        attempt: attempt,
        shot: shot,
        current: current,
        context: context
      }
      |> Map.merge(Map.new(extra))

    put_inflight(state, entry)
  end

  defp put_inflight(state, %{type: :task, result_ref: result_ref} = entry) do
    update_in(state.round_state.inflight, &Map.put(&1, result_ref, entry))
  end

  defp put_inflight(state, %{type: :resource_waiter, waiter: waiter} = entry) do
    update_in(state.round_state.inflight, &Map.put(&1, {:waiter, waiter.id}, entry))
  end

  defp drop_inflight(state, entry, opts \\ []) do
    entry = cancel_inflight_side_effects(entry, opts)
    update_in(state.round_state.inflight, &Map.delete(&1, inflight_key(entry)))
  end

  defp cancel_inflight_side_effects(%{type: :task} = entry, opts) do
    if Keyword.get(opts, :cancel_timer?, true), do: cancel_timer(entry.timer_ref)
    if Keyword.get(opts, :demonitor?, false), do: demonitor(entry.monitor_ref)
    release_shot_permit(entry.permit)
    entry
  end

  defp cancel_inflight_side_effects(%{type: :resource_waiter} = entry, opts) do
    if Keyword.get(opts, :cancel_waiter?, false), do: ResourceLimiter.cancel_waiter(entry.waiter)
    entry
  end

  defp inflight_key(%{type: :task, result_ref: result_ref}), do: result_ref
  defp inflight_key(%{type: :resource_waiter, waiter: waiter}), do: {:waiter, waiter.id}

  defp fetch_inflight_by_ref(state, ref) do
    case state.round_state do
      %RoundState{} -> Map.fetch(state.round_state.inflight, ref)
      _other -> :error
    end
  end

  defp fetch_inflight_by_monitor(state, monitor_ref, pid) do
    with %RoundState{} <- state.round_state do
      Enum.find_value(state.round_state.inflight, :error, fn
        {_key, %{type: :task, monitor_ref: ^monitor_ref, pid: ^pid} = entry} -> {:ok, entry}
        _other -> nil
      end)
    else
      _other -> :error
    end
  end

  defp fetch_inflight_by_shot(state, shot_id, attempt) do
    with %RoundState{} <- state.round_state do
      Enum.find_value(state.round_state.inflight, :error, fn
        {_key, %{type: :task, shot_id: ^shot_id, attempt: ^attempt} = entry} -> {:ok, entry}
        _other -> nil
      end)
    else
      _other -> :error
    end
  end

  defp fetch_waiter(state, waiter_id, resource_kind) do
    with %RoundState{} <- state.round_state,
         {:ok, %{type: :resource_waiter, waiter: waiter} = entry} <-
           Map.fetch(state.round_state.inflight, {:waiter, waiter_id}),
         true <- waiter.resource_kind == resource_kind do
      {:ok, entry}
    else
      _other -> :error
    end
  end

  defp apply_shot_result(state, entry, result) do
    record_shot_metrics(entry.shot, result, entry.started_mono, state.opts)

    case result do
      {:ok, result} ->
        case finish_attempt(state, entry, :completed, {:ok, result}) do
          %{result: nil} = state -> complete_shot(state, entry.current, result)
          state -> state
        end

      {:error, %Error{} = error} ->
        case finish_attempt(state, entry, :failed, {:error, error}) do
          %{result: nil} = state ->
            apply_attempt_error(state, entry.shot, entry.current, entry.attempt, error)

          state ->
            state
        end
    end
  end

  defp complete_shot(state, running, result) do
    completed = %{
      running
      | status: :complete,
        completed_at: Twelvgaige.Clock.utc_now(),
        output: %{
          "content" => result.content,
          "structured" => result.output,
          "tool_calls" => result.tool_calls,
          "usage" => result.usage
        }
    }

    round_state = RoundState.put_shot(state.round_state, completed)
    transition_round_state(state, round_state, :shot_completed)
  end

  defp apply_attempt_error(state, shot, running, attempt, %Error{} = error) do
    running = %{running | status: :running, attempt: attempt}

    if RetryPolicy.retry?(shot.retry, error, attempt) do
      retrying =
        %{
          running
          | status: :retrying,
            error: error,
            next_retry_at: RetryPolicy.next_retry_at(shot.retry, attempt),
            history: retry_history(running, error)
        }

      delay_ms = RetryPolicy.next_delay_ms(shot.retry, attempt)
      Process.send_after(self(), {:retry_ready, shot.id, attempt}, delay_ms)
      round_state = RoundState.put_shot(state.round_state, retrying)
      transition_round_state(state, round_state, :shot_retrying)
    else
      failed =
        %{
          running
          | status: :failed,
            error: error,
            completed_at: Twelvgaige.Clock.utc_now(),
            history: retry_history(running, error)
        }

      round_state = RoundState.put_shot(state.round_state, failed)
      transition_round_state(state, round_state, :shot_failed)
    end
  end

  defp apply_safety_shot(state, shot) do
    request = safety_request(state.round_state, shot)

    case safety_decision(request, state.opts) do
      {:approved, reason, actor} ->
        record_safety_decision(:approved, state.opts)
        current = Map.fetch!(state.round_state.shot_states, shot.id)

        shot_state = %{
          current
          | status: :complete,
            attempt: 0,
            output: safety_output("approved", reason, actor),
            completed_at: Twelvgaige.Clock.utc_now()
        }

        round_state = RoundState.put_shot(state.round_state, shot_state)
        transition_round_state(state, round_state, :safety_approved)

      {:rejected, reason, actor} ->
        record_safety_decision(:rejected, state.opts)

        error =
          Error.new(:policy_error, :safety_rejected, "safety shot #{shot.id} was rejected",
            safety_required: true,
            details: %{shot_id: shot.id, reason: reason, actor: actor}
          )

        current = Map.fetch!(state.round_state.shot_states, shot.id)

        shot_state = %{
          current
          | status: :failed,
            attempt: 0,
            output: safety_output("rejected", reason, actor),
            error: error,
            completed_at: Twelvgaige.Clock.utc_now()
        }

        round_state =
          state.round_state
          |> RoundState.put_shot(shot_state)
          |> Map.put(:status, rejected_round_status(state.round_state))
          |> Map.put(:completed_at, Twelvgaige.Clock.utc_now())
          |> Map.put(:error, error)

        transition_round_state(
          state,
          round_state,
          :round_safety_rejected,
          {:finish, {:failure, error}}
        )

      :await ->
        current = Map.fetch!(state.round_state.shot_states, shot.id)

        shot_state = %{
          current
          | status: :awaiting_safety,
            attempt: 0,
            output: safety_output("awaiting", nil, nil),
            started_at: Twelvgaige.Clock.utc_now()
        }

        round_state =
          state.round_state
          |> RoundState.put_shot(shot_state)
          |> Map.merge(%{
            status: :awaiting_safety,
            awaiting_safety: [request | state.round_state.awaiting_safety]
          })

        state
        |> transition_round_state(round_state, :safety_awaiting, :pause_safety)
    end
  end

  defp apply_external_safety_decision(state, shot_id, decision, opts) do
    with {:ok, request} <- awaiting_safety_request(state.round_state, shot_id),
         {:ok, shot_state} <- awaiting_safety_shot(state.round_state, shot_id) do
      apply_external_safety_decision(state, shot_state, request, decision, opts)
    end
  end

  defp apply_external_safety_decision(state, shot_state, request, :approved, opts) do
    with {:ok, state} <- ensure_round_permit(state) do
      record_safety_decision(:approved, opts)

      reason = Keyword.get(opts, :reason)
      actor = Keyword.get(opts, :actor, "human")

      shot_state =
        %{
          shot_state
          | status: :complete,
            output: safety_output("approved", reason, actor),
            completed_at: Twelvgaige.Clock.utc_now()
        }

      round_state =
        state.round_state
        |> RoundState.put_shot(shot_state)
        |> Map.merge(%{
          status: :firing,
          awaiting_safety:
            drop_awaiting_safety(state.round_state.awaiting_safety, request["shot_id"])
        })

      {:ok, transition_round_state(state, round_state, :safety_approved)}
    end
  end

  defp apply_external_safety_decision(state, shot_state, request, :rejected, opts) do
    record_safety_decision(:rejected, opts)

    reason = Keyword.get(opts, :reason)
    actor = Keyword.get(opts, :actor, "human")

    error =
      Error.new(:policy_error, :safety_rejected, "safety shot #{request["shot_id"]} was rejected",
        safety_required: true,
        details: %{shot_id: request["shot_id"], reason: reason, actor: actor}
      )

    shot_state =
      %{
        shot_state
        | status: :failed,
          output: safety_output("rejected", reason, actor),
          error: error,
          completed_at: Twelvgaige.Clock.utc_now()
      }

    round_state =
      state.round_state
      |> RoundState.put_shot(shot_state)
      |> Map.merge(%{
        status: rejected_round_status(state.round_state),
        completed_at: Twelvgaige.Clock.utc_now(),
        error: error,
        awaiting_safety:
          drop_awaiting_safety(state.round_state.awaiting_safety, request["shot_id"])
      })

    state =
      transition_round_state(
        state,
        round_state,
        :round_safety_rejected,
        {:finish, {:failure, error}}
      )

    {:terminal, state}
  end

  defp apply_external_safety_decision(_state, _shot_state, _request, _decision, _opts) do
    {:error,
     Error.new(:policy_error, :policy_denied, "unknown safety decision",
       details: %{decision: "unknown"}
     )}
  end

  defp awaiting_safety_request(
         %RoundState{status: :awaiting_safety, awaiting_safety: awaiting},
         shot_id
       ) do
    case Enum.find(awaiting, &(Map.get(&1, "shot_id") == shot_id)) do
      nil ->
        {:error,
         Error.new(:policy_error, :policy_denied, "safety shot is not awaiting approval",
           details: %{shot_id: shot_id}
         )}

      request ->
        {:ok, request}
    end
  end

  defp awaiting_safety_request(%RoundState{} = round_state, shot_id) do
    {:error,
     Error.new(:policy_error, :policy_denied, "round is not awaiting safety approval",
       details: %{shot_id: shot_id, status: round_state.status}
     )}
  end

  defp awaiting_safety_request(_round_state, shot_id) do
    {:error,
     Error.new(:policy_error, :policy_denied, "round is not awaiting safety approval",
       details: %{shot_id: shot_id}
     )}
  end

  defp awaiting_safety_shot(%RoundState{} = round_state, shot_id) do
    case Map.fetch(round_state.shot_states, shot_id) do
      {:ok, %{kind: :safety, status: :awaiting_safety} = shot_state} ->
        {:ok, shot_state}

      {:ok, %{kind: :safety}} ->
        {:error,
         Error.new(:policy_error, :policy_denied, "safety shot is not awaiting approval",
           details: %{shot_id: shot_id}
         )}

      {:ok, _shot_state} ->
        {:error,
         Error.new(:policy_error, :policy_denied, "target shot is not a safety shot",
           details: %{shot_id: shot_id}
         )}

      :error ->
        {:error,
         Error.new(:policy_error, :policy_denied, "unknown safety shot",
           details: %{shot_id: shot_id}
         )}
    end
  end

  defp ensure_round_permit(%{round_permit: %ResourceLimiter.Permit{}} = state), do: {:ok, state}

  defp ensure_round_permit(state) do
    case acquire_round_permit(state) do
      {:ok, permit} -> {:ok, %{state | round_permit: permit}}
      {:error, _error} = error -> error
    end
  end

  defp finish_attempt(state, entry, status, outcome) do
    case record_attempt_finished(entry.attempt_input, status, outcome, state.opts) do
      :ok ->
        state

      {:error, %Error{} = error} ->
        finish_result(state, {:error, error})
    end
  end

  defp record_attempt_started(%Attempt{} = attempt, opts) do
    case Keyword.get(opts, :store) do
      nil ->
        :ok

      store ->
        journal = AttemptJournal.new(attempt)

        case store.record_attempt_started(journal, [AttemptJournal.audit_event(journal)]) do
          status when status in [:ok, :already_recorded] ->
            :ok

          {:error, reason} ->
            {:error,
             Error.new(:store_error, :store_unavailable, "failed to record shot attempt start",
               retryable: true,
               details: %{
                 round_id: attempt.round_id,
                 shot_id: attempt.shot_id,
                 attempt: attempt.attempt,
                 reason: inspect(reason)
               }
             )}
        end
    end
  rescue
    error ->
      {:error,
       Error.new(:store_error, :store_unavailable, "failed to record shot attempt start",
         retryable: true,
         details: %{
           round_id: attempt.round_id,
           shot_id: attempt.shot_id,
           attempt: attempt.attempt,
           reason: Exception.message(error)
         }
       )}
  end

  defp record_attempt_finished(%Attempt{} = attempt, status, outcome, opts) do
    case Keyword.get(opts, :store) do
      nil ->
        :ok

      store ->
        journal = AttemptJournal.finish(attempt, status, outcome)

        case store.record_attempt_finished(journal, [AttemptJournal.audit_event(journal)]) do
          status when status in [:ok, :already_recorded] ->
            :ok

          {:error, reason} ->
            {:error,
             Error.new(:store_error, :store_unavailable, "failed to record shot attempt result",
               retryable: true,
               details: %{
                 round_id: attempt.round_id,
                 shot_id: attempt.shot_id,
                 attempt: attempt.attempt,
                 reason: inspect(reason)
               }
             )}
        end
    end
  rescue
    error ->
      {:error,
       Error.new(:store_error, :store_unavailable, "failed to record shot attempt result",
         retryable: true,
         details: %{
           round_id: attempt.round_id,
           shot_id: attempt.shot_id,
           attempt: attempt.attempt,
           reason: Exception.message(error)
         }
       )}
  end

  defp ensure_scheduler_store_round(state) do
    case Keyword.get(state.opts, :store) do
      nil ->
        {:ok, state}

      store ->
        if Keyword.has_key?(state.opts, :recovery_snapshot) do
          {:ok, state}
        else
          snapshot = RoundState.to_snapshot(state.round_state)
          manifest = state.round_state.manifest

          case store.create_round(snapshot, manifest, []) do
            :ok ->
              {:ok, state}

            {:error, :round_already_exists} ->
              reload_scheduler_round(state)

            {:error, reason} ->
              {:error,
               store_error("failed to create scheduler round", state.round_state.id, reason)}
          end
        end
    end
  rescue
    error ->
      {:error, store_error("failed to create scheduler round", state.round_state.id, error)}
  end

  defp reload_scheduler_round(state) do
    store = Keyword.fetch!(state.opts, :store)

    with {:ok, snapshot} <- store.get_round(state.round_state.id) do
      snapshot = Snapshot.new(snapshot)

      round_state =
        RoundState.from_snapshot(snapshot,
          pattern: state.round_state.pattern,
          manifest: state.round_state.manifest
        )

      {:ok, %{state | round_state: round_state}}
    else
      {:error, reason} ->
        {:error,
         store_error("failed to load existing scheduler round", state.round_state.id, reason)}
    end
  end

  defp transition_round_state(state, %RoundState{} = next_round_state, event_type) do
    transition_round_state(state, next_round_state, event_type, :none)
  end

  defp transition_round_state(state, %RoundState{} = next_round_state, event_type, after_commit) do
    case Keyword.get(state.opts, :store) do
      nil ->
        state
        |> Map.put(:round_state, %{next_round_state | store_status: :ok, pending_transition: nil})
        |> apply_after_commit(after_commit)

      store ->
        commit_transition(state, store, %{
          transition_id: ID.transition_id(),
          expected_version: state.round_state.version,
          event_type: event_type,
          next_round_state: next_round_state,
          after_commit: after_commit
        })
    end
  end

  defp retry_pending_store_commit(
         %{
           round_state: %RoundState{pending_transition: %{transition_id: transition_id} = pending}
         } =
           state,
         transition_id
       ) do
    case Keyword.get(state.opts, :store) do
      nil -> state
      store -> commit_transition(state, store, pending)
    end
  end

  defp retry_pending_store_commit(state, _transition_id), do: state

  defp commit_transition(state, store, pending) do
    event = transition_event(state.round_state, pending)
    audit_event = transition_audit_event(state.round_state, pending, event)

    try do
      case store.commit_transition(
             state.round_state.id,
             pending.expected_version,
             pending.transition_id,
             RoundState.to_snapshot(pending.next_round_state),
             [event],
             [audit_event]
           ) do
        status when status in [:ok, :already_committed] ->
          committed =
            pending.next_round_state
            |> Map.put(:version, pending.expected_version + 1)
            |> Map.put(:store_status, :ok)
            |> Map.put(:pending_transition, nil)

          state
          |> Map.put(:round_state, committed)
          |> apply_after_commit(pending.after_commit)

        {:error, :version_conflict} ->
          reconcile_version_conflict(state)

        {:error, reason} ->
          block_on_store(state, pending, reason)
      end
    rescue
      error ->
        block_on_store(state, pending, error)
    catch
      :exit, reason ->
        block_on_store(state, pending, reason)
    end
  end

  defp block_on_store(state, pending, reason) do
    pending = cleanup_pending_after_store_block(pending)

    Process.send_after(
      self(),
      {:retry_store_commit, pending.transition_id},
      store_retry_ms(state.opts)
    )

    error_status = %{
      status: :error,
      reason: inspect(reason),
      transition_id: pending.transition_id,
      blocked_at: DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }

    blocked =
      state.round_state
      |> Map.put(:status, :blocked_on_store)
      |> Map.put(:store_status, error_status)
      |> Map.put(:pending_transition, pending)

    %{state | round_state: blocked}
  end

  defp cleanup_pending_after_store_block(
         %{after_commit: {:start_shot, shot, running, attempt, attempt_input, permit}} = pending
       ) do
    release_shot_permit(permit)

    %{
      pending
      | after_commit: {:start_shot_after_store, shot, running, attempt, attempt_input}
    }
  end

  defp cleanup_pending_after_store_block(pending), do: pending

  defp reconcile_version_conflict(state) do
    case reload_scheduler_round(state) do
      {:ok, state} -> chamber(state)
      {:error, %Error{} = error} -> fail_from_state(state, error)
    end
  end

  defp apply_after_commit(state, :none), do: state
  defp apply_after_commit(state, :chamber), do: chamber(state)
  defp apply_after_commit(state, :pause_safety), do: pause_for_safety(state)

  defp apply_after_commit(state, {:finish, :success}) do
    result = {:ok, RoundState.to_snapshot(state.round_state)}

    record_round_metrics(
      result,
      state.workflow.id,
      started_mono_from_round(state.round_state),
      state.opts
    )

    finish_result(state, result)
  end

  defp apply_after_commit(state, {:finish, {:failure, %Error{} = error}}) do
    snapshot = state.round_state |> RoundState.to_snapshot() |> Map.put(:error, error)
    result = {:ok, snapshot}

    record_round_metrics(
      result,
      state.workflow.id,
      started_mono_from_round(state.round_state),
      state.opts
    )

    finish_result(state, result)
  end

  defp apply_after_commit(
         state,
         {:start_shot, shot, running, attempt, %Attempt{} = attempt_input, permit}
       ) do
    start_committed_shot(state, shot, running, attempt, attempt_input, permit)
  end

  defp apply_after_commit(
         state,
         {:start_shot_after_store, shot, running, attempt, %Attempt{} = attempt_input}
       ) do
    start_committed_shot_after_store(state, shot, running, attempt, attempt_input)
  end

  defp start_committed_shot_after_store(state, shot, running, attempt, attempt_input) do
    case acquire_shot_permit(state.round_state, shot, attempt, state.opts) do
      {:ok, permit} ->
        start_committed_shot(state, shot, running, attempt, attempt_input, permit)

      {:queued, waiter, context} ->
        put_resource_waiter(state, waiter, shot, running, attempt, context,
          start_mode: :committed_after_store,
          attempt_input: attempt_input
        )

      {:error, %Error{} = error} ->
        apply_attempt_error(state, shot, running, attempt, error)
    end
  end

  defp start_committed_shot(state, shot, running, attempt, attempt_input, permit) do
    round_state = state.round_state

    with :ok <- record_attempt_started(attempt_input, state.opts),
         {:ok, task} <- start_shot_task(shot, attempt, attempt_input, state.opts) do
      timeout = shot_timeout(shot, attempt)

      entry = %{
        type: :task,
        round_id: round_state.id,
        shot_id: shot.id,
        attempt: attempt,
        shot: shot,
        current: running,
        attempt_input: attempt_input,
        permit: permit,
        pid: task.pid,
        result_ref: task.result_ref,
        monitor_ref: task.monitor_ref,
        timeout_ref: timeout && timeout.ref,
        timer_ref: timeout && timeout.timer_ref,
        started_mono: monotonic_ms()
      }

      put_inflight(state, entry)
    else
      {:error, %Error{} = error} ->
        release_shot_permit(permit)
        apply_attempt_error(state, shot, running, attempt, error)

      {:error, reason} ->
        release_shot_permit(permit)

        error =
          Error.new(:crash_error, :shot_crash, "failed to start shot task",
            retryable: true,
            details: %{
              round_id: round_state.id,
              shot_id: shot.id,
              attempt: attempt,
              reason: inspect(reason)
            }
          )

        apply_attempt_error(state, shot, running, attempt, error)
    end
  end

  defp transition_event(%RoundState{} = current, pending) do
    Event.new(
      round_id: current.id,
      transition_id: pending.transition_id,
      round_version: pending.expected_version + 1,
      event_type: pending.event_type,
      shot_id: changed_shot_id(current, pending.next_round_state),
      payload: %{
        previous_status: current.status,
        status: pending.next_round_state.status,
        changed_shots: changed_shot_payloads(current, pending.next_round_state)
      },
      occurred_at: Twelvgaige.Clock.utc_now()
    )
  end

  defp transition_audit_event(%RoundState{} = current, pending, %Event{} = event) do
    %{
      event_type: :round_state_transition,
      round_id: current.id,
      shot_id: event.shot_id,
      actor: "system",
      payload: %{
        transition_id: pending.transition_id,
        round_version: pending.expected_version + 1,
        event_type: pending.event_type,
        previous_status: current.status,
        status: pending.next_round_state.status,
        changed_shots: changed_shot_payloads(current, pending.next_round_state)
      },
      occurred_at: event.occurred_at
    }
  end

  defp changed_shot_id(current, next) do
    case changed_shot_payloads(current, next) do
      [%{id: id}] -> id
      _other -> nil
    end
  end

  defp changed_shot_payloads(current, next) do
    next.shot_states
    |> Enum.flat_map(fn {shot_id, next_shot} ->
      case Map.fetch(current.shot_states, shot_id) do
        {:ok, current_shot} ->
          if shot_transition_changed?(current_shot, next_shot) do
            [
              %{
                id: shot_id,
                previous_status: current_shot.status,
                status: next_shot.status,
                previous_attempt: current_shot.attempt,
                attempt: next_shot.attempt
              }
            ]
          else
            []
          end

        :error ->
          [
            %{
              id: shot_id,
              previous_status: nil,
              status: next_shot.status,
              attempt: next_shot.attempt
            }
          ]
      end
    end)
  end

  defp shot_transition_changed?(current, next) do
    current.status != next.status or current.attempt != next.attempt or
      current.output != next.output or current.error != next.error
  end

  defp store_retry_ms(opts) do
    opts
    |> Keyword.get(:store_retry_ms, 100)
    |> max(0)
  end

  defp store_error(message, round_id, reason) do
    Error.new(:store_error, :store_unavailable, message,
      retryable: true,
      details: %{round_id: round_id, reason: inspect(reason)}
    )
  end

  defp pause_for_safety(state) do
    release_round_permit(state.round_permit)

    state
    |> Map.put(:round_permit, nil)
    |> reply_awaiters({:ok, RoundState.to_snapshot(state.round_state)})
  end

  defp cancel_scheduled_round(state, opts) do
    now = Twelvgaige.Clock.utc_now()
    actor = Keyword.get(opts, :actor, "system")
    reason = Keyword.get(opts, :reason)

    state = cancel_inflight_work(state)

    round_state =
      state.round_state
      |> Map.put(:status, :cancelled)
      |> Map.put(:completed_at, now)
      |> Map.put(:awaiting_safety, [])
      |> Map.put(
        :shot_states,
        cancel_shot_states(state.round_state.shot_states, now, actor, reason)
      )

    state
    |> transition_round_state(round_state, :round_cancelled, {:finish, :success})
  end

  defp cancel_inflight_work(state) do
    state.round_state.inflight
    |> Map.values()
    |> Enum.reduce(state, fn
      %{type: :task, pid: pid} = entry, acc ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
        drop_inflight(acc, entry, demonitor?: true)

      %{type: :resource_waiter} = entry, acc ->
        drop_inflight(acc, entry, cancel_waiter?: true)
    end)
  end

  defp cancel_shot_states(shot_states, now, actor, reason) do
    Map.new(shot_states, fn {shot_id, shot_state} ->
      {shot_id, cancel_shot_state(shot_state, now, actor, reason)}
    end)
  end

  defp cancel_shot_state(%Shot.State{} = shot_state, now, actor, reason) do
    if Shot.State.terminal?(shot_state) do
      shot_state
    else
      %{
        shot_state
        | status: :cancelled,
          completed_at: now,
          output: %{
            "decision" => "cancelled",
            "actor" => actor,
            "reason" => reason,
            "decided_at" => DateTime.to_iso8601(now)
          }
      }
    end
  end

  defp complete_from_state(state) do
    round_state =
      state.round_state
      |> Map.put(:status, :complete)
      |> Map.put(:completed_at, Twelvgaige.Clock.utc_now())

    transition_round_state(state, round_state, :round_completed, {:finish, :success})
  end

  defp fail_from_state(state, %Error{} = error) do
    round_state =
      state.round_state
      |> Map.put(:status, failed_round_status(state.round_state))
      |> Map.put(:completed_at, Twelvgaige.Clock.utc_now())
      |> Map.put(:error, error)

    transition_round_state(
      state,
      round_state,
      event_type(round_state.status),
      {:finish, {:failure, error}}
    )
  end

  defp failed_round_status(%RoundState{status: status}) when status in [:halted, :failed],
    do: status

  defp failed_round_status(_round_state), do: :failed

  defp event_type(:failed), do: :round_failed
  defp event_type(:halted), do: :round_halted
  defp event_type(:awaiting_reconciliation), do: :round_awaiting_reconciliation
  defp event_type(status) when is_atom(status), do: :"round_#{status}"

  defp finish_result(state, result) do
    release_round_permit(state.round_permit)

    state
    |> reply_awaiters(result)
    |> Map.merge(%{result: result, round_permit: nil})
  end

  defp reply_awaiters(state, result) do
    Enum.each(Enum.reverse(state.awaiters), fn from ->
      GenServer.reply(from, result)
    end)

    %{state | awaiters: []}
  end

  defp run_with_round_permit(state) do
    case acquire_round_permit(state) do
      {:ok, permit} ->
        try do
          Runner.run(state.workflow, state.input, state.opts)
        after
          release_round_permit(permit)
        end

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp acquire_round_permit(state) do
    limiter = Keyword.get(state.opts, :limiter, ResourceLimiter)

    if limiter_available?(limiter) do
      context = round_resource_context(state)
      acquire_round_permit(limiter, context)
    else
      {:ok, nil}
    end
  end

  defp acquire_round_permit(limiter, context) do
    case ResourceLimiter.acquire(:active_round, context,
           server: limiter,
           owner_pid: self(),
           queue?: true
         ) do
      {:ok, permit} ->
        {:ok, permit}

      {:queued, waiter} ->
        wait_for_round_permit(limiter, context, waiter)

      {:error, {:limit_exceeded, _limit} = reason} ->
        {:error, resource_admission_error(reason, context)}

      {:error, reason} ->
        {:error, resource_admission_error(reason, context)}
    end
  end

  defp wait_for_round_permit(limiter, context, %ResourceLimiter.Waiter{} = waiter) do
    receive do
      {:resource_available, waiter_id, resource_kind}
      when waiter_id == waiter.id and resource_kind == waiter.resource_kind ->
        acquire_round_permit(limiter, context)

      {:resource_timeout, waiter_id, resource_kind}
      when waiter_id == waiter.id and resource_kind == waiter.resource_kind ->
        {:error, resource_queue_timeout_error(context)}
    end
  end

  defp acquire_shot_permit(round_state, shot, attempt, opts) do
    limiter = Keyword.get(opts, :limiter, ResourceLimiter)

    if limiter_available?(limiter) do
      context = shot_resource_context(round_state, shot, attempt, opts)

      case ResourceLimiter.acquire(:active_shot, context,
             server: limiter,
             owner_pid: self(),
             queue?: true
           ) do
        {:ok, permit} ->
          {:ok, permit}

        {:queued, waiter} ->
          {:queued, waiter, context}

        {:error, {:limit_exceeded, _limit} = reason} ->
          {:error, resource_admission_error(reason, context)}

        {:error, reason} ->
          {:error, resource_admission_error(reason, context)}
      end
    else
      {:ok, nil}
    end
  end

  defp release_round_permit(nil), do: :ok

  defp release_round_permit(%ResourceLimiter.Permit{} = permit) do
    case ResourceLimiter.release(permit) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp release_shot_permit(nil), do: :ok

  defp release_shot_permit(%ResourceLimiter.Permit{} = permit) do
    case ResourceLimiter.release(permit) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp limiter_available?(nil), do: false
  defp limiter_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp limiter_available?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp round_resource_context(state) do
    context = %{round_id: Keyword.fetch!(state.opts, :round_id)}

    case round_queue_timeout_ms(state) do
      nil -> context
      timeout_ms -> Map.put(context, :queue_timeout_ms, timeout_ms)
    end
  end

  defp round_queue_timeout_ms(state) do
    Keyword.get(state.opts, :queue_timeout_ms) || state.workflow.policy.queue_timeout_ms
  end

  defp shot_resource_context(round_state, shot, attempt, opts) do
    context = %{
      round_id: round_state.id,
      shot_id: shot.id,
      attempt: attempt
    }

    case queue_timeout_ms(round_state, opts) do
      nil -> context
      timeout_ms -> Map.put(context, :queue_timeout_ms, timeout_ms)
    end
  end

  defp queue_timeout_ms(round_state, opts) do
    Keyword.get(opts, :queue_timeout_ms) || Map.get(round_state.policy || %{}, :queue_timeout_ms)
  end

  defp resource_admission_error({:limit_exceeded, _limit} = reason, context) do
    Error.new(:timeout_error, :resource_queue_timeout, "resource limit exceeded",
      retryable: true,
      details: Map.merge(context, %{reason: inspect(reason)})
    )
  end

  defp resource_admission_error(reason, context) do
    Error.new(:internal_error, :policy_denied, "resource admission failed",
      details: Map.merge(context, %{reason: inspect(reason)})
    )
  end

  defp resource_queue_timeout_error(context) do
    Error.new(:timeout_error, :resource_queue_timeout, "resource queue timed out",
      retryable: true,
      details: context
    )
  end

  defp shot_crash_error(entry, reason) do
    Error.new(:crash_error, :shot_crash, "shot task exited",
      retryable: true,
      details: %{
        round_id: entry.round_id,
        shot_id: entry.shot_id,
        attempt: entry.attempt,
        reason: inspect(reason)
      }
    )
  end

  defp initial_round_state(state, compiled) do
    case Keyword.get(state.opts, :recovery_snapshot) do
      nil ->
        {:ok, new_round_state(state, compiled)}

      %Snapshot{} = snapshot ->
        {:ok, round_state_from_recovery_snapshot(state, compiled, snapshot)}

      snapshot ->
        {:ok, round_state_from_recovery_snapshot(state, compiled, Snapshot.new(snapshot))}
    end
  rescue
    error ->
      {:error,
       Error.new(:internal_error, :invalid_input, "invalid recovery snapshot",
         details: %{reason: Exception.message(error)}
       )}
  end

  defp new_round_state(state, compiled) do
    now = Twelvgaige.Clock.utc_now()
    round_id = Keyword.fetch!(state.opts, :round_id)
    profile = Keyword.get(state.opts, :profile, state.workflow.policy.resource_profile)

    RoundState.new(
      id: round_id,
      shell_id: state.workflow.id,
      shell_version: state.workflow.version,
      pattern: compiled,
      manifest:
        Manifest.new(
          round_id: round_id,
          workflow: state.workflow,
          source: Keyword.get(state.opts, :workflow_source, Manifest.source_for(state.workflow)),
          agents: Keyword.get(state.opts, :agents, []),
          agent_sources: Keyword.get(state.opts, :agent_sources, []),
          agent_hashes: Keyword.get(state.opts, :agent_hashes, %{}),
          effective_resource_profile: profile,
          created_at: now
        ),
      policy: %{
        resource_profile: profile,
        safety_scope: state.workflow.policy.safety_scope,
        on_safety_reject: state.workflow.policy.on_safety_reject,
        queue_timeout_ms: state.workflow.policy.queue_timeout_ms,
        scheduler_owned?: true
      },
      status: :queued,
      input: state.input,
      started_at: now,
      shots: Enum.map(state.workflow.shots, &shot_state_from_shell/1)
    )
  end

  defp round_state_from_recovery_snapshot(state, compiled, %Snapshot{} = snapshot) do
    RoundState.from_snapshot(snapshot,
      pattern: compiled,
      manifest:
        Manifest.new(
          round_id: snapshot.id,
          workflow: state.workflow,
          source: Keyword.get(state.opts, :workflow_source, Manifest.source_for(state.workflow)),
          agents: Keyword.get(state.opts, :agents, []),
          agent_sources: Keyword.get(state.opts, :agent_sources, []),
          agent_hashes: Keyword.get(state.opts, :agent_hashes, %{}),
          created_at: snapshot.started_at || Twelvgaige.Clock.utc_now()
        )
    )
  end

  defp shot_state_from_shell(shot) do
    Shot.State.new(
      id: shot.id,
      kind: shot.kind,
      depends_on: shot.depends_on,
      condition: shot.condition
    )
  end

  defp dependency_outputs(round_state, shot) do
    Map.new(shot.depends_on, fn dependency ->
      shot_state = Map.fetch!(round_state.shot_states, dependency)
      {dependency, shot_state.output}
    end)
  end

  defp failed_shot(round_state) do
    round_state.shot_states
    |> Map.values()
    |> Enum.find(&(&1.status == :failed))
  end

  defp awaiting_safety?(round_state), do: round_state.awaiting_safety != []
  defp inflight_empty?(round_state), do: map_size(round_state.inflight) == 0

  defp inflight_shot_ids(round_state) do
    Enum.map(round_state.inflight, fn {_key, entry} -> entry.shot_id end)
  end

  defp safety_scope(round_state),
    do: Map.get(round_state.policy || %{}, :safety_scope, :dependency)

  defp rejected_round_status(round_state) do
    case Map.get(round_state.policy || %{}, :on_safety_reject, :halt_round) do
      :fail_round -> :failed
      _halt_round -> :halted
    end
  end

  defp safety_request(round_state, shot) do
    %{
      "round_id" => round_state.id,
      "shot_id" => shot.id,
      "status" => "awaiting",
      "scope" => Atom.to_string(safety_scope(round_state)),
      "reason" => shot.description,
      "requested_at" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }
  end

  defp safety_decision(request, opts) do
    cond do
      Keyword.get(opts, :approve_all_safety?, false) ->
        {:approved, "approved by foreground option", "system"}

      decisions = Keyword.get(opts, :safety_decisions) ->
        decisions
        |> lookup_safety_decision(request["shot_id"])
        |> normalize_safety_decision()

      handler = Keyword.get(opts, :safety_handler) ->
        handler
        |> call_safety_handler(request)
        |> normalize_safety_decision()

      true ->
        :await
    end
  end

  defp lookup_safety_decision(decisions, shot_id) when is_map(decisions) do
    Enum.find_value(decisions, fn {key, value} ->
      if to_string(key) == shot_id, do: value
    end)
  end

  defp lookup_safety_decision(decisions, shot_id) when is_list(decisions) do
    Enum.find_value(decisions, fn
      {key, value} when is_atom(key) or is_binary(key) ->
        if to_string(key) == shot_id, do: value

      _other ->
        nil
    end)
  end

  defp lookup_safety_decision(_decisions, _shot_id), do: nil

  defp call_safety_handler(handler, request) when is_function(handler, 1), do: handler.(request)

  defp call_safety_handler(handler, request) when is_function(handler, 2),
    do: handler.(request["shot_id"], request)

  defp call_safety_handler(_handler, _request), do: nil

  defp normalize_safety_decision(value)
       when value in [:approve, :approved, "approve", "approved"] do
    {:approved, nil, "system"}
  end

  defp normalize_safety_decision(value)
       when value in [:reject, :rejected, "reject", "rejected"] do
    {:rejected, nil, "system"}
  end

  defp normalize_safety_decision({decision, reason}) when decision in [:approve, :approved] do
    {:approved, reason, "system"}
  end

  defp normalize_safety_decision({decision, reason}) when decision in [:reject, :rejected] do
    {:rejected, reason, "system"}
  end

  defp normalize_safety_decision(%{} = decision) do
    normalized =
      decision
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()

    case normalize_safety_decision(Map.get(normalized, "decision")) do
      {:approved, _reason, _actor} ->
        {:approved, Map.get(normalized, "reason"), Map.get(normalized, "actor", "system")}

      {:rejected, _reason, _actor} ->
        {:rejected, Map.get(normalized, "reason"), Map.get(normalized, "actor", "system")}

      :await ->
        :await
    end
  end

  defp normalize_safety_decision(_value), do: :await

  defp safety_output(decision, reason, actor) do
    %{
      "decision" => decision,
      "reason" => reason,
      "actor" => actor,
      "decided_at" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }
  end

  defp drop_awaiting_safety(awaiting, shot_id) do
    Enum.reject(awaiting, &(Map.get(&1, "shot_id") == shot_id))
  end

  defp retry_history(shot_state, error) do
    shot_state.history ++
      [
        %{
          attempt: shot_state.attempt,
          failed_at: DateTime.to_iso8601(Twelvgaige.Clock.utc_now()),
          error: Error.to_map(error)
        }
      ]
  end

  defp shot_executor_opts(opts, attempt) do
    opts =
      opts
      |> Keyword.get(:profile, :laptop)
      |> RuntimeProfile.shot_opts(opts)

    case Keyword.get(opts, :attempt_responses) do
      responses when is_list(responses) ->
        opts
        |> Keyword.delete(:response)
        |> Keyword.delete(:responses)
        |> Keyword.put(:response, Enum.at(responses, attempt - 1, ""))

      _other ->
        opts
    end
  end

  defp compiler_opts(opts) do
    Keyword.take(opts, [
      :agents,
      :agent_ids,
      :known_tools,
      :tool_catalog,
      :validate_tools?,
      :allow_unsafe_tools_without_safety?
    ])
  end

  defp record_round_metrics({:ok, %Snapshot{} = snapshot}, workflow_id, started_mono, opts) do
    labels = %{workflow_id: workflow_id, status: snapshot.status}

    Metrics.counter("twelvgaige_rounds_total", labels, 1, metrics_opts(opts))

    Metrics.observe(
      "twelvgaige_round_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics_opts(opts)
    )
  end

  defp record_round_metrics({:error, %Error{} = error}, workflow_id, started_mono, opts) do
    labels = %{workflow_id: workflow_id, status: :failed, error_class: error.class}

    Metrics.counter("twelvgaige_rounds_total", labels, 1, metrics_opts(opts))

    Metrics.observe(
      "twelvgaige_round_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics_opts(opts)
    )
  end

  defp record_shot_metrics(shot, result, started_mono, opts) do
    labels =
      %{
        kind: Map.get(shot, :kind, :slug),
        status: shot_status(result)
      }
      |> maybe_error_class(result)

    Metrics.counter("twelvgaige_shot_attempts_total", labels, 1, metrics_opts(opts))

    Metrics.observe(
      "twelvgaige_shot_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics_opts(opts)
    )
  end

  defp maybe_error_class(labels, {:error, %Error{} = error}),
    do: Map.put(labels, :error_class, error.class)

  defp maybe_error_class(labels, _result), do: labels

  defp shot_status({:ok, _result}), do: :complete
  defp shot_status({:error, _error}), do: :failed

  defp record_safety_decision(decision, opts) do
    Metrics.counter(
      "twelvgaige_safety_decisions_total",
      %{decision: decision},
      1,
      metrics_opts(opts)
    )
  end

  defp metrics_opts(opts), do: [metrics: Keyword.get(opts, :metrics, Metrics)]

  defp started_mono_from_round(%RoundState{started_at: %DateTime{} = started_at}) do
    max(monotonic_ms() - DateTime.diff(Twelvgaige.Clock.utc_now(), started_at, :millisecond), 0)
  end

  defp duration_seconds(started_mono), do: max(monotonic_ms() - started_mono, 0) / 1000
  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp cancel_timer(nil), do: :ok

  defp cancel_timer(ref) when is_reference(ref) do
    _ = Process.cancel_timer(ref)
    :ok
  end

  defp demonitor(nil), do: :ok

  defp demonitor(ref) when is_reference(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end
end
