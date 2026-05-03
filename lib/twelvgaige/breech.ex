defmodule Twelvgaige.Breech do
  @moduledoc """
  Local daemon control-plane process.

  Phase 3 starts with an in-VM owner for daemon lifecycle and health state. IPC
  and detached round ownership build on this process; foreground execution still
  works without depending on external daemon discovery.
  """

  use GenServer

  alias Twelvgaige.Error
  alias Twelvgaige.ID
  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.Log
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.InputValidator
  alias Twelvgaige.Round.Manifest
  alias Twelvgaige.Round.Recovery
  alias Twelvgaige.Round.Runner
  alias Twelvgaige.Round.Server, as: RoundServer
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.ResourceLimiter
  alias Twelvgaige.RuntimeProfile
  alias Twelvgaige.Shell
  alias Twelvgaige.Shell.Cache, as: ShellCache
  alias Twelvgaige.Store.Config, as: StoreConfig
  alias Twelvgaige.Shot

  defstruct [
    :daemon_id,
    :started_at,
    :started_mono_ms,
    :profile,
    :ipc,
    :shell_cache,
    :store,
    active_rounds: %{}
  ]

  @type status :: %{
          daemon_id: String.t(),
          status: String.t(),
          version: String.t(),
          profile: String.t(),
          ipc: String.t(),
          started_at: String.t(),
          uptime_ms: non_neg_integer(),
          resources: map(),
          store: map()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec status(GenServer.server()) :: {:ok, status()} | {:error, :daemon_unavailable}
  def status(server \\ __MODULE__) do
    case resolve_server(server) do
      nil -> {:error, :daemon_unavailable}
      pid -> GenServer.call(pid, :status)
    end
  end

  @spec start_round(Shell.Workflow.t() | map() | Path.t(), map(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def start_round(shell_or_path, input, opts \\ []) when is_map(input) and is_list(opts) do
    with {:ok, pid} <- resolve_server_option(opts) do
      GenServer.call(pid, {:start_round, shell_or_path, input, opts})
    end
  end

  @spec get_round(String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, :not_found}
  def get_round(round_id, opts \\ []) when is_binary(round_id) do
    with {:ok, store} <- store_for_option(opts),
         {:ok, snapshot} <- store.get_round(round_id) do
      {:ok, normalize_snapshot(snapshot)}
    end
  end

  @spec list_rounds(keyword()) :: {:ok, [Snapshot.t()]} | {:error, term()}
  def list_rounds(opts \\ []) when is_list(opts) do
    with {:ok, store} <- store_for_option(opts),
         {:ok, snapshots} <- store.list_rounds(Keyword.take(opts, [:status])) do
      {:ok, Enum.map(snapshots, &normalize_snapshot/1)}
    end
  end

  @spec list_round_events(String.t(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def list_round_events(round_id, opts \\ []) when is_binary(round_id) and is_list(opts) do
    with {:ok, store} <- store_for_option(opts),
         {:ok, events} <-
           store.list_round_events(round_id, Keyword.take(opts, [:after_seq, :limit])) do
      {:ok, Enum.map(events, &normalize_event/1)}
    end
  end

  @spec await_round_events(String.t(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def await_round_events(round_id, opts \\ []) when is_binary(round_id) and is_list(opts) do
    with {:ok, store} <- store_for_option(opts),
         {:ok, events} <-
           store.await_round_events(
             round_id,
             Keyword.take(opts, [:after_seq, :limit, :timeout_ms])
           ) do
      {:ok, Enum.map(events, &normalize_event/1)}
    end
  end

  @spec list_audit_events(String.t(), keyword()) :: {:ok, [AuditEvent.t()]} | {:error, term()}
  def list_audit_events(round_id, opts \\ []) when is_binary(round_id) and is_list(opts) do
    with {:ok, store} <- store_for_option(opts) do
      store.list_audit_events(round_id, Keyword.take(opts, [:after_seq, :limit]))
    end
  end

  @spec approve_safety(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def approve_safety(round_id, shot_id, opts \\ [])
      when is_binary(round_id) and is_binary(shot_id) and is_list(opts) do
    with {:ok, pid} <- resolve_server_option(opts) do
      GenServer.call(pid, {:safety_decision, round_id, shot_id, :approved, opts})
    end
  end

  @spec reject_safety(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def reject_safety(round_id, shot_id, opts \\ [])
      when is_binary(round_id) and is_binary(shot_id) and is_list(opts) do
    with {:ok, pid} <- resolve_server_option(opts) do
      GenServer.call(pid, {:safety_decision, round_id, shot_id, :rejected, opts})
    end
  end

  @spec cancel_round(String.t(), keyword()) :: :ok | {:error, term()}
  def cancel_round(round_id, opts \\ []) when is_binary(round_id) and is_list(opts) do
    with {:ok, pid} <- resolve_server_option(opts) do
      GenServer.call(pid, {:cancel_round, round_id, opts})
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    started_at = Keyword.get(opts, :started_at, Twelvgaige.Clock.utc_now())

    with {:ok, profile} <-
           RuntimeProfile.normalize(Keyword.get(opts, :profile, RuntimeProfile.default())) do
      state =
        %__MODULE__{
          daemon_id: Keyword.get(opts, :daemon_id, ID.new(:daemon)),
          started_at: started_at,
          started_mono_ms: Keyword.get(opts, :started_mono_ms, monotonic_ms()),
          profile: profile,
          ipc: Keyword.get(opts, :ipc, :in_vm),
          shell_cache: Keyword.get(opts, :shell_cache, ShellCache),
          store: Keyword.get(opts, :store, configured_store())
        }

      with :ok <- ensure_store_available(state.store) do
        state = recover_incomplete_rounds(state, opts)

        Log.emit(:info, :daemon_started, "breech daemon started",
          daemon_id: state.daemon_id,
          profile: state.profile,
          store: state.store
        )

        {:ok, state}
      else
        {:error, reason} -> {:stop, reason}
      end
    else
      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.active_rounds, fn {_round_id, active} ->
      if is_reference(active.monitor_ref), do: Process.demonitor(active.monitor_ref, [:flush])

      if is_pid(active.pid) and Process.alive?(active.pid) do
        Process.exit(active.pid, :shutdown)
      end
    end)

    :ok
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, {:ok, status_map(state)}, state}
  end

  def handle_call(:store, _from, state) do
    {:reply, state.store, state}
  end

  def handle_call({:start_round, shell_or_path, input, opts}, _from, state) do
    opts =
      opts
      |> Keyword.put_new(:shell_cache, state.shell_cache)
      |> Keyword.put_new(:max_profile, state.profile)

    with {:ok, workflow, opts, source} <- load_workflow(shell_or_path, opts),
         :ok <- InputValidator.validate(workflow, input),
         {:ok, round_id} <-
           create_queued_round(
             state.store,
             workflow,
             input,
             opts,
             source
           ),
         {:ok, pid} <- start_round_task(self(), round_id, workflow, input, state.store, opts) do
      monitor_ref = Process.monitor(pid)

      state =
        put_active_round(state, round_id, pid, monitor_ref,
          persist_result?: persist_task_result?(opts)
        )

      Log.emit(:info, :round_queued, "round queued",
        round_id: round_id,
        shell_id: workflow.id,
        shell_version: workflow.version,
        profile: state.profile
      )

      {:reply, {:ok, round_id}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:safety_decision, round_id, shot_id, decision, opts}, _from, state) do
    state = clear_dead_active_round(round_id, state)

    with {:ok, workflow} <- workflow_for_round(state.store, round_id),
         {:ok, snapshot} <- fetch_snapshot(state.store, round_id),
         :ok <- ensure_awaiting_safety(snapshot, shot_id),
         :ok <- ensure_not_active(round_id, state),
         {:ok, pid} <-
           start_resume_task(
             self(),
             round_id,
             workflow,
             snapshot,
             shot_id,
             decision,
             state.store,
             opts
           ) do
      monitor_ref = Process.monitor(pid)

      state =
        put_active_round(state, round_id, pid, monitor_ref,
          persist_result?: not scheduler_owned?(snapshot)
        )

      {:reply, :ok, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel_round, round_id, opts}, _from, state) do
    with {:ok, snapshot} <- fetch_snapshot(state.store, round_id) do
      state = stop_active_round(round_id, state)

      if Snapshot.terminal?(snapshot) do
        {:reply, :ok, state}
      else
        snapshot = cancelled_snapshot(snapshot, opts)

        case commit_snapshot(state.store, round_id, snapshot) do
          :ok -> {:reply, :ok, state}
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp ensure_awaiting_safety(%Snapshot{status: :awaiting_safety} = snapshot, shot_id) do
    awaiting? =
      Enum.any?(snapshot.awaiting_safety, fn request ->
        Map.get(request, "shot_id", Map.get(request, :shot_id)) == shot_id
      end)

    if awaiting? do
      :ok
    else
      {:error,
       Error.new(:policy_error, :policy_denied, "safety shot is not awaiting approval",
         details: %{round_id: snapshot.id, shot_id: shot_id}
       )}
    end
  end

  defp ensure_awaiting_safety(%Snapshot{} = snapshot, shot_id) do
    {:error,
     Error.new(:policy_error, :policy_denied, "round is not awaiting safety approval",
       details: %{round_id: snapshot.id, shot_id: shot_id, status: snapshot.status}
     )}
  end

  @impl true
  def handle_info({:round_finished, round_id, result}, state) do
    persist_result? = persist_round_result?(round_id, result, state)
    state = demonitor_round(round_id, state)
    if persist_result?, do: persist_round_result(state.store, round_id, result)
    log_round_finished(round_id, result, state)
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
    case find_active_round(state.active_rounds, monitor_ref, pid) do
      {round_id, _active} ->
        state = update_in(state.active_rounds, &Map.delete(&1, round_id))

        if reason != :normal do
          persist_round_result(state.store, round_id, {:error, task_crash_error(reason)})
        end

        {:noreply, state}

      nil ->
        {:noreply, state}
    end
  end

  defp status_map(state) do
    %{
      daemon_id: state.daemon_id,
      status: "running",
      version: Twelvgaige.version(),
      profile: Atom.to_string(state.profile),
      ipc: Atom.to_string(state.ipc),
      started_at: DateTime.to_iso8601(state.started_at),
      uptime_ms: max(monotonic_ms() - state.started_mono_ms, 0),
      active_rounds: map_size(state.active_rounds),
      resources: resource_status(),
      store: store_status(state.store),
      metrics: Twelvgaige.Metrics.snapshot() |> Twelvgaige.Metrics.to_map()
    }
  end

  defp load_workflow(%Shell.Workflow{} = workflow, opts),
    do: {:ok, workflow, opts, Manifest.source_for(workflow)}

  defp load_workflow(%{} = workflow_map, opts) do
    with {:ok, workflow} <- Shell.Workflow.from_map(workflow_map) do
      {:ok, workflow, opts, Manifest.source_for(workflow_map)}
    end
  end

  defp load_workflow(path, opts) when is_binary(path) do
    if shell_path?(path) do
      load_workflow_path(path, opts)
    else
      load_cached_workflow(path, opts)
    end
  end

  defp load_workflow_path(path, opts) do
    agent_paths = Shell.Loader.agent_shell_paths_for_workflow(path, opts)

    agent_opts =
      opts
      |> Keyword.put(:agent_shell_paths, agent_paths)
      |> Keyword.put(:discover_agents?, false)

    with {:ok, %Shell.Workflow{} = workflow} <- Shell.Loader.load(path, opts),
         {:ok, agents} <- Shell.Loader.load_agents_for_workflow(path, agent_opts) do
      opts =
        opts
        |> put_discovered_agents(agents)
        |> put_manifest_provenance(path, agent_paths, agents)

      {:ok, workflow, opts, Keyword.fetch!(opts, :workflow_source)}
    else
      {:ok, _other_shell} -> {:error, :workflow_shell_required}
      {:error, _reason} = error -> error
    end
  end

  defp load_cached_workflow(shell_id, opts) do
    cache = Keyword.get(opts, :shell_cache, ShellCache)

    with {:ok, workflow, agents} <- ShellCache.workflow_with_agents(shell_id, server: cache) do
      opts =
        opts
        |> put_discovered_agents(agents)
        |> Keyword.put(:agent_hashes, Manifest.agent_hashes(agents))
        |> Keyword.put(:agent_sources, Manifest.sources_for(agents))

      {:ok, workflow, opts, %{type: :shell_cache, shell_id: shell_id}}
    end
  end

  defp shell_path?(value) do
    extension = value |> Path.extname() |> String.downcase()
    Shell.Loader.supported_extension?(extension) or String.contains?(value, ["/", "\\"])
  end

  defp put_discovered_agents(opts, []), do: opts

  defp put_discovered_agents(opts, agents) do
    Keyword.update(opts, :agents, agents, fn existing_agents ->
      List.wrap(existing_agents) ++ agents
    end)
  end

  defp put_manifest_provenance(opts, workflow_path, agent_paths, agents) do
    opts
    |> Keyword.put(:workflow_source, Manifest.source_for(workflow_path))
    |> Keyword.put(:agent_sources, Manifest.sources_for(agent_paths))
    |> Keyword.put(:agent_hashes, Manifest.agent_hashes(agents))
  end

  defp create_queued_round(store, workflow, input, opts, source) do
    round_id = Keyword.get_lazy(opts, :round_id, fn -> ID.new(:round) end)
    now = Twelvgaige.Clock.utc_now()

    with {:ok, profile} <- RuntimeProfile.effective(workflow.policy, opts) do
      snapshot =
        Snapshot.new(
          id: round_id,
          shell_id: workflow.id,
          shell_version: workflow.version,
          status: :queued,
          input: input,
          started_at: now,
          shots: Enum.map(workflow.shots, &shot_state_from_shell/1),
          policy: policy_map(workflow.policy, opts, profile),
          resource_profile: profile
        )

      manifest =
        Manifest.new(
          round_id: round_id,
          workflow: workflow,
          source: source,
          agents: Keyword.get(opts, :agents, []),
          agent_sources: Keyword.get(opts, :agent_sources, []),
          agent_hashes: Keyword.get(opts, :agent_hashes, %{}),
          effective_resource_profile: profile,
          created_at: now
        )

      case store.create_round(snapshot, manifest, []) do
        :ok -> {:ok, round_id}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp policy_map(policy, opts, profile) do
    policy
    |> Map.from_struct()
    |> Map.put(:resource_profile, profile)
    |> maybe_mark_scheduler_owned(opts)
  end

  defp maybe_mark_scheduler_owned(policy, opts) do
    if Keyword.get(opts, :scheduler?, false) do
      Map.put(policy, :scheduler_owned?, true)
    else
      policy
    end
  end

  defp start_round_task(owner, round_id, workflow, input, store, opts) do
    runner_opts =
      opts
      |> Keyword.drop([:server])
      |> Keyword.put(:round_id, round_id)
      |> Keyword.put(:store, store)

    fun = fn ->
      result =
        if Keyword.get(opts, :scheduler?, false) do
          run_scheduler_round(workflow, input, round_id, store, runner_opts)
        else
          Runner.run(workflow, input, runner_opts)
        end

      send(owner, {:round_finished, round_id, result})
    end

    case Process.whereis(Twelvgaige.Breech.TaskSupervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(Twelvgaige.Breech.TaskSupervisor, fun)
    end
  end

  defp run_scheduler_round(workflow, input, round_id, store, opts) do
    opts =
      opts
      |> Keyword.put(:supervised?, false)
      |> Keyword.put(:stop_after_await?, true)

    case store.get_round(round_id) do
      {:ok, snapshot} ->
        RoundServer.recover_sync(workflow, normalize_snapshot(snapshot), opts)

      {:error, _reason} ->
        RoundServer.run_sync(workflow, input, opts)
    end
  end

  defp start_resume_task(owner, round_id, workflow, snapshot, shot_id, decision, store, opts) do
    runner_opts =
      opts
      |> Keyword.drop([:server])
      |> Keyword.put(:store, store)

    fun = fn ->
      result =
        if scheduler_owned?(snapshot) do
          resume_scheduler_safety(workflow, snapshot, shot_id, decision, runner_opts)
        else
          case decision do
            :approved -> Runner.approve_safety(workflow, snapshot, shot_id, runner_opts)
            :rejected -> Runner.reject_safety(workflow, snapshot, shot_id, runner_opts)
          end
        end

      send(owner, {:round_finished, round_id, result})
    end

    case Process.whereis(Twelvgaige.Breech.TaskSupervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(Twelvgaige.Breech.TaskSupervisor, fun)
    end
  end

  defp resume_scheduler_safety(workflow, snapshot, shot_id, decision, opts) do
    opts =
      opts
      |> Keyword.put(:supervised?, false)
      |> Keyword.put(:stop_after_await?, true)

    case decision do
      :approved -> RoundServer.approve_safety_sync(workflow, snapshot, shot_id, opts)
      :rejected -> RoundServer.reject_safety_sync(workflow, snapshot, shot_id, opts)
    end
  end

  defp workflow_for_round(store, round_id) do
    with {:ok, manifest} <- store.get_manifest(round_id) do
      Manifest.workflow(manifest)
    end
  end

  defp fetch_snapshot(store, round_id) do
    with {:ok, snapshot} <- store.get_round(round_id) do
      {:ok, normalize_snapshot(snapshot)}
    end
  end

  defp ensure_not_active(round_id, state) do
    if Map.has_key?(state.active_rounds, round_id) do
      {:error,
       Error.new(:policy_error, :policy_denied, "round is already active",
         details: %{round_id: round_id}
       )}
    else
      :ok
    end
  end

  defp clear_dead_active_round(round_id, state) do
    case Map.fetch(state.active_rounds, round_id) do
      {:ok, %{pid: pid, monitor_ref: monitor_ref}} ->
        if Process.alive?(pid) do
          state
        else
          Process.demonitor(monitor_ref, [:flush])
          update_in(state.active_rounds, &Map.delete(&1, round_id))
        end

      :error ->
        state
    end
  end

  defp persist_round_result(store, round_id, {:ok, %Snapshot{} = snapshot}) do
    commit_snapshot(store, round_id, snapshot)
  end

  defp persist_round_result(store, round_id, {:error, %Error{} = error}) do
    case store.get_round(round_id) do
      {:ok, snapshot} ->
        snapshot =
          snapshot
          |> normalize_snapshot()
          |> Map.merge(%{
            status: :failed,
            completed_at: Twelvgaige.Clock.utc_now(),
            error: error
          })

        commit_snapshot(store, round_id, snapshot)

      {:error, :not_found} ->
        :ok
    end
  end

  defp commit_snapshot(store, round_id, %Snapshot{} = snapshot) do
    expected_version = snapshot.version

    event =
      Event.new(
        round_id: round_id,
        transition_id: ID.transition_id(),
        round_version: expected_version + 1,
        event_type: event_type(snapshot.status),
        payload: %{status: Atom.to_string(snapshot.status)},
        occurred_at: Twelvgaige.Clock.utc_now()
      )

    audit_event = %{
      event_type: :round_state_transition,
      round_id: round_id,
      actor: "system",
      payload: %{
        transition_id: event.transition_id,
        round_version: event.round_version,
        status: snapshot.status
      },
      occurred_at: event.occurred_at
    }

    case store.commit_transition(
           round_id,
           expected_version,
           event.transition_id,
           snapshot,
           [event],
           [audit_event]
         ) do
      :ok -> :ok
      :already_committed -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp log_round_finished(round_id, {:ok, %Snapshot{} = snapshot}, state) do
    Log.emit(:info, :round_finished, "round finished",
      round_id: round_id,
      shell_id: snapshot.shell_id,
      shell_version: snapshot.shell_version,
      status: snapshot.status,
      profile: state.profile
    )
  end

  defp log_round_finished(round_id, {:error, %Error{} = error}, state) do
    Log.emit(:error, :round_failed, "round failed",
      round_id: round_id,
      status: :failed,
      error: error,
      profile: state.profile
    )
  end

  defp log_round_finished(round_id, _result, state) do
    Log.emit(:warn, :round_finished_unknown, "round finished with unknown result",
      round_id: round_id,
      profile: state.profile
    )
  end

  defp event_type(:complete), do: :round_completed
  defp event_type(:failed), do: :round_failed
  defp event_type(:halted), do: :round_halted
  defp event_type(:awaiting_safety), do: :round_awaiting_safety
  defp event_type(:awaiting_reconciliation), do: :round_awaiting_reconciliation
  defp event_type(:cancelled), do: :round_cancelled
  defp event_type(status) when is_atom(status), do: :"round_#{status}"

  defp recover_incomplete_rounds(state, opts) do
    if Keyword.get(opts, :recover?, true) do
      do_recover_incomplete_rounds(state)
    else
      state
    end
  end

  defp do_recover_incomplete_rounds(state) do
    case state.store.list_incomplete_rounds() do
      {:ok, snapshots} ->
        Enum.reduce(snapshots, state, &recover_incomplete_round/2)

      {:error, _reason} ->
        state
    end
  rescue
    _error -> state
  end

  defp recover_incomplete_round(snapshot, state) do
    snapshot = normalize_snapshot(snapshot)
    journals = recovery_journals(state.store, snapshot.id)

    if scheduler_owned?(snapshot) do
      recover_scheduler_round(snapshot, journals, state)
    else
      case Recovery.reconcile(snapshot, journals: journals) do
        {:resume, %Snapshot{} = snapshot} ->
          resume_recovered_round(snapshot, state)

        {:commit_and_resume, %Snapshot{} = snapshot} ->
          resume_committed_recovery(snapshot, state)

        {:commit, %Snapshot{} = snapshot} ->
          _result = commit_snapshot(state.store, snapshot.id, snapshot)
          state

        {:keep, _snapshot} ->
          state
      end
    end
  end

  defp recover_scheduler_round(%Snapshot{} = snapshot, journals, state) do
    case Recovery.reconcile(snapshot, journals: journals) do
      decision when elem(decision, 0) in [:resume, :commit_and_resume] ->
        resume_scheduler_recovered_round(snapshot, journals, state)

      {:commit, %Snapshot{} = snapshot} ->
        _result = commit_snapshot(state.store, snapshot.id, snapshot)
        state

      {:keep, _snapshot} ->
        state
    end
  end

  defp recovery_journals(store, round_id) do
    %{
      attempts: list_recovery_journals(store, :list_attempt_journals, round_id),
      tools: list_recovery_journals(store, :list_tool_journals, round_id)
    }
  end

  defp list_recovery_journals(store, fun, round_id) do
    case apply(store, fun, [round_id]) do
      {:ok, journals} -> journals
      {:error, _reason} -> []
    end
  rescue
    _error -> []
  end

  defp resume_recovered_round(%Snapshot{} = snapshot, state) do
    with {:ok, workflow} <- workflow_for_round(state.store, snapshot.id),
         {:ok, pid} <-
           start_round_task(self(), snapshot.id, workflow, snapshot.input, state.store, []) do
      monitor_ref = Process.monitor(pid)

      put_active_round(state, snapshot.id, pid, monitor_ref, persist_result?: true)
    else
      {:error, reason} ->
        failed =
          snapshot
          |> Map.merge(%{
            status: :failed,
            completed_at: Twelvgaige.Clock.utc_now(),
            error: recovery_resume_error(snapshot.id, reason)
          })

        _result = commit_snapshot(state.store, snapshot.id, failed)
        state
    end
  end

  defp resume_scheduler_recovered_round(%Snapshot{} = snapshot, journals, state) do
    with {:ok, workflow} <- workflow_for_round(state.store, snapshot.id),
         {:ok, pid} <-
           start_scheduler_recover_task(
             self(),
             snapshot.id,
             workflow,
             snapshot,
             journals,
             state.store
           ) do
      monitor_ref = Process.monitor(pid)

      put_active_round(state, snapshot.id, pid, monitor_ref, persist_result?: false)
    else
      {:error, reason} ->
        failed =
          snapshot
          |> Map.merge(%{
            status: :failed,
            completed_at: Twelvgaige.Clock.utc_now(),
            error: recovery_resume_error(snapshot.id, reason)
          })

        _result = commit_snapshot(state.store, snapshot.id, failed)
        state
    end
  end

  defp resume_committed_recovery(%Snapshot{} = snapshot, state) do
    case commit_snapshot(state.store, snapshot.id, snapshot) do
      :ok ->
        snapshot
        |> Map.update!(:version, &(&1 + 1))
        |> resume_recovered_snapshot(state)

      {:error, _reason} ->
        state
    end
  end

  defp resume_recovered_snapshot(%Snapshot{} = snapshot, state) do
    with {:ok, workflow} <- workflow_for_round(state.store, snapshot.id),
         {:ok, pid} <-
           start_recover_task(self(), snapshot.id, workflow, snapshot, state.store, []) do
      monitor_ref = Process.monitor(pid)

      put_active_round(state, snapshot.id, pid, monitor_ref, persist_result?: true)
    else
      {:error, reason} ->
        failed =
          snapshot
          |> Map.merge(%{
            status: :failed,
            completed_at: Twelvgaige.Clock.utc_now(),
            error: recovery_resume_error(snapshot.id, reason)
          })

        _result = commit_snapshot(state.store, snapshot.id, failed)
        state
    end
  end

  defp start_scheduler_recover_task(owner, round_id, workflow, snapshot, journals, store) do
    fun = fn ->
      result =
        RoundServer.recover_sync(workflow, snapshot,
          store: store,
          journals: journals,
          supervised?: false,
          stop_after_await?: true
        )

      send(owner, {:round_finished, round_id, result})
    end

    case Process.whereis(Twelvgaige.Breech.TaskSupervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(Twelvgaige.Breech.TaskSupervisor, fun)
    end
  end

  defp start_recover_task(owner, round_id, workflow, snapshot, store, opts) do
    runner_opts =
      opts
      |> Keyword.drop([:server])
      |> Keyword.put(:store, store)

    fun = fn ->
      result = Runner.recover(workflow, snapshot, runner_opts)
      send(owner, {:round_finished, round_id, result})
    end

    case Process.whereis(Twelvgaige.Breech.TaskSupervisor) do
      nil -> Task.start(fun)
      _pid -> Task.Supervisor.start_child(Twelvgaige.Breech.TaskSupervisor, fun)
    end
  end

  defp recovery_resume_error(round_id, reason) do
    Error.new(:crash_error, :shot_crash, "recovered round could not be resumed",
      details: %{round_id: round_id, reason: inspect(reason)}
    )
  end

  defp ensure_store_available(store) do
    if Process.whereis(store) do
      :ok
    else
      {:error, {:store_unavailable, store}}
    end
  end

  defp put_active_round(state, round_id, pid, monitor_ref, opts) do
    entry = %{
      pid: pid,
      monitor_ref: monitor_ref,
      persist_result?: Keyword.get(opts, :persist_result?, true)
    }

    put_in(state.active_rounds[round_id], entry)
  end

  defp persist_task_result?(opts), do: not Keyword.get(opts, :scheduler?, false)

  defp persist_round_result?(round_id, result, state) do
    active = Map.get(state.active_rounds, round_id, %{})

    Map.get(active, :persist_result?, true) or match?({:error, %Error{}}, result)
  end

  defp scheduler_owned?(%Snapshot{} = snapshot) do
    policy_value(snapshot.policy, :scheduler_owned?) == true
  end

  defp policy_value(policy, key) when is_map(policy) do
    Map.get(policy, key, Map.get(policy, Atom.to_string(key)))
  end

  defp policy_value(_policy, _key), do: nil

  defp demonitor_round(round_id, state) do
    case Map.fetch(state.active_rounds, round_id) do
      {:ok, %{monitor_ref: monitor_ref}} ->
        Process.demonitor(monitor_ref, [:flush])
        update_in(state.active_rounds, &Map.delete(&1, round_id))

      :error ->
        state
    end
  end

  defp stop_active_round(round_id, state) do
    case Map.fetch(state.active_rounds, round_id) do
      {:ok, %{pid: pid, monitor_ref: monitor_ref}} ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor_ref, [:flush])
        update_in(state.active_rounds, &Map.delete(&1, round_id))

      :error ->
        state
    end
  end

  defp cancelled_snapshot(%Snapshot{} = snapshot, opts) do
    now = Twelvgaige.Clock.utc_now()
    actor = Keyword.get(opts, :actor, "system")
    reason = Keyword.get(opts, :reason)

    %{
      snapshot
      | status: :cancelled,
        completed_at: now,
        awaiting_safety: [],
        error: nil,
        shots: Enum.map(snapshot.shots, &cancel_shot(&1, now, actor, reason))
    }
  end

  defp cancel_shot(%Shot.State{} = shot, now, actor, reason) do
    if Shot.State.terminal?(shot) do
      shot
    else
      %{
        shot
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

  defp find_active_round(active_rounds, monitor_ref, pid) do
    Enum.find(active_rounds, fn
      {_round_id, %{monitor_ref: ^monitor_ref, pid: ^pid}} -> true
      _other -> false
    end)
  end

  defp task_crash_error(reason) do
    Error.new(:crash_error, :shot_crash, "daemon-owned round task exited",
      retryable: true,
      details: %{reason: inspect(reason)}
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

  defp normalize_snapshot(%Snapshot{} = snapshot), do: snapshot
  defp normalize_snapshot(%{} = snapshot), do: Snapshot.new(snapshot)

  defp normalize_event(%Event{} = event), do: event
  defp normalize_event(%{} = event), do: Event.new(event)

  defp resource_status do
    case Process.whereis(ResourceLimiter) do
      nil ->
        %{status: "unavailable"}

      _pid ->
        snapshot = ResourceLimiter.snapshot()

        %{
          status: "ok",
          profile: Atom.to_string(snapshot.profile),
          limits: stringify_keys(snapshot.limits),
          used: stringify_keys(snapshot.used),
          queue_depth: stringify_keys(Map.get(snapshot, :queue_depth, %{})),
          denials: stringify_denials(Map.get(snapshot, :denials, []))
        }
    end
  rescue
    _error -> %{status: "unavailable"}
  end

  defp store_status(store) do
    case Process.whereis(store) do
      nil ->
        %{status: "unavailable", incomplete_rounds: nil}

      _pid ->
        case store.stats() do
          {:ok, stats} -> Map.merge(%{status: "ok"}, stringify_keys(stats))
          {:error, reason} -> %{status: "error", error: inspect(reason)}
        end
    end
  rescue
    _error -> %{status: "unavailable", incomplete_rounds: nil}
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify_denials(denials) when is_list(denials) do
    Enum.map(denials, fn denial ->
      %{
        resource_kind: denial |> Map.get(:resource_kind) |> to_string(),
        reason: denial |> Map.get(:reason) |> to_string(),
        count: Map.get(denial, :count, 0)
      }
    end)
  end

  defp stringify_denials(_denials), do: []

  defp resolve_server(pid) when is_pid(pid), do: pid
  defp resolve_server(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_server(_server), do: nil

  defp resolve_server_option(opts) do
    opts
    |> Keyword.get(:server, __MODULE__)
    |> resolve_server()
    |> case do
      nil -> {:error, :daemon_unavailable}
      pid -> {:ok, pid}
    end
  end

  defp store_for_option(opts) do
    case resolve_server_option(opts) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :store)}
      {:error, _reason} = error -> error
    end
  catch
    :exit, _reason -> {:error, :daemon_unavailable}
  end

  defp configured_store do
    StoreConfig.resolve() |> StoreConfig.module()
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
