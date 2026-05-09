defmodule Twelvgaige.Round.ServerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.ResourceLimiter
  alias Twelvgaige.Round.Server
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Shell.Agent, as: ShellAgent
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shot

  defmodule TransitionStore do
    use Agent

    def start_link(_opts) do
      Agent.start_link(
        fn ->
          %{
            rounds: %{},
            manifests: %{},
            transitions: [],
            attempts: [],
            fail_event_types: MapSet.new()
          }
        end,
        name: __MODULE__
      )
    end

    def fail_event_types(event_types) do
      Agent.update(__MODULE__, &Map.put(&1, :fail_event_types, MapSet.new(event_types)))
    end

    def transitions, do: Agent.get(__MODULE__, & &1.transitions)
    def attempts, do: Agent.get(__MODULE__, & &1.attempts)

    def create_round(snapshot, manifest, _audit_events) do
      Agent.get_and_update(__MODULE__, fn state ->
        if Map.has_key?(state.rounds, snapshot.id) do
          {{:error, :round_already_exists}, state}
        else
          state =
            state
            |> put_in([:rounds, snapshot.id], snapshot)
            |> put_in([:manifests, snapshot.id], manifest)

          {:ok, state}
        end
      end)
    end

    def get_round(round_id) do
      Agent.get(__MODULE__, fn state ->
        case Map.fetch(state.rounds, round_id) do
          {:ok, snapshot} -> {:ok, snapshot}
          :error -> {:error, :not_found}
        end
      end)
    end

    def commit_transition(
          round_id,
          expected_version,
          transition_id,
          next_snapshot,
          events,
          _audit_events
        ) do
      event_type = events |> List.first() |> Map.fetch!(:event_type)

      Agent.get_and_update(__MODULE__, fn state ->
        cond do
          MapSet.member?(state.fail_event_types, event_type) ->
            {{:error, :store_down}, state}

          not Map.has_key?(state.rounds, round_id) ->
            {{:error, :not_found}, state}

          state.rounds[round_id].version != expected_version ->
            {{:error, :version_conflict}, state}

          true ->
            next_snapshot = %{next_snapshot | version: expected_version + 1}

            state =
              state
              |> put_in([:rounds, round_id], next_snapshot)
              |> update_in([:transitions], &(&1 ++ [{transition_id, event_type}]))

            {:ok, state}
        end
      end)
    end

    def record_attempt_started(attempt, _audit_events) do
      Agent.update(__MODULE__, &update_in(&1.attempts, fn attempts -> attempts ++ [attempt] end))
    end

    def record_attempt_finished(_attempt, _audit_events), do: :ok
  end

  test "runs a foreground round through a GenServer" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_simple",
        version: "1.0.0",
        shots: [%{id: "only", kind: :slug, agent: "agent", prompt: "hello"}]
      })

    assert {:ok, snapshot} = Server.run_sync(workflow, %{}, round_id: "round_server")

    assert snapshot.id == "round_server"
    assert snapshot.status == :complete
    assert [%{id: "only", status: :complete}] = snapshot.shots
  end

  test "scheduler path handles successful task results and fires dependent shots" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_success",
        version: "1.0.0",
        shots: [
          %{id: "first", kind: :slug, agent: "agent", prompt: "first"},
          %{id: "second", kind: :slug, agent: "agent", depends_on: ["first"], prompt: "second"}
        ]
      })

    assert {:ok, snapshot} =
             Server.run_sync(workflow, %{},
               round_id: "round_server_scheduler_success",
               scheduler?: true,
               limiter: nil
             )

    assert snapshot.status == :complete

    assert Enum.map(snapshot.shots, &{&1.id, &1.status}) == [
             {"first", :complete},
             {"second", :complete}
           ]
  end

  test "scheduler path initializes shots as pending before chambered work can start" do
    start_supervised!(TransitionStore)
    TransitionStore.fail_event_types([:round_started])

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_initial_pending",
        version: "1.0.0",
        shots: [
          %{id: "root", kind: :slug, agent: "agent", prompt: "root"},
          %{id: "after", kind: :slug, agent: "agent", depends_on: ["root"], prompt: "after"}
        ]
      })

    {:ok, pid} =
      Server.start_link(
        {workflow, %{},
         [
           round_id: "round_server_scheduler_initial_pending",
           scheduler?: true,
           limiter: nil,
           store: TransitionStore,
           store_retry_ms: 10
         ]}
      )

    assert eventually(fn ->
             {:ok, snapshot} = Server.snapshot(pid)
             snapshot.status == :blocked_on_store
           end)

    assert {:ok, snapshot} = Server.snapshot(pid)
    assert snapshot.status == :blocked_on_store

    assert Enum.map(snapshot.shots, &{&1.id, &1.status}) == [
             {"after", :pending},
             {"root", :pending}
           ]
  end

  test "scheduler path fires all root shots on chamber" do
    parent = self()

    handler = fn _model, _messages, opts ->
      send(parent, {:shot_started, get_in(opts, [:limiter_context, :shot_id])})
      "ok"
    end

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_root_shots",
        version: "1.0.0",
        shots: [
          %{id: "root_a", kind: :slug, agent: "agent", prompt: "root a"},
          %{id: "root_b", kind: :slug, agent: "agent", prompt: "root b"}
        ]
      })

    assert {:ok, snapshot} =
             Server.run_sync(workflow, %{},
               round_id: "round_server_scheduler_root_shots",
               scheduler?: true,
               limiter: nil,
               mock_handler: handler
             )

    assert_receive {:shot_started, "root_a"}, 200
    assert_receive {:shot_started, "root_b"}, 200

    assert snapshot.status == :complete

    assert Enum.map(snapshot.shots, &{&1.id, &1.status}) == [
             {"root_a", :complete},
             {"root_b", :complete}
           ]
  end

  test "scheduler path runs independent store-backed shots in parallel after start commits" do
    start_supervised!(TransitionStore)
    parent = self()

    handler = fn _model, _messages, opts ->
      shot_id = get_in(opts, [:limiter_context, :shot_id])
      send(parent, {:shot_started, shot_id, self()})

      receive do
        :release -> "ok #{shot_id}"
      after
        1_000 -> exit(:mock_handler_timeout)
      end
    end

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_store_parallel_roots",
        version: "1.0.0",
        shots: [
          %{id: "root_a", kind: :slug, agent: "agent", prompt: "root a"},
          %{id: "root_b", kind: :slug, agent: "agent", prompt: "root b"}
        ]
      })

    task =
      Task.async(fn ->
        Server.run_sync(workflow, %{},
          round_id: "round_server_scheduler_store_parallel_roots",
          scheduler?: true,
          limiter: nil,
          store: TransitionStore,
          mock_handler: handler
        )
      end)

    started =
      for _ <- 1..2 do
        assert_receive {:shot_started, shot_id, pid}, 1_000
        {shot_id, pid}
      end

    assert started |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["root_a", "root_b"]

    event_types =
      Enum.map(TransitionStore.transitions(), fn {_transition_id, event_type} -> event_type end)

    assert event_types == [:round_started, :shot_started, :shot_started]

    Enum.each(started, fn {_shot_id, pid} -> send(pid, :release) end)

    assert {:ok, snapshot} = Task.await(task, 1_000)

    shots = shots_by_id(snapshot)
    assert snapshot.status == :complete
    assert shots["root_a"].status == :complete
    assert shots["root_b"].status == :complete
  end

  test "scheduler path commits skipped shots when conditions evaluate false" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_condition_skip",
        version: "1.0.0",
        shots: [
          %{
            id: "only",
            kind: :slug,
            agent: "agent",
            condition: "input.enabled == true",
            prompt: "only"
          }
        ]
      })

    assert {:ok, snapshot} =
             Server.run_sync(workflow, %{"enabled" => false},
               round_id: "round_server_scheduler_condition_skip",
               scheduler?: true,
               limiter: nil
             )

    assert snapshot.status == :complete
    assert [%{id: "only", status: :skipped, output: %{"skipped" => true}}] = snapshot.shots
  end

  test "scheduler path uses referenced agent loadout for shot execution" do
    parent = self()

    {:ok, agent} =
      ShellAgent.from_map(%{
        kind: :agent,
        id: "inspector",
        version: "1.0.0",
        provider: "mock",
        model: "scheduler-agent-model",
        system_prompt: "Scheduler agent prompt"
      })

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_agent_loadout",
        version: "1.0.0",
        shots: [%{id: "inspect", kind: :slug, agent: "inspector", prompt: "inspect"}]
      })

    handler = fn model, messages, _opts ->
      send(parent, {:scheduler_loadout, model, messages})
      "ok"
    end

    assert {:ok, snapshot} =
             Server.run_sync(workflow, %{},
               round_id: "round_server_scheduler_agent_loadout",
               scheduler?: true,
               limiter: nil,
               agents: [agent],
               mock_handler: handler
             )

    assert snapshot.status == :complete

    assert_receive {:scheduler_loadout, "scheduler-agent-model",
                    [%{role: "system", content: "Scheduler agent prompt"} | _]},
                   200
  end

  test "scheduler path commits store transitions before firing dependent shots" do
    start_supervised!(TransitionStore)

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_store_success",
        version: "1.0.0",
        shots: [
          %{id: "first", kind: :slug, agent: "agent", prompt: "first"},
          %{id: "second", kind: :slug, agent: "agent", depends_on: ["first"], prompt: "second"}
        ]
      })

    assert {:ok, snapshot} =
             Server.run_sync(workflow, %{},
               round_id: "round_server_scheduler_store_success",
               scheduler?: true,
               limiter: nil,
               store: TransitionStore
             )

    assert snapshot.status == :complete

    event_types =
      Enum.map(TransitionStore.transitions(), fn {_transition_id, event_type} -> event_type end)

    assert event_types == [
             :round_started,
             :shot_started,
             :shot_completed,
             :shot_started,
             :shot_completed,
             :round_completed
           ]
  end

  test "scheduler path blocks on store failure and does not fire dependents" do
    start_supervised!(TransitionStore)
    TransitionStore.fail_event_types([:shot_completed])

    parent = self()

    handler = fn _model, _messages, opts ->
      send(parent, {:shot_started, get_in(opts, [:limiter_context, :shot_id])})
      "ok"
    end

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_store_failure",
        version: "1.0.0",
        shots: [
          %{id: "first", kind: :slug, agent: "agent", prompt: "first"},
          %{id: "second", kind: :slug, agent: "agent", depends_on: ["first"], prompt: "second"}
        ]
      })

    {:ok, pid} =
      Server.start_link(
        {workflow, %{},
         [
           round_id: "round_server_scheduler_store_failure",
           scheduler?: true,
           limiter: nil,
           store: TransitionStore,
           store_retry_ms: 10,
           mock_handler: handler
         ]}
      )

    assert_receive {:shot_started, "first"}, 200

    assert eventually(fn ->
             {:ok, snapshot} = Server.snapshot(pid)
             snapshot.status == :blocked_on_store
           end)

    assert {:ok, snapshot} = Server.snapshot(pid)
    shots = shots_by_id(snapshot)

    assert snapshot.status == :blocked_on_store
    assert shots["first"].status == :running
    assert shots["second"].status == :pending
    refute_receive {:shot_started, "second"}, 50
  end

  test "scheduler path releases admitted shot permits when start transition blocks on store" do
    start_supervised!(TransitionStore)
    TransitionStore.fail_event_types([:shot_started])

    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{active_shot: 1}})

    {:ok, pid} =
      Server.start_link(
        {workflow!("server_scheduler_store_start_block"), %{},
         [
           round_id: "round_server_scheduler_store_start_block",
           scheduler?: true,
           limiter: limiter,
           store: TransitionStore,
           store_retry_ms: 10
         ]}
      )

    assert eventually(fn ->
             {:ok, snapshot} = Server.snapshot(pid)
             snapshot.status == :blocked_on_store
           end)

    assert {:ok, snapshot} = Server.snapshot(pid)
    assert snapshot.status == :blocked_on_store
    assert [%{id: "only", status: :pending}] = snapshot.shots
    assert eventually(fn -> ResourceLimiter.snapshot(limiter).used.active_shot == 0 end)
  end

  test "scheduler path reacquires released shot permits after a blocked start transition recovers" do
    start_supervised!(TransitionStore)
    TransitionStore.fail_event_types([:shot_started])

    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{active_shot: 1}})

    {:ok, pid} =
      Server.start_link(
        {workflow!("server_scheduler_store_start_recover"), %{},
         [
           round_id: "round_server_scheduler_store_start_recover",
           scheduler?: true,
           limiter: limiter,
           store: TransitionStore,
           store_retry_ms: 10
         ]}
      )

    assert eventually(fn ->
             {:ok, snapshot} = Server.snapshot(pid)
             snapshot.status == :blocked_on_store
           end)

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).used.active_shot == 0 end)
    assert TransitionStore.attempts() == []

    assert {:ok, held} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "other", shot_id: "other"},
               server: limiter
             )

    TransitionStore.fail_event_types([])

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).queue_depth.active_shot == 1 end)
    assert TransitionStore.attempts() == []

    assert :ok = ResourceLimiter.release(held)
    assert {:ok, snapshot} = GenServer.call(pid, :await, 1_000)

    assert snapshot.status == :complete
    assert [%{id: "only", status: :complete}] = snapshot.shots
    assert [%{shot_id: "only", attempt: 1}] = TransitionStore.attempts()
    assert ResourceLimiter.snapshot(limiter).used.active_shot == 0
    assert ResourceLimiter.snapshot(limiter).queue_depth.active_shot == 0
  end

  test "scheduler path drops queued blocked-start waiters when the server exits" do
    start_supervised!(TransitionStore)
    TransitionStore.fail_event_types([:shot_started])

    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{active_shot: 1}})

    {:ok, pid} =
      Server.start_link(
        {workflow!("server_scheduler_store_start_stop"), %{},
         [
           round_id: "round_server_scheduler_store_start_stop",
           scheduler?: true,
           limiter: limiter,
           store: TransitionStore,
           store_retry_ms: 10
         ]}
      )

    assert eventually(fn ->
             {:ok, snapshot} = Server.snapshot(pid)
             snapshot.status == :blocked_on_store
           end)

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).used.active_shot == 0 end)

    assert {:ok, held} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "other", shot_id: "other"},
               server: limiter
             )

    TransitionStore.fail_event_types([])

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).queue_depth.active_shot == 1 end)

    ref = Process.monitor(pid)
    GenServer.stop(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).queue_depth.active_shot == 0 end)
    assert TransitionStore.attempts() == []

    assert :ok = ResourceLimiter.release(held)
    assert ResourceLimiter.snapshot(limiter).used.active_shot == 0
    assert ResourceLimiter.snapshot(limiter).queue_depth.active_shot == 0
  end

  test "scheduler recovery retries journal-safe interrupted shots" do
    workflow = workflow!("server_scheduler_recovery")

    snapshot =
      Snapshot.new(
        id: "round_server_scheduler_recovery",
        shell_id: workflow.id,
        shell_version: workflow.version,
        status: :firing,
        version: 1,
        input: %{},
        started_at: DateTime.utc_now(),
        shots: [
          Shot.State.new(
            id: "only",
            kind: :slug,
            status: :running,
            attempt: 1,
            started_at: DateTime.utc_now()
          )
        ]
      )

    assert {:ok, recovered} =
             Server.recover_sync(workflow, snapshot,
               limiter: nil,
               timeout: 1_000
             )

    assert recovered.status == :complete
    assert [%{id: "only", status: :complete, attempt: 2, history: [history]}] = recovered.shots
    assert history.status == :interrupted
    assert history.recovery_action == :retry_no_tool
  end

  test "scheduler path handles task crashes as classified shot failures" do
    starter = fn _fun ->
      pid = spawn(fn -> exit(:boom) end)
      ref = Process.monitor(pid)
      {:ok, %{pid: pid, result_ref: ref, monitor_ref: ref}}
    end

    assert {:ok, snapshot} =
             Server.run_sync(workflow!("server_scheduler_crash"), %{},
               round_id: "round_server_scheduler_crash",
               scheduler?: true,
               limiter: nil,
               shot_task_starter: starter
             )

    assert snapshot.status == :failed
    assert [%{id: "only", status: :failed, error: error}] = snapshot.shots
    assert error.class == :crash_error
    assert error.reason == :shot_crash
  end

  test "scheduler path releases shot permits if task start fails after admission" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{active_shot: 1}})

    assert {:ok, snapshot} =
             Server.run_sync(workflow!("server_scheduler_start_failure"), %{},
               round_id: "round_server_scheduler_start_failure",
               scheduler?: true,
               limiter: limiter,
               shot_task_starter: fn _fun -> {:error, :task_supervisor_down} end
             )

    assert snapshot.status == :failed
    assert [%{status: :failed, error: %{reason: :shot_crash}}] = snapshot.shots
    assert ResourceLimiter.snapshot(limiter).used.active_shot == 0
  end

  test "scheduler path handles shot timeout and retries when policy allows it" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_timeout_retry",
        version: "1.0.0",
        shots: [
          %{
            id: "only",
            kind: :slug,
            agent: "agent",
            prompt: "hello",
            timeout: "25ms",
            retry: %{
              max_attempts: 2,
              base_delay: "0ms",
              max_delay: "0ms",
              retryable_errors: [:shot_timeout]
            }
          }
        ]
      })

    handler = fn _model, _messages, opts ->
      case get_in(opts, [:limiter_context, :attempt]) do
        1 ->
          receive do
            :release -> "late"
          after
            1_000 -> exit(:mock_handler_timeout)
          end

        2 ->
          "ok"
      end
    end

    assert {:ok, snapshot} =
             Server.run_sync(workflow, %{},
               round_id: "round_server_scheduler_timeout_retry",
               scheduler?: true,
               limiter: nil,
               mock_handler: handler,
               timeout: 1_000
             )

    assert snapshot.status == :complete

    assert [%{id: "only", status: :complete, attempt: 2, history: [failed_attempt]}] =
             snapshot.shots

    assert failed_attempt.error.reason == "shot_timeout"
  end

  test "scheduler path ignores stale task results from old attempts" do
    parent = self()
    counter = :counters.new(1, [])

    starter = fn _fun ->
      :counters.add(counter, 1, 1)
      attempt = :counters.get(counter, 1)
      server = self()
      result_ref = make_ref()

      if attempt == 1 do
        pid = spawn(fn -> Process.sleep(:infinity) end)
        monitor_ref = Process.monitor(pid)

        stale_sender =
          spawn(fn ->
            receive do
              :send_stale ->
                send(
                  server,
                  {result_ref,
                   {:shot_result, "only", 1,
                    {:ok, %{content: "stale", output: "stale", tool_calls: [], usage: %{}}}}}
                )

                send(parent, :stale_result_sent)
            after
              1_000 -> exit(:stale_sender_timeout)
            end
          end)

        send(parent, {:stale_sender, stale_sender})

        {:ok, %{pid: pid, result_ref: result_ref, monitor_ref: monitor_ref}}
      else
        pid =
          spawn(fn ->
            send(
              server,
              {result_ref,
               {:shot_result, "only", 2,
                {:ok, %{content: "fresh", output: "fresh", tool_calls: [], usage: %{}}}}}
            )
          end)

        monitor_ref = Process.monitor(pid)
        {:ok, %{pid: pid, result_ref: result_ref, monitor_ref: monitor_ref}}
      end
    end

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_stale_result",
        version: "1.0.0",
        shots: [
          %{
            id: "only",
            kind: :slug,
            agent: "agent",
            prompt: "hello",
            timeout: "1ms",
            retry: %{
              max_attempts: 2,
              base_delay: "0ms",
              max_delay: "0ms",
              retryable_errors: [:shot_timeout]
            }
          }
        ]
      })

    {:ok, pid} =
      Server.start_link(
        {workflow, %{},
         [
           round_id: "round_server_scheduler_stale_result",
           scheduler?: true,
           limiter: nil,
           shot_task_starter: starter
         ]}
      )

    assert {:ok, snapshot} = GenServer.call(pid, :await, 1_000)
    assert snapshot.status == :complete

    assert [%{id: "only", status: :complete, attempt: 2, output: output}] = snapshot.shots
    refute output["content"] == "stale"

    assert_receive {:stale_sender, stale_sender}, 200
    send(stale_sender, :send_stale)
    assert_receive :stale_result_sent, 200
    assert {:ok, snapshot_after_stale} = Server.snapshot(pid)

    assert [%{id: "only", status: :complete, attempt: 2, output: output_after_stale}] =
             snapshot_after_stale.shots

    refute output_after_stale["content"] == "stale"
  end

  test "scheduler path cancels queued resource waiters" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{active_shot: 1}})

    assert {:ok, held} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "held", shot_id: "held"},
               server: limiter
             )

    {:ok, pid} =
      Server.start_link(
        {workflow!("server_scheduler_cancel_waiter"), %{},
         [
           round_id: "round_server_scheduler_cancel_waiter",
           scheduler?: true,
           limiter: limiter,
           queue_timeout_ms: 1_000
         ]}
      )

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).queue_depth.active_shot == 1 end)

    assert :ok = Server.cancel(pid, reason: "operator stop", actor: "human:test")
    assert {:ok, snapshot} = GenServer.call(pid, :await)

    assert snapshot.status == :cancelled
    assert [%{id: "only", status: :cancelled}] = snapshot.shots
    assert eventually(fn -> ResourceLimiter.snapshot(limiter).queue_depth.active_shot == 0 end)

    assert :ok = ResourceLimiter.release(held)
  end

  test "scheduler path cancels in-flight tasks and releases shot permits" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{active_shot: 1}})

    handler = fn _model, _messages, _opts ->
      Process.sleep(5_000)
      "too late"
    end

    {:ok, pid} =
      Server.start_link(
        {workflow!("server_scheduler_cancel_running"), %{},
         [
           round_id: "round_server_scheduler_cancel_running",
           scheduler?: true,
           limiter: limiter,
           mock_handler: handler
         ]}
      )

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).used.active_shot == 1 end)

    assert :ok = Server.cancel(pid, reason: "operator stop", actor: "human:test")
    assert {:ok, snapshot} = GenServer.call(pid, :await)

    assert snapshot.status == :cancelled
    assert [%{id: "only", status: :cancelled}] = snapshot.shots
    assert eventually(fn -> ResourceLimiter.snapshot(limiter).used.active_shot == 0 end)
  end

  test "scheduler path pauses at safety shot and resumes after targeted approval" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_safety_approval",
        version: "1.0.0",
        shots: [
          %{id: "approval", kind: :safety, description: "review"},
          %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"], prompt: "after"}
        ]
      })

    {:ok, pid} =
      Server.start_link(
        {workflow, %{},
         [
           round_id: "round_server_scheduler_safety_approval",
           scheduler?: true,
           limiter: nil
         ]}
      )

    assert {:ok, awaiting} = GenServer.call(pid, :await, 1_000)
    assert awaiting.status == :awaiting_safety

    awaiting_shots = shots_by_id(awaiting)
    assert awaiting_shots["approval"].status == :awaiting_safety
    assert awaiting_shots["after"].status == :pending

    assert :ok = Server.approve_safety(pid, "approval", reason: "reviewed", actor: "human:test")

    assert {:ok, snapshot} = GenServer.call(pid, :await, 1_000)
    assert snapshot.status == :complete

    shots = shots_by_id(snapshot)
    assert shots["approval"].status == :complete
    assert shots["after"].status == :complete
  end

  test "scheduler path halts after targeted safety rejection" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "server_scheduler_safety_rejection",
        version: "1.0.0",
        shots: [
          %{id: "approval", kind: :safety, description: "review"},
          %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"], prompt: "after"}
        ]
      })

    {:ok, pid} =
      Server.start_link(
        {workflow, %{},
         [
           round_id: "round_server_scheduler_safety_rejection",
           scheduler?: true,
           limiter: nil
         ]}
      )

    assert {:ok, awaiting} = GenServer.call(pid, :await, 1_000)
    assert awaiting.status == :awaiting_safety

    assert :ok = Server.reject_safety(pid, "approval", reason: "too risky", actor: "human:test")

    assert {:ok, snapshot} = GenServer.call(pid, :await, 1_000)
    assert snapshot.status == :halted
    assert snapshot.error.reason == :safety_rejected

    shots = shots_by_id(snapshot)
    assert shots["approval"].status == :failed
    assert shots["after"].status == :pending
  end

  test "queues ready shots when active-shot permits are unavailable and fires after release" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{active_shot: 1}})

    assert {:ok, held} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "held", shot_id: "held"},
               server: limiter
             )

    workflow = workflow!("server_queued")

    task =
      Task.async(fn ->
        Server.run_sync(workflow, %{},
          round_id: "round_server_queued",
          limiter: limiter,
          queue_timeout_ms: 1_000
        )
      end)

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).queue_depth.active_shot == 1 end)

    assert :ok = ResourceLimiter.release(held)
    assert {:ok, snapshot} = Task.await(task, 1_000)

    assert snapshot.status == :complete
    assert [%{id: "only", status: :complete}] = snapshot.shots
    assert ResourceLimiter.snapshot(limiter).used.active_shot == 0
  end

  test "queues the round before execution when active-round permits are unavailable" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{active_round: 1}})

    assert {:ok, held} =
             ResourceLimiter.acquire(:active_round, %{round_id: "held"}, server: limiter)

    workflow = workflow!("server_round_queued")

    task =
      Task.async(fn ->
        Server.run_sync(workflow, %{},
          round_id: "round_server_round_queued",
          limiter: limiter,
          queue_timeout_ms: 1_000
        )
      end)

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).queue_depth.active_round == 1 end)

    assert :ok = ResourceLimiter.release(held)
    assert {:ok, snapshot} = Task.await(task, 1_000)

    assert snapshot.id == "round_server_round_queued"
    assert snapshot.status == :complete
    assert ResourceLimiter.snapshot(limiter).used.active_round == 0
  end

  test "returns an error when active-round admission times out before execution" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{active_round: 1}})

    assert {:ok, held} =
             ResourceLimiter.acquire(:active_round, %{round_id: "held"}, server: limiter)

    assert {:error, error} =
             Server.run_sync(workflow!("server_round_queue_timeout"), %{},
               round_id: "round_server_round_queue_timeout",
               limiter: limiter,
               queue_timeout_ms: 1
             )

    assert error.class == :timeout_error
    assert error.reason == :resource_queue_timeout

    assert :ok = ResourceLimiter.release(held)
  end

  test "marks shot failed when queued active-shot admission times out" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{active_shot: 1}})

    assert {:ok, held} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "held", shot_id: "held"},
               server: limiter
             )

    assert {:ok, snapshot} =
             Server.run_sync(workflow!("server_queue_timeout"), %{},
               round_id: "round_server_queue_timeout",
               limiter: limiter,
               queue_timeout_ms: 1
             )

    assert snapshot.status == :failed
    assert snapshot.error.reason == :resource_queue_timeout
    assert [%{id: "only", status: :failed, error: error}] = snapshot.shots
    assert error.reason == :resource_queue_timeout

    assert :ok = ResourceLimiter.release(held)
  end

  defp workflow!(id) do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: id,
        version: "1.0.0",
        shots: [%{id: "only", kind: :slug, agent: "agent", prompt: "hello"}]
      })

    workflow
  end

  defp eventually(fun), do: eventually(fun, 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts_left) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts_left - 1)
    end
  end

  defp shots_by_id(snapshot), do: Map.new(snapshot.shots, &{&1.id, &1})
end
