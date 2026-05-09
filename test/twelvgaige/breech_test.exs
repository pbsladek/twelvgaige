defmodule Twelvgaige.BreechTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech
  alias Twelvgaige.ResourceLimiter
  alias Twelvgaige.Round.Manifest
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Shell.Cache, as: ShellCache
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shot

  defmodule ProvenanceStore do
    use Agent

    @behaviour Twelvgaige.Store

    @terminal_statuses MapSet.new([:complete, :failed, :halted, :cancelled])

    def start_link(_opts \\ []) do
      Agent.start_link(
        fn ->
          %{
            rounds: %{},
            manifests: %{},
            events: %{},
            audit_events: %{},
            attempts: %{},
            tools: %{},
            transitions: MapSet.new()
          }
        end,
        name: __MODULE__
      )
    end

    @impl true
    def create_round(snapshot, manifest, audit_events) do
      Agent.get_and_update(__MODULE__, fn state ->
        round_id = value(snapshot, :id)

        if Map.has_key?(state.rounds, round_id) do
          {{:error, :round_already_exists}, state}
        else
          state =
            state
            |> put_in([:rounds, round_id], snapshot)
            |> put_in([:manifests, round_id], manifest)
            |> put_in([:audit_events, round_id], audit_events)

          {:ok, state}
        end
      end)
    end

    @impl true
    def record_attempt_started(attempt, audit_events),
      do: put_journal(:attempts, attempt_key(attempt), attempt, audit_events)

    @impl true
    def record_attempt_finished(attempt, audit_events),
      do: put_journal(:attempts, attempt_key(attempt), attempt, audit_events)

    @impl true
    def record_tool_intent(intent, audit_events),
      do: put_journal(:tools, tool_key(intent), intent, audit_events)

    @impl true
    def record_tool_result(result, audit_events),
      do: put_journal(:tools, tool_key(result), result, audit_events)

    @impl true
    def commit_transition(
          round_id,
          expected_version,
          transition_id,
          next_snapshot,
          events,
          audit_events
        ) do
      Agent.get_and_update(__MODULE__, fn state ->
        cond do
          MapSet.member?(state.transitions, {round_id, transition_id}) ->
            {:already_committed, state}

          not Map.has_key?(state.rounds, round_id) ->
            {{:error, :not_found}, state}

          value(state.rounds[round_id], :version) != expected_version ->
            {{:error, :version_conflict}, state}

          true ->
            events = assign_event_sequences(Map.get(state.events, round_id, []), events)
            next_snapshot = Map.put(next_snapshot, :version, expected_version + 1)

            state =
              state
              |> put_in([:rounds, round_id], next_snapshot)
              |> update_in([:events, round_id], &((&1 || []) ++ events))
              |> update_in([:audit_events, round_id], &((&1 || []) ++ audit_events))
              |> update_in([:transitions], &MapSet.put(&1, {round_id, transition_id}))

            {:ok, state}
        end
      end)
    end

    @impl true
    def get_round(round_id), do: fetch(:rounds, round_id)

    @impl true
    def get_manifest(round_id), do: fetch(:manifests, round_id)

    @impl true
    def list_rounds(opts \\ []) do
      Agent.get(__MODULE__, fn state ->
        status = Keyword.get(opts, :status)

        rounds =
          state.rounds
          |> Map.values()
          |> Enum.filter(&(is_nil(status) or value(&1, :status) == status))

        {:ok, rounds}
      end)
    end

    @impl true
    def list_shot_runs(round_id) do
      with {:ok, snapshot} <- get_round(round_id) do
        {:ok,
         snapshot
         |> value(:shots)
         |> Enum.map(fn shot ->
           %{
             round_id: round_id,
             shot_id: value(shot, :id),
             status: value(shot, :status),
             attempt: value(shot, :attempt) || 0
           }
         end)}
      end
    end

    @impl true
    def list_round_events(round_id, opts \\ []), do: list_events(:events, round_id, opts)

    @impl true
    def await_round_events(round_id, opts \\ []), do: list_round_events(round_id, opts)

    @impl true
    def list_audit_events(round_id, opts \\ []), do: list_events(:audit_events, round_id, opts)

    @impl true
    def list_attempt_journals(round_id), do: list_journals(:attempts, round_id)

    @impl true
    def list_tool_journals(round_id), do: list_journals(:tools, round_id)

    @impl true
    def list_incomplete_rounds do
      Agent.get(__MODULE__, fn state ->
        rounds =
          state.rounds
          |> Map.values()
          |> Enum.reject(&(value(&1, :status) in @terminal_statuses))

        {:ok, rounds}
      end)
    end

    @impl true
    def stats, do: {:ok, %{}}

    defp put_journal(kind, key, record, audit_events) do
      Agent.update(__MODULE__, fn state ->
        state
        |> put_in([kind, key], record)
        |> update_in([:audit_events, value(record, :round_id)], &((&1 || []) ++ audit_events))
      end)
    end

    defp fetch(kind, round_id) do
      Agent.get(__MODULE__, fn state ->
        case get_in(state, [kind, round_id]) do
          nil -> {:error, :not_found}
          value -> {:ok, value}
        end
      end)
    end

    defp list_events(kind, round_id, opts) do
      Agent.get(__MODULE__, fn state ->
        if Map.has_key?(state.rounds, round_id) do
          after_seq = Keyword.get(opts, :after_seq, 0)
          limit = Keyword.get(opts, :limit, 100)

          events =
            (get_in(state, [kind, round_id]) || [])
            |> Enum.filter(&((value(&1, :seq) || 0) > after_seq))
            |> Enum.take(limit)

          {:ok, events}
        else
          {:error, :not_found}
        end
      end)
    end

    defp list_journals(kind, round_id) do
      Agent.get(__MODULE__, fn state ->
        journals =
          state
          |> Map.fetch!(kind)
          |> Map.values()
          |> Enum.filter(&(value(&1, :round_id) == round_id))

        {:ok, journals}
      end)
    end

    defp assign_event_sequences(existing, events) do
      first_seq = length(existing) + 1

      events
      |> Enum.with_index(first_seq)
      |> Enum.map(fn {event, seq} -> Map.put(event, :seq, value(event, :seq) || seq) end)
    end

    defp attempt_key(record),
      do: {value(record, :round_id), value(record, :shot_id), value(record, :attempt)}

    defp tool_key(record) do
      {
        value(record, :round_id),
        value(record, :shot_id),
        value(record, :attempt),
        value(record, :id) || value(record, :provider_tool_call_id) ||
          value(record, :tool_call_index)
      }
    end

    defp value(record, key) when is_map(record),
      do: Map.get(record, key) || Map.get(record, Atom.to_string(key))
  end

  @workflow %{
    kind: :workflow,
    id: "breech_round",
    version: "1.0.0",
    shots: [
      %{id: "only", kind: :slug, agent: "agent", prompt: "hello"}
    ]
  }

  @safety_workflow %{
    kind: :workflow,
    id: "breech_safety",
    version: "1.0.0",
    shots: [
      %{id: "approval", kind: :safety, description: "review"},
      %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"]}
    ]
  }

  test "reports local daemon status" do
    name = :"breech_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Breech,
       name: name,
       daemon_id: "daemon_test",
       started_at: ~U[2026-05-01 00:00:00Z],
       started_mono_ms: System.monotonic_time(:millisecond)}
    )

    assert {:ok, status} = Breech.status(name)

    assert status.daemon_id == "daemon_test"
    assert status.status == "running"
    assert status.version == Twelvgaige.version()
    assert status.profile == "laptop"
    assert status.ipc == "in_vm"
    assert status.started_at == "2026-05-01T00:00:00Z"
    assert is_integer(status.uptime_ms)
    assert status.resources.status in ["ok", "unavailable"]
    assert status.store.status in ["ok", "unavailable"]
  end

  test "reports unavailable for a missing daemon process" do
    assert Breech.status(:missing_breech_process) == {:error, :daemon_unavailable}
  end

  test "starts, stores, lists, and fetches daemon-owned rounds" do
    round_id = "round_breech_#{System.unique_integer([:positive])}"

    assert {:ok, ^round_id} = Breech.start_round(@workflow, %{}, round_id: round_id)

    assert eventually(fn ->
             case Breech.get_round(round_id) do
               {:ok, snapshot} -> snapshot.status == :complete
               _other -> false
             end
           end)

    assert {:ok, snapshot} = Breech.get_round(round_id)
    assert snapshot.id == round_id
    assert snapshot.status == :complete
    assert [%{id: "only", status: :complete}] = snapshot.shots

    assert {:ok, rounds} = Breech.list_rounds()
    assert Enum.any?(rounds, &(&1.id == round_id))
  end

  test "daemon-owned rounds honor explicit admission policy before queueing" do
    round_id = "round_breech_admission_#{System.unique_integer([:positive])}"

    assert {:error, error} =
             Breech.start_round(@workflow, %{},
               round_id: round_id,
               admission_policy: :approved
             )

    assert error.reason == :policy_denied
    assert {:error, :not_found} = Breech.get_round(round_id)
  end

  test "starts daemon-owned rounds by workflow id from the configured shell cache" do
    parent = self()
    name = :"breech_cache_#{System.unique_integer([:positive])}"
    cache_name = :"shell_cache_#{System.unique_integer([:positive])}"
    round_id = "round_breech_cache_#{System.unique_integer([:positive])}"
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    agent_path = Path.join(root, "agents/inspector.yaml")

    File.mkdir_p!(Path.dirname(agent_path))
    File.write!(workflow_path, workflow_yaml("cached_inspector"))
    File.write!(agent_path, agent_yaml("cached_inspector", "cached-model", "Cached prompt"))

    start_supervised!({ShellCache, name: cache_name, paths: [root]})
    start_supervised!({Breech, name: name, shell_cache: cache_name, recover?: false})

    handler = fn model, messages, _opts ->
      send(parent, {:cached_loadout, model, messages})
      "ok"
    end

    assert {:ok, ^round_id} =
             Breech.start_round("cached_workflow", %{},
               server: name,
               round_id: round_id,
               mock_handler: handler
             )

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: name))
           end)

    assert_receive {:cached_loadout, "cached-model",
                    [%{role: "system", content: "Cached prompt"} | _]},
                   200
  end

  test "stores workflow and agent provenance for path-owned rounds" do
    name = :"breech_provenance_#{System.unique_integer([:positive])}"
    round_id = "round_breech_provenance_#{System.unique_integer([:positive])}"
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    agent_path = Path.join(root, "agents/inspector.yaml")

    File.mkdir_p!(Path.dirname(agent_path))
    File.write!(workflow_path, workflow_yaml("inspector"))
    File.write!(agent_path, agent_yaml("inspector", "provenance-model", "Provenance prompt"))

    start_supervised!(ProvenanceStore)
    start_supervised!({Breech, name: name, store: ProvenanceStore, recover?: false})

    assert {:ok, ^round_id} =
             Breech.start_round(workflow_path, %{}, server: name, round_id: round_id)

    assert {:ok, manifest} = ProvenanceStore.get_manifest(round_id)

    assert manifest.source.type == :path
    assert manifest.source.path == Path.expand(workflow_path)
    assert manifest.source.format == "yaml"
    assert is_binary(manifest.source.content_hash)

    assert [%{type: :path, path: expanded_agent_path, format: "yaml", content_hash: agent_hash}] =
             manifest.agent_sources

    assert expanded_agent_path == Path.expand(agent_path)
    assert is_binary(agent_hash)
    assert is_binary(manifest.agent_hashes["inspector"])
  end

  test "recovers scheduler-owned rounds through scheduler recovery" do
    name = :"breech_scheduler_recovery_#{System.unique_integer([:positive])}"
    round_id = "round_breech_scheduler_recovery_#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    assert {:ok, workflow} = Workflow.from_map(@workflow)

    snapshot =
      Snapshot.new(
        id: round_id,
        shell_id: workflow.id,
        shell_version: workflow.version,
        status: :firing,
        version: 1,
        input: %{},
        started_at: now,
        policy: %{scheduler_owned?: true, resource_profile: :laptop},
        resource_profile: :laptop,
        shots: [
          Shot.State.new(
            id: "only",
            kind: :slug,
            status: :running,
            attempt: 1,
            started_at: now
          )
        ]
      )

    manifest =
      Manifest.new(
        round_id: round_id,
        workflow: workflow,
        effective_resource_profile: :laptop,
        created_at: now
      )

    start_supervised!(ProvenanceStore)
    assert :ok = ProvenanceStore.create_round(snapshot, manifest, [])

    start_supervised!({Breech, name: name, store: ProvenanceStore})

    assert eventually(
             fn ->
               match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: name))
             end,
             50
           )

    assert {:ok, recovered} = Breech.get_round(round_id, server: name)
    assert recovered.policy.scheduler_owned?
    assert [%{id: "only", status: :complete, attempt: 2, history: [history]}] = recovered.shots
    assert history.status == :interrupted
    assert history.recovery_action == :retry_no_tool
  end

  test "rejects daemon-owned rounds with invalid input before queuing" do
    name = :"breech_input_#{System.unique_integer([:positive])}"

    start_supervised!({Breech, name: name, recover?: false})

    workflow =
      Map.put(@workflow, :input_schema, %{
        type: :object,
        required: ["cluster"],
        properties: %{cluster: %{type: :string}},
        additionalProperties: false
      })

    assert {:error, error} =
             Breech.start_round(workflow, %{"cluster" => 123},
               server: name,
               round_id: "round_breech_invalid_input"
             )

    assert error.class == :input_error
    assert error.reason == :input_schema_violation
    assert Breech.get_round("round_breech_invalid_input", server: name) == {:error, :not_found}
  end

  test "can list rounds by status" do
    round_id = "round_breech_filter_#{System.unique_integer([:positive])}"

    assert {:ok, ^round_id} = Breech.start_round(@workflow, %{}, round_id: round_id)
    assert eventually(fn -> match?({:ok, %{status: :complete}}, Breech.get_round(round_id)) end)

    assert {:ok, complete_rounds} = Breech.list_rounds(status: :complete)
    assert Enum.any?(complete_rounds, &(&1.id == round_id))
  end

  test "approves an awaiting safety shot and resumes the round" do
    round_id = "round_breech_approve_#{System.unique_integer([:positive])}"

    assert {:ok, ^round_id} = Breech.start_round(@safety_workflow, %{}, round_id: round_id)

    assert eventually(fn ->
             match?({:ok, %{status: :awaiting_safety}}, Breech.get_round(round_id))
           end)

    assert :ok =
             Breech.approve_safety(round_id, "approval", reason: "reviewed", actor: "human:test")

    assert eventually(fn -> match?({:ok, %{status: :complete}}, Breech.get_round(round_id)) end)

    assert {:ok, snapshot} = Breech.get_round(round_id)
    shots = Map.new(snapshot.shots, &{&1.id, &1})
    assert shots["approval"].output["reason"] == "reviewed"
    assert shots["after"].status == :complete
  end

  test "rejects safety decisions when the round is not awaiting that shot" do
    complete_round_id = "round_breech_complete_decision_#{System.unique_integer([:positive])}"

    assert {:ok, ^complete_round_id} =
             Breech.start_round(@workflow, %{}, round_id: complete_round_id)

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(complete_round_id))
           end)

    assert {:error, complete_error} = Breech.approve_safety(complete_round_id, "approval")
    assert complete_error.reason == :policy_denied

    safety_round_id = "round_breech_wrong_decision_#{System.unique_integer([:positive])}"

    assert {:ok, ^safety_round_id} =
             Breech.start_round(@safety_workflow, %{}, round_id: safety_round_id)

    assert eventually(fn ->
             match?({:ok, %{status: :awaiting_safety}}, Breech.get_round(safety_round_id))
           end)

    assert {:error, shot_error} = Breech.approve_safety(safety_round_id, "not_approval")
    assert shot_error.reason == :policy_denied
  end

  test "rejects an awaiting safety shot and halts the round" do
    round_id = "round_breech_reject_#{System.unique_integer([:positive])}"

    assert {:ok, ^round_id} = Breech.start_round(@safety_workflow, %{}, round_id: round_id)

    assert eventually(fn ->
             match?({:ok, %{status: :awaiting_safety}}, Breech.get_round(round_id))
           end)

    assert :ok =
             Breech.reject_safety(round_id, "approval", reason: "too risky", actor: "human:test")

    assert eventually(fn -> match?({:ok, %{status: :halted}}, Breech.get_round(round_id)) end)

    assert {:ok, snapshot} = Breech.get_round(round_id)
    assert snapshot.error.reason == :safety_rejected
    shots = Map.new(snapshot.shots, &{&1.id, &1})
    assert shots["approval"].status == :failed
    assert shots["after"].status == :pending
  end

  test "cancels an awaiting safety round" do
    round_id = "round_breech_cancel_#{System.unique_integer([:positive])}"

    assert {:ok, ^round_id} = Breech.start_round(@safety_workflow, %{}, round_id: round_id)

    assert eventually(fn ->
             match?({:ok, %{status: :awaiting_safety}}, Breech.get_round(round_id))
           end)

    assert :ok = Breech.cancel_round(round_id, reason: "operator stop", actor: "human:test")
    assert {:ok, snapshot} = Breech.get_round(round_id)

    assert snapshot.status == :cancelled
    assert snapshot.awaiting_safety == []
    assert Enum.all?(snapshot.shots, &(&1.status == :cancelled))
    assert Enum.all?(snapshot.shots, &(&1.output["reason"] == "operator stop"))
  end

  test "cancels an active round task and prevents late results from replacing cancellation" do
    round_id = "round_breech_cancel_active_#{System.unique_integer([:positive])}"
    parent = self()

    handler = fn request ->
      send(parent, {:handler_entered, request["shot_id"]})
      Process.sleep(5_000)
      :await
    end

    assert {:ok, ^round_id} =
             Breech.start_round(@safety_workflow, %{},
               round_id: round_id,
               safety_handler: handler
             )

    assert_receive {:handler_entered, "approval"}, 1_000
    assert :ok = Breech.cancel_round(round_id, reason: "stop active", actor: "human:test")
    assert {:ok, snapshot} = Breech.get_round(round_id)

    assert snapshot.status == :cancelled
    assert Enum.all?(snapshot.shots, &(&1.status == :cancelled))
  end

  test "stopping Breech terminates active round tasks and releases their resource permits" do
    name = :"breech_shutdown_cleanup_#{System.unique_integer([:positive])}"

    limiter =
      start_supervised!(%{
        id: {:breech_shutdown_limiter, name},
        start: {ResourceLimiter, :start_link, [[name: nil, limits: %{active_shot: 1}]]}
      })

    start_supervised!({Breech, name: name, recover?: false})

    handler = fn _model, _messages, _opts ->
      Process.sleep(5_000)
      "too late"
    end

    assert {:ok, _round_id} =
             Breech.start_round(@workflow, %{},
               server: name,
               limiter: limiter,
               mock_handler: handler
             )

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).used.active_shot == 1 end)

    stop_supervised!(Breech)

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).used.active_shot == 0 end, 50)
  end

  defp eventually(fun), do: eventually(fun, 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts_left) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts_left - 1)
    end
  end

  defp tmp_dir! do
    path = Path.join(System.tmp_dir!(), "twelvgaige-breech-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp workflow_yaml(agent_id) do
    """
    kind: workflow
    id: cached_workflow
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: #{agent_id}
        prompt: inspect
    """
  end

  defp agent_yaml(agent_id, model, prompt) do
    """
    kind: agent
    id: #{agent_id}
    version: 1.0.0
    provider: mock
    model: #{model}
    system_prompt: #{prompt}
    """
  end
end
