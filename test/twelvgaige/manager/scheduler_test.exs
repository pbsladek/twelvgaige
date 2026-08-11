defmodule Twelvgaige.Manager.SchedulerTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Handoff
  alias Twelvgaige.Manager.{Compiler, Envelope, Scheduler}
  alias Twelvgaige.Manager.Store.Memory

  test "schedules fairly across parent rounds and gives each writer a separate workspace/session" do
    parent = self()
    store = start_store()

    executor = fn child ->
      send(
        parent,
        {:started, child.plan_id, child.task_id, child.workspace_id, child.delegated_session_id,
         self()}
      )

      receive do: (:finish -> success(child))
    end

    scheduler = start_scheduler(store, executor, max_running: 1)
    first = compiled("plan-a", [task("a1"), task("a2")])
    second = compiled("plan-b", [task("b1")])

    assert {:ok, "plan-a", :submitted} = Scheduler.submit(first, server: scheduler)
    assert_receive {:started, "plan-a", "a1", workspace_a, session_a, worker_a}

    assert {:ok, "plan-b", :submitted} = Scheduler.submit(second, server: scheduler)
    send(worker_a, :finish)

    assert_receive {:started, "plan-b", "b1", workspace_b, session_b, worker_b}, 1_000
    refute workspace_a == workspace_b
    refute session_a == session_b
    send(worker_b, :finish)

    assert_receive {:started, "plan-a", "a2", workspace_a2, session_a2, worker_a2}, 1_000
    assert MapSet.size(MapSet.new([workspace_a, workspace_b, workspace_a2])) == 3
    assert MapSet.size(MapSet.new([session_a, session_b, session_a2])) == 3
    send(worker_a2, :finish)

    assert_eventually(fn ->
      match?({:ok, %{status: :completed}}, Scheduler.status("plan-a", server: scheduler))
    end)

    assert_eventually(fn ->
      match?({:ok, %{status: :completed}}, Scheduler.status("plan-b", server: scheduler))
    end)
  end

  test "review returns JSON-safe handoffs, usage, and events without mutation" do
    store = start_store()
    scheduler = start_scheduler(store, fn child -> success(child) end, [])
    plan = compiled("review-plan", [task("review-child")])

    assert {:ok, "review-plan", :submitted} = Scheduler.submit(plan, server: scheduler)

    assert_eventually(fn ->
      match?({:ok, %{status: :completed}}, Scheduler.status("review-plan", server: scheduler))
    end)

    assert {:ok, review} = Scheduler.review("review-plan", server: scheduler)
    assert review.mutates_state == false
    assert review.status == :completed
    assert [%{handoff: %{summary: _summary}, usage: usage}] = review.children
    assert is_map(usage)
    assert is_binary(Jason.encode!(review))
  end

  test "applies bounded queue backpressure before persisting children" do
    store = start_store()
    scheduler = start_scheduler(store, fn child -> success(child) end, max_queue_children: 2)
    plan = compiled("too-large", [task("one"), task("two"), task("three")], max_children: 3)

    assert {:error, :manager_queue_backpressure} = Scheduler.submit(plan, server: scheduler)
    assert {:error, :not_found} = Memory.get_plan("too-large", server: store)
    assert {:ok, []} = Memory.list_children("too-large", server: store)
  end

  test "reserves the aggregate plan then admits children incrementally as permits become available" do
    parent = self()
    store = start_store()
    permits = start_supervised!({Agent, fn -> 0 end})

    admit = fn child ->
      Agent.get_and_update(permits, fn
        available when available > 0 -> {{:ok, {:permit, child.id}}, available - 1}
        0 -> {{:wait, :capacity}, 0}
      end)
    end

    release = fn permit ->
      send(parent, {:child_permit_released, permit})
      :ok
    end

    executor = fn child ->
      send(parent, {:incremental_started, child.id, self()})

      receive do
        :incremental_finish -> success(child)
      end
    end

    scheduler =
      start_scheduler(store, executor,
        child_admit_fun: admit,
        child_release_fun: release
      )

    plan = compiled("incremental", [task("child")])
    assert {:ok, "incremental", :submitted} = Scheduler.submit(plan, server: scheduler)
    refute_receive {:incremental_started, _id, _pid}, 100

    Agent.update(permits, fn _ -> 1 end)
    assert :ok = Scheduler.capacity_available(server: scheduler)
    assert_receive {:incremental_started, child_id, worker}, 1_000

    assert {:ok, child} = Memory.get_child(child_id, server: store)
    assert child.status == :running
    assert child.resource_permit == {:permit, child_id}

    send(worker, :incremental_finish)
    assert_receive {:child_permit_released, {:permit, ^child_id}}, 1_000

    assert_eventually(fn ->
      match?({:ok, %{status: :completed}}, Scheduler.status("incremental", server: scheduler))
    end)

    assert {:ok, completed} = Memory.get_child(child_id, server: store)
    assert completed.resource_permit == nil
  end

  test "permanent child admission denial stops for review instead of waiting forever" do
    store = start_store()

    scheduler =
      start_scheduler(store, fn _child -> flunk("a denied child must not run") end,
        child_admit_fun: fn _child -> {:error, :host_headroom_unavailable} end
      )

    plan = compiled("admission-denied", [task("child")])
    assert {:ok, "admission-denied", :submitted} = Scheduler.submit(plan, server: scheduler)

    assert_eventually(fn ->
      match?(
        {:ok, %{status: :awaiting_review}},
        Scheduler.status("admission-denied", server: scheduler)
      )
    end)

    assert {:ok, [child]} = Memory.list_children("admission-denied", server: store)
    assert child.status == :awaiting_review
    assert child.error == {:manager_child_admission_failed, :host_headroom_unavailable}
  end

  test "tree-wide cancellation remains responsive at maximum fanout" do
    parent = self()
    store = start_store()

    executor = fn child ->
      send(parent, {:running, child.id})
      receive do: (:never -> success(child))
    end

    cancel = fn child ->
      send(parent, {:cancelled_runtime, child.id})
      :ok
    end

    scheduler = start_scheduler(store, executor, max_running: 16, cancel_fun: cancel)

    plan =
      compiled("cancel-plan", Enum.map(1..16, &task("child-#{&1}")),
        max_children: 16,
        max_fanout: 16
      )

    assert {:ok, "cancel-plan", :submitted} = Scheduler.submit(plan, server: scheduler)
    running = for _ <- 1..16, do: receive_message(:running)
    assert MapSet.size(MapSet.new(running)) == 16

    started = System.monotonic_time(:millisecond)
    assert :ok = Scheduler.cancel("cancel-plan", server: scheduler)
    assert System.monotonic_time(:millisecond) - started < 1_000

    cancelled = for _ <- 1..16, do: receive_message(:cancelled_runtime)
    assert MapSet.new(cancelled) == MapSet.new(running)

    assert {:ok, %{status: :cancelled, progress: %{by_status: %{cancelled: 16}}}} =
             Scheduler.status("cancel-plan", server: scheduler)
  end

  test "an unexpected worker exit stops the runtime and captures a terminal handoff" do
    parent = self()
    store = start_store()

    executor = fn child ->
      send(parent, {:crashing_child_running, child.id})
      exit(:simulated_crash)
    end

    cancel = fn child ->
      send(parent, {:crashing_runtime_stopped, child.id})

      {:ok,
       %{
         runtime_stopped: true,
         runtime_identity: "sandbox-#{child.id}",
         stopped_at: DateTime.utc_now()
       }}
    end

    finalize = fn child, {:error, reason, evidence} ->
      send(parent, {:crashing_workspace_finalized, child.id, reason, evidence})

      handoff =
        Handoff.new(%{
          objective_status: :failed,
          summary: "partial work captured",
          workspace_id: child.workspace_id,
          base_commit: "base",
          diff_artifact: "artifact:partial-#{child.id}"
        })

      {:error, reason, Map.put(evidence, :handoff, handoff)}
    end

    scheduler =
      start_scheduler(store, executor,
        max_running: 1,
        cancel_fun: cancel,
        workspace_finalize_fun: finalize
      )

    plan = compiled("worker-crash-finalization", [task("crash")])

    assert {:ok, "worker-crash-finalization", :submitted} =
             Scheduler.submit(plan, server: scheduler)

    assert_receive {:crashing_child_running, child_id}
    assert_receive {:crashing_runtime_stopped, ^child_id}

    assert_receive {:crashing_workspace_finalized, ^child_id, {:worker_exit, :simulated_crash},
                    %{runtime_quiescence: %{runtime_stopped: true}}}

    assert_eventually(fn ->
      match?(
        {:ok, %{status: :failed}},
        Scheduler.status("worker-crash-finalization", server: scheduler)
      )
    end)

    assert {:ok, failed} = Memory.get_child(child_id, server: store)
    assert failed.status == :failed
    assert failed.handoff.objective_status == :failed
    assert failed.handoff.diff_artifact == "artifact:partial-#{child_id}"
  end

  test "maximum supported fanout stays bounded and reconciles tree-wide usage" do
    store = start_store()
    concurrency = start_supervised!({Agent, fn -> %{active: 0, peak: 0} end})

    executor = fn child ->
      Agent.update(concurrency, fn state ->
        active = state.active + 1
        %{active: active, peak: max(state.peak, active)}
      end)

      Process.sleep(20)
      result = success(child)
      Agent.update(concurrency, &%{&1 | active: &1.active - 1})
      result
    end

    scheduler = start_scheduler(store, executor, max_running: 4, max_queue_children: 16)

    plan =
      compiled("load-plan", Enum.map(1..16, &task("load-#{&1}")), max_children: 16, max_fanout: 8)

    assert {:ok, "load-plan", :submitted} = Scheduler.submit(plan, server: scheduler)

    assert_eventually(
      fn ->
        match?({:ok, %{status: :completed}}, Scheduler.status("load-plan", server: scheduler))
      end,
      3_000
    )

    assert {:ok, view} = Scheduler.status("load-plan", server: scheduler)
    assert view.progress.by_status == %{completed: 16}

    assert view.budget.used.tokens == 16
    assert view.budget.used.cost_micros == 16
    assert view.budget.used.tool_calls == 16
    assert view.budget.used.time_ms >= 16 * 20

    assert Agent.get(concurrency, & &1.peak) == 4
    assert view.running == 0 and view.queued == 0

    assert {:ok, children} = Memory.list_children("load-plan", server: store)
    assert MapSet.size(MapSet.new(Enum.map(children, & &1.workspace_id))) == 16
    assert MapSet.size(MapSet.new(Enum.map(children, & &1.delegated_session_id))) == 16
  end

  test "scheduler crash recovery quarantines an in-flight identity instead of duplicating it" do
    parent = self()
    store = start_store()

    executor = fn child ->
      send(parent, {:first_execution, child.id, self()})
      receive do: (:never -> success(child))
    end

    permit = {:permit, "recovery"}

    scheduler =
      start_scheduler(store, executor, child_admit_fun: fn _child -> {:ok, permit} end)

    Process.unlink(scheduler)
    plan = compiled("recovery-plan", [task("only")])
    assert {:ok, "recovery-plan", :submitted} = Scheduler.submit(plan, server: scheduler)
    assert_receive {:first_execution, child_id, worker}
    assert {:ok, before_restart} = Memory.get_plan("recovery-plan", server: store)
    old_lease = before_restart.reservation_lease

    ref = Process.monitor(scheduler)
    Process.exit(scheduler, :kill)
    assert_receive {:DOWN, ^ref, :process, ^scheduler, :killed}
    assert_eventually(fn -> not Process.alive?(worker) end)

    replacement_lease = {:plan_lease, "recovered"}

    recovered =
      start_scheduler(
        store,
        fn child ->
          send(parent, {:duplicate_execution, child.id})
          success(child)
        end,
        reservation_recovery_fun: fn lease, budget, recovered_plan ->
          send(parent, {:reservation_reconciled, lease, budget, recovered_plan.id})
          {:ok, replacement_lease}
        end,
        child_release_fun: fn released ->
          send(parent, {:recovered_permit_released, released})
          :ok
        end
      )

    assert_receive {:reservation_reconciled, ^old_lease, _budget, "recovery-plan"}
    assert_receive {:recovered_permit_released, ^permit}
    refute_receive {:duplicate_execution, ^child_id}, 150

    assert {:ok, %{status: :awaiting_review, progress: %{by_status: %{awaiting_review: 1}}}} =
             Scheduler.status("recovery-plan", server: recovered)

    assert {:ok, [child]} = Memory.list_children("recovery-plan", server: store)
    assert child.id == child_id
    assert child.error == :scheduler_recovery_quarantined
    assert child.resource_permit == nil
    assert {:ok, after_restart} = Memory.get_plan("recovery-plan", server: store)
    assert after_restart.reservation_lease == replacement_lease
  end

  test "a verifier cannot validate a dependent worker under the same principal" do
    store = start_store()

    executor = fn child ->
      case child.task.role do
        :worker -> success(child, "shared-principal")
        :verifier -> success(child, "shared-principal")
      end
    end

    scheduler = start_scheduler(store, executor, max_running: 2)

    tasks = [
      task("worker"),
      task("verify", role: :verifier, write: false, depends_on: ["worker"])
    ]

    plan = compiled("independence-plan", tasks, max_children: 2)
    assert {:ok, "independence-plan", :submitted} = Scheduler.submit(plan, server: scheduler)

    assert_eventually(fn ->
      match?(
        {:ok, %{status: :awaiting_review}},
        Scheduler.status("independence-plan", server: scheduler)
      )
    end)

    assert {:ok, children} = Memory.list_children("independence-plan", server: store)
    verifier = Enum.find(children, &(&1.task.role == :verifier))
    assert verifier.status == :awaiting_review
    assert verifier.error == :manager_verifier_not_independent
  end

  test "the scheduler enforces a plan deadline while all children wait for capacity" do
    store = start_store()

    scheduler =
      start_scheduler(store, fn _child -> flunk("a deadline-expired child must not run") end,
        child_admit_fun: fn _child -> {:wait, :capacity} end
      )

    deadline = DateTime.add(DateTime.utc_now(), 75, :millisecond)
    plan = compiled("deadline-plan", [task("waiting")], deadline: deadline)
    assert {:ok, "deadline-plan", :submitted} = Scheduler.submit(plan, server: scheduler)

    assert_eventually(
      fn ->
        match?(
          {:ok, %{status: :failed, error: :plan_deadline_exceeded}},
          Scheduler.status("deadline-plan", server: scheduler)
        )
      end,
      1_000
    )

    assert {:ok, [child]} = Memory.list_children("deadline-plan", server: store)
    assert child.status == :cancelled
    assert child.error == :plan_deadline_exceeded
  end

  test "a child result cannot silently omit tree-wide usage accounting" do
    store = start_store()

    executor = fn child ->
      {:ok,
       Handoff.new(%{
         objective_status: :complete,
         summary: "missing usage",
         workspace_id: child.workspace_id,
         base_commit: "base",
         diff_artifact: "artifact:patch"
       })}
    end

    scheduler = start_scheduler(store, executor, max_running: 1)
    plan = compiled("missing-usage", [task("worker")])
    assert {:ok, "missing-usage", :submitted} = Scheduler.submit(plan, server: scheduler)

    assert_eventually(fn ->
      match?({:ok, %{status: :failed}}, Scheduler.status("missing-usage", server: scheduler))
    end)

    assert {:ok, [child]} = Memory.list_children("missing-usage", server: store)
    assert child.status == :failed
    assert child.error == {:manager_child_usage_missing, :success}
    assert child.usage.time_ms >= 0
  end

  test "manager status exposes cost, progress, disagreement, and cancellation state" do
    store = start_store()

    executor = fn child ->
      {:ok, result} = success(child)
      {:ok, Map.put(result, :verification, %{disagreement: true})}
    end

    scheduler = start_scheduler(store, executor, max_running: 1)
    plan = compiled("status-view", [task("worker")])
    assert {:ok, "status-view", :submitted} = Scheduler.submit(plan, server: scheduler)

    assert_eventually(fn ->
      match?({:ok, %{status: :completed}}, Scheduler.status("status-view", server: scheduler))
    end)

    assert {:ok, view} = Scheduler.status("status-view", server: scheduler)
    assert view.progress.by_status == %{completed: 1}
    assert view.budget.used.cost_micros == 1
    assert view.disagreements == 1
    assert view.cancellation == nil
  end

  test "one failed verification gets one charged repair and one retry, then stops for review" do
    store = start_store()

    executor = fn child ->
      case {child.task.role, child.attempt} do
        {:worker, 0} -> success(child, "worker")
        {:verifier, 0} -> {:error, {:verification_failed, :missing_evidence}, usage(1)}
        {:repair, 1} -> success(child, "repair")
        {:verifier, 1} -> {:error, {:verification_failed, :still_missing}, usage(1)}
      end
    end

    scheduler = start_scheduler(store, executor, max_running: 2)

    tasks = [
      task("worker", budget: budget(10)),
      task("verify", role: :verifier, write: false, depends_on: ["worker"], budget: budget(10))
    ]

    plan = compiled("repair-plan", tasks, max_children: 4, plan_budget: budget(40))
    assert {:ok, "repair-plan", :submitted} = Scheduler.submit(plan, server: scheduler)

    assert_eventually(
      fn ->
        match?(
          {:ok, %{status: :awaiting_review}},
          Scheduler.status("repair-plan", server: scheduler)
        )
      end,
      2_000
    )

    assert {:ok, view} = Scheduler.status("repair-plan", server: scheduler)
    assert view.repair_attempts == 1
    assert view.progress.total == 4
    assert view.budget.used.tokens == 4

    assert {:ok, children} = Memory.list_children("repair-plan", server: store)
    assert Enum.count(children, &(&1.task.role == :repair)) == 1
    assert Enum.count(children, &(&1.task.role == :verifier)) == 2

    assert Enum.any?(
             children,
             &(&1.task.role == :verifier and &1.attempt == 1 and &1.status == :awaiting_review)
           )
  end

  test "a verifier retry remains independent from both the original worker and repair" do
    store = start_store()

    executor = fn child ->
      case {child.task.role, child.attempt} do
        {:worker, 0} -> success(child, "worker-principal")
        {:verifier, 0} -> {:error, :verification_failed, usage(1)}
        {:repair, 1} -> success(child, "repair-principal")
        {:verifier, 1} -> success(child, "worker-principal")
      end
    end

    scheduler = start_scheduler(store, executor, max_running: 2)

    tasks = [
      task("worker", budget: budget(10)),
      task("verify", role: :verifier, write: false, depends_on: ["worker"], budget: budget(10))
    ]

    plan = compiled("retry-independence", tasks, max_children: 4, plan_budget: budget(40))
    assert {:ok, "retry-independence", :submitted} = Scheduler.submit(plan, server: scheduler)

    assert_eventually(
      fn ->
        match?(
          {:ok, %{status: :awaiting_review}},
          Scheduler.status("retry-independence", server: scheduler)
        )
      end,
      2_000
    )

    assert {:ok, children} = Memory.list_children("retry-independence", server: store)
    retry = Enum.find(children, &(&1.task.role == :verifier and &1.attempt == 1))
    assert retry.status == :awaiting_review
    assert retry.error == :manager_verifier_not_independent
    assert Enum.sort(retry.task.depends_on) == ["worker", "worker:repair:1"]
  end

  test "owner-only local store survives process restart with exact records and events" do
    root = temp_dir()
    path = Path.join(root, "manager.store")
    {:ok, first} = Memory.start_link(name: nil, persistence_path: path)
    compiled = compiled("durable-plan", [task("child")])
    record = Twelvgaige.Manager.PlanRecord.new(compiled)
    assert :ok = Memory.put_plan(record, server: first)

    assert :ok =
             Memory.append_event("durable-plan", %{id: "event-1", type: :saved}, server: first)

    GenServer.stop(first)

    {:ok, second} = Memory.start_link(name: nil, persistence_path: path)
    on_exit(fn -> safe_stop(second) end)
    assert {:ok, ^record} = Memory.get_plan("durable-plan", server: second)
    assert {:ok, [%{id: "event-1"}]} = Memory.list_events("durable-plan", server: second)
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
  end

  test "plan and initial children are committed as one idempotent submission" do
    store = start_store()
    compiled = compiled("atomic-plan", [task("one"), task("two")])
    record = Twelvgaige.Manager.PlanRecord.new(compiled)
    children = Enum.map(compiled.tasks, &Twelvgaige.Manager.ChildRecord.new(compiled, &1))

    assert :ok = Memory.put_submission(record, children, server: store)
    assert :already_present = Memory.put_submission(record, children, server: store)
    assert {:ok, ^record} = Memory.get_plan("atomic-plan", server: store)
    assert {:ok, stored_children} = Memory.list_children("atomic-plan", server: store)

    assert Enum.map(stored_children, & &1.id) |> MapSet.new() ==
             Enum.map(children, & &1.id) |> MapSet.new()

    conflicting = %{record | status: :running}
    extra = Twelvgaige.Manager.ChildRecord.new(compiled, %{hd(compiled.tasks) | id: "extra"})

    assert {:error, :manager_plan_conflict} =
             Memory.put_submission(conflicting, [extra], server: store)

    assert {:error, :not_found} = Memory.get_child(extra.id, server: store)
  end

  defp start_store do
    {:ok, store} = Memory.start_link(name: nil)
    on_exit(fn -> safe_stop(store) end)
    store
  end

  defp start_scheduler(store, executor, opts) do
    parent = self()

    factory = fn child, _factory_opts ->
      workspace_id = child.workspace_id || "ws-#{child.id}"
      session_id = child.delegated_session_id || "session-#{child.id}"
      {:ok, %{child | workspace_id: workspace_id, delegated_session_id: session_id}}
    end

    {:ok, scheduler} =
      Scheduler.start_link(
        [
          name: nil,
          store_server: store,
          executor: executor,
          child_factory: factory,
          reserve_fun: fn budget ->
            send(parent, {:reserved, budget})
            {:ok, make_ref()}
          end,
          release_fun: fn lease ->
            send(parent, {:released, lease})
            :ok
          end
        ] ++ opts
      )

    on_exit(fn -> safe_stop(scheduler) end)
    scheduler
  end

  defp compiled(id, tasks, opts \\ []) do
    max_children = Keyword.get(opts, :max_children, max(length(tasks), 1))
    max_fanout = Keyword.get(opts, :max_fanout, min(max_children, 2))
    plan_budget = Keyword.get(opts, :plan_budget, budget(max(length(tasks), 1) * 10))
    deadline = Keyword.get(opts, :deadline, DateTime.add(DateTime.utc_now(), 3_600))

    attrs = %{
      id: id,
      manager_principal: "manager",
      manager_session_id: "parent-session-#{id}",
      round_id: "round-#{id}",
      shot_id: "shot-#{id}",
      repository: "repo",
      base_ref: "main",
      auth_profile_id: "api",
      sandbox_profile: :coding_restricted,
      network_mode: :broker_only,
      capabilities: ["filesystem.write"],
      allowed_paths: ["lib", "test"],
      budget: plan_budget,
      deadline: deadline,
      max_depth: 1,
      max_children: max_children,
      max_fanout: max_fanout,
      tasks: tasks
    }

    {:ok, envelope} =
      Envelope.new(%{
        repositories: ["repo"],
        agents: ["codex"],
        workflows: ["coding.change.v1", "coding.verify.v1"],
        auth_profiles: ["api"],
        sandbox_profiles: [:coding_restricted],
        network_modes: [:broker_only],
        capabilities: ["filesystem.write"],
        mounts: [],
        allowed_paths: ["lib", "test"],
        budget: plan_budget,
        deadline: deadline,
        max_depth: 1,
        max_children: max_children,
        max_fanout: max_fanout
      })

    catalog = %{
      repositories: ["repo"],
      agents: ["codex"],
      workflows: ["coding.change.v1", "coding.verify.v1"],
      auth_profiles: ["api"],
      sandbox_profiles: [:coding_restricted],
      network_modes: [:broker_only],
      capabilities: ["filesystem.write"],
      mounts: []
    }

    {:ok, compiled} = Compiler.compile(attrs, parent_envelope: envelope, catalog: catalog)
    compiled
  end

  defp task(id, opts \\ []) do
    %{
      id: id,
      agent: "codex",
      workflow:
        if(Keyword.get(opts, :role) == :verifier,
          do: "coding.verify.v1",
          else: "coding.change.v1"
        ),
      objective: "Do #{id}",
      role: Keyword.get(opts, :role, :worker),
      write: Keyword.get(opts, :write, true),
      allowed_paths: ["lib"],
      capabilities: if(Keyword.get(opts, :write, true), do: ["filesystem.write"], else: []),
      mounts: [],
      depends_on: Keyword.get(opts, :depends_on, []),
      budget: Keyword.get(opts, :budget, budget(10))
    }
  end

  defp budget(tokens),
    do: %{tokens: tokens, cost_micros: tokens, time_ms: tokens * 1_000, tool_calls: tokens}

  defp usage(amount),
    do: %{tokens: amount, cost_micros: amount, time_ms: amount, tool_calls: amount}

  defp success(child, principal \\ "codex") do
    {:ok,
     %{
       handoff:
         Handoff.new(%{
           objective_status: :complete,
           summary: "completed #{child.task_id}",
           workspace_id: child.workspace_id,
           base_commit: "base",
           diff_artifact: "artifact:#{child.id}",
           claims: [%{claim: "work captured", evidence: "artifact:#{child.id}"}]
         }),
       usage: usage(1),
       principal: principal
     }}
  end

  defp receive_message(tag) do
    receive do
      {^tag, id} -> id
    after
      1_000 -> flunk("timed out waiting for #{tag}")
    end
  end

  defp assert_eventually(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("condition did not become true")
      else
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
      end
    end
  end

  defp temp_dir do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-manager-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
