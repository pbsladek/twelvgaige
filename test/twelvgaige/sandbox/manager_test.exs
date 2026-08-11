defmodule Twelvgaige.Sandbox.ManagerTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Credential.Broker
  alias Twelvgaige.Lifecycle.FaultEvidence
  alias Twelvgaige.Operations.Store, as: OperationsStore
  alias Twelvgaige.Sandbox.{Admission, Manager}

  defmodule RecoveryBackend do
    @behaviour Twelvgaige.Sandbox.Backend

    def probe(_opts), do: {:ok, %{available: true}}
    def prepare(spec, _opts), do: {:ok, Map.put(spec, :backend, :recovery_test)}

    def create(manifest, _opts) do
      resource_id = Map.fetch!(manifest, :resource_id)
      {:ok, resource_id, %{manifest: manifest}}
    end

    def start(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:recovery_started, resource_id})
      {:ok, %{status: :running}}
    end

    def inspect(resource_id, _opts), do: {:ok, %{resource_id: resource_id, status: :running}}
    def stop(_resource_id, _opts), do: :ok

    def destroy(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:recovery_destroyed, resource_id})
      :ok
    end

    def reconcile(durable, _opts), do: {:ok, :resume, durable}
  end

  defmodule StartFailureBackend do
    @behaviour Twelvgaige.Sandbox.Backend

    def probe(_opts), do: {:ok, %{available: true}}
    def prepare(spec, _opts), do: {:ok, spec}
    def create(manifest, _opts), do: {:ok, "sandbox_start_failure", %{manifest: manifest}}
    def start(_resource_id, _opts), do: {:error, :start_failed}
    def inspect(_resource_id, _opts), do: {:error, :not_running}
    def stop(_resource_id, _opts), do: :ok

    def destroy(resource_id, opts) do
      if pid = Keyword.get(opts, :test_pid), do: send(pid, {:destroyed, resource_id})
      :ok
    end

    def reconcile(durable, _opts), do: {:ok, :resume, durable}
  end

  defmodule CompletionBackend do
    @behaviour Twelvgaige.Sandbox.Backend

    def probe(_opts), do: {:ok, %{available: true}}
    def prepare(spec, _opts), do: {:ok, spec}
    def create(manifest, _opts), do: {:ok, "sandbox_complete", %{manifest: manifest}}
    def start(_resource_id, _opts), do: {:ok, %{status: :running}}
    def inspect(_resource_id, _opts), do: {:ok, %{status: :running}}

    def stop(resource_id, opts) do
      Process.put({__MODULE__, resource_id}, :stopped)
      send(Keyword.fetch!(opts, :test_pid), {:completion_step, :stopped})
      :ok
    end

    def export(resource_id, destination, paths, opts) do
      if Process.get({__MODULE__, resource_id}) != :stopped,
        do: raise("export ran before worker stop")

      send(Keyword.fetch!(opts, :test_pid), {:completion_step, :exported})

      {:ok, %{transport: :copy_snapshot, destination: destination, exported: paths, bytes: 0}}
    end

    def destroy(_resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:completion_step, :destroyed})
      :ok
    end

    def reconcile(durable, _opts), do: {:ok, :resume, durable}
  end

  defmodule AttachedBackend do
    @behaviour Twelvgaige.Sandbox.Backend

    def probe(_opts), do: {:ok, %{available: true}}
    def prepare(spec, _opts), do: {:ok, Map.put(spec, :backend, :attached_test)}
    def create(manifest, _opts), do: {:ok, "sandbox_attached", %{manifest: manifest}}

    def start(_resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), :unexpected_detached_start)
      {:error, :unexpected_detached_start}
    end

    def stdio_transport(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:attached_transport, resource_id})

      {:ok,
       %{
         binary: "/qualified/runtime",
         arguments: ["start", "--attach", "--interactive", resource_id],
         environment: [{"PATH", "/qualified/bin"}]
       }}
    end

    def inspect(resource_id, _opts), do: {:ok, %{resource_id: resource_id, status: :created}}

    def stop(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:attached_stop, resource_id})
      :ok
    end

    def destroy(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:attached_destroy, resource_id})
      :ok
    end

    def reconcile(durable, _opts), do: {:ok, :resume, durable}
  end

  defmodule RetryCompletionBackend do
    @behaviour Twelvgaige.Sandbox.Backend

    def probe(_opts), do: {:ok, %{available: true}}
    def prepare(spec, _opts), do: {:ok, Map.put(spec, :backend, :retry_completion_test)}

    def create(manifest, _opts) do
      resource_id = Map.get(manifest, :resource_id, "sandbox_retry_complete")
      {:ok, resource_id, %{manifest: manifest}}
    end

    def start(_resource_id, _opts), do: {:ok, %{status: :running}}
    def stdio_transport(_resource_id, _opts), do: {:error, :not_used}
    def inspect(resource_id, _opts), do: {:ok, %{resource_id: resource_id, status: :created}}

    def stop(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:retry_completion_stop, resource_id})
      :ok
    end

    def export_workspace(resource_id, destination, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:retry_completion_export, resource_id, destination})

      case take_fault(opts, :export) do
        true -> {:error, :injected_export_failure}
        false -> {:ok, %{destination: destination, bytes: 1, entries: 1}}
      end
    end

    def destroy(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:retry_completion_destroy, resource_id})

      case take_fault(opts, :destroy) do
        true -> {:error, :injected_destroy_failure}
        false -> :ok
      end
    end

    def reconcile(durable, _opts), do: {:ok, :resume, durable}

    defp take_fault(opts, key) do
      Agent.get_and_update(Keyword.fetch!(opts, :faults), fn faults ->
        count = Map.get(faults, key, 0)
        {count > 0, Map.put(faults, key, max(count - 1, 0))}
      end)
    end
  end

  defmodule DurableCompletionBackend do
    @behaviour Twelvgaige.Sandbox.Backend

    def probe(_opts), do: {:ok, %{available: true}}
    def prepare(spec, _opts), do: {:ok, Map.put(spec, :backend, :durable_completion_test)}

    def create(manifest, _opts) do
      resource_id = Map.fetch!(manifest, :resource_id)
      {:ok, resource_id, %{manifest: manifest}}
    end

    def start(resource_id, opts) do
      step(opts, {:started, resource_id})
      {:ok, %{resource_id: resource_id, status: :running}}
    end

    def inspect(resource_id, _opts), do: {:ok, %{resource_id: resource_id, status: :running}}

    def stop(resource_id, opts) do
      step(opts, {:stopped, resource_id})
      :ok
    end

    def export_workspace(resource_id, destination, opts) do
      step(opts, {:exported, resource_id, destination})
      {:ok, %{transport: :copy_snapshot, destination: destination, bytes: 7, entries: 1}}
    end

    def destroy(resource_id, opts) do
      step(opts, {:destroyed, resource_id})
      :ok
    end

    def reconcile(durable, _opts), do: {:ok, :resume, durable}

    defp step(opts, event) do
      case Keyword.get(opts, :trace) do
        trace when is_pid(trace) -> Agent.update(trace, &(&1 ++ [event]))
        _missing -> :ok
      end
    end
  end

  defmodule FakeBoundary do
    def provision(backend, lease, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:boundary_step, :provisioned, backend, lease.id})
      {:ok, %{id: "boundary", access_token: lease.access_token}}
    end

    def worker_options(boundary) do
      [
        broker_network: "internal-network",
        proxy_environment: %{
          "HTTP_PROXY" => "http://twelvgaige:#{boundary.access_token}@10.0.0.2:8080",
          "HTTPS_PROXY" => "http://twelvgaige:#{boundary.access_token}@10.0.0.2:8080",
          "NO_PROXY" => "127.0.0.1,localhost"
        }
      ]
    end

    def revoke(_boundary, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:boundary_step, :revoked})
      :ok
    end

    def destroy(_boundary, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:boundary_step, :destroyed})
      :ok
    end
  end

  setup do
    limits = [
      sandboxes: 1,
      cpu: 1,
      memory_bytes: 1_024,
      pids: 10,
      workspace_bytes: 1_024,
      artifact_bytes: 1_024,
      provider_tokens: 100
    ]

    start_supervised!({Admission, limits: limits})
    admission = Process.whereis(Admission)
    start_supervised!(Broker)
    broker = Process.whereis(Broker)

    %{admission: admission, broker: broker}
  end

  test "cancellation releases admission and revokes the credential lease", context do
    manager =
      start_supervised!(
        {Manager,
         admission: context.admission,
         credential_broker: context.broker,
         backend: Twelvgaige.Sandbox.Backend.Mock}
      )

    lease = issue_credential(context.broker)

    assert {:ok, resource_id, _record} =
             Manager.launch(spec(lease.id), server: manager)

    assert :ok = Manager.cancel(resource_id, server: manager)
    assert %{used: %{sandboxes: 0}} = Admission.snapshot(server: context.admission)

    assert {:error, :credential_lease_revoked} =
             Broker.authorize(
               lease.access_token,
               %{session_id: "session", model: "model", destination: "provider", amount: 1},
               server: context.broker
             )
  end

  test "a start failure destroys the resource and rolls back all leases", context do
    manager =
      start_supervised!(
        {Manager,
         admission: context.admission,
         credential_broker: context.broker,
         backend: StartFailureBackend}
      )

    lease = issue_credential(context.broker)

    assert {:error, :start_failed} =
             Manager.launch(spec(lease.id), server: manager, test_pid: self())

    assert_receive {:destroyed, "sandbox_start_failure"}
    assert %{used: %{sandboxes: 0}} = Admission.snapshot(server: context.admission)

    assert {:error, :credential_lease_revoked} =
             Broker.authorize(
               lease.access_token,
               %{session_id: "session", model: "model", destination: "provider", amount: 1},
               server: context.broker
             )
  end

  test "attached launch returns one governed stdio transport without detached start", context do
    manager =
      start_supervised!(
        {Manager,
         admission: context.admission, credential_broker: context.broker, backend: AttachedBackend}
      )

    lease = issue_credential(context.broker)

    assert {:ok, "sandbox_attached", record,
            %{
              binary: "/qualified/runtime",
              arguments: ["start", "--attach", "--interactive", "sandbox_attached"]
            }} =
             Manager.launch_attached(spec(lease.id),
               server: manager,
               test_pid: self(),
               command: ["/opt/codex/bin/codex", "app-server", "--stdio"]
             )

    assert record.process.status == :attach_pending
    assert_receive {:attached_transport, "sandbox_attached"}
    refute_received :unexpected_detached_start

    assert :ok = Manager.cancel("sandbox_attached", server: manager, test_pid: self())
    assert_receive {:attached_stop, "sandbox_attached"}
    assert_receive {:attached_destroy, "sandbox_attached"}
    assert %{used: %{sandboxes: 0}} = Admission.snapshot(server: context.admission)

    assert {:error, :credential_lease_revoked} =
             Broker.authorize(
               lease.access_token,
               %{session_id: "session", model: "model", destination: "provider", amount: 1},
               server: context.broker
             )
  end

  test "completion revokes authority, stops the worker, exports, then destroys", context do
    manager =
      start_supervised!(
        {Manager,
         admission: context.admission,
         credential_broker: context.broker,
         backend: CompletionBackend}
      )

    lease = issue_credential(context.broker)

    launch_spec =
      spec(lease.id)
      |> Map.put(:workspace_transport, :copy_snapshot)
      |> put_in([:reservation, :workspace_bytes], 512)

    assert {:ok, resource_id, _record} =
             Manager.launch(launch_spec, server: manager, test_pid: self())

    destination = Path.join(System.tmp_dir!(), "manager-complete-output")

    assert {:ok, %{transport: :copy_snapshot}} =
             Manager.complete(resource_id, destination, ["result.txt"],
               server: manager,
               test_pid: self()
             )

    assert_receive {:completion_step, :stopped}
    assert_receive {:completion_step, :exported}
    assert_receive {:completion_step, :destroyed}

    assert {:error, :credential_lease_revoked} =
             Broker.authorize(
               lease.access_token,
               %{session_id: "session", model: "model", destination: "provider", amount: 1},
               server: context.broker
             )

    assert %{used: %{sandboxes: 0}} = Admission.snapshot(server: context.admission)
  end

  test "workspace completion is retryable after export and cleanup failures", context do
    for fault <- [:export, :destroy] do
      faults = start_supervised!({Agent, fn -> %{fault => 1} end}, id: {fault, self()})

      manager =
        start_supervised!(
          {Manager,
           name: nil,
           admission: context.admission,
           credential_broker: context.broker,
           backend: RetryCompletionBackend},
          id: {:retry_completion_manager, fault}
        )

      lease = issue_credential(context.broker)

      launch_spec =
        spec(lease.id)
        |> Map.merge(%{workspace_transport: :copy_snapshot, reservation: %{sandboxes: 1}})

      assert {:ok, resource_id, _record} =
               Manager.launch(launch_spec, server: manager, test_pid: self(), faults: faults)

      destination = Path.join(System.tmp_dir!(), "manager-retry-complete-#{fault}")

      assert {:error, {:sandbox_workspace_completion_failed, injected}} =
               Manager.complete_workspace(resource_id, destination,
                 server: manager,
                 test_pid: self(),
                 faults: faults
               )

      assert injected in [:injected_export_failure, :injected_destroy_failure]
      assert {:ok, _record} = Manager.get(resource_id, server: manager)
      assert %{used: %{sandboxes: 1}} = Admission.snapshot(server: context.admission)

      assert {:ok, %{runtime_quiescence: %{runtime_stopped: true}}} =
               Manager.complete_workspace(resource_id, destination,
                 server: manager,
                 test_pid: self(),
                 faults: faults
               )

      assert :error = Manager.get(resource_id, server: manager)
      assert %{used: %{sandboxes: 0}} = Admission.snapshot(server: context.admission)
    end
  end

  test "restart cleanup destroys an exact journaled resource and revokes its lease", context do
    root =
      Path.join(
        System.tmp_dir!(),
        "sandbox-manager-recovery-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    store =
      start_supervised!({OperationsStore, name: nil, path: Path.join(root, "operations.sqlite3")})

    checkpoints = start_supervised!({Agent, fn -> [] end})

    fault_checkpoint_fun = fn event ->
      Agent.update(checkpoints, &[event.id | &1])
      :ok
    end

    opts = [
      name: nil,
      admission: context.admission,
      credential_broker: context.broker,
      backend: RecoveryBackend,
      operations_store: store,
      recovery_opts: [test_pid: self()],
      fault_checkpoint_fun: fault_checkpoint_fun
    ]

    {:ok, manager} = Manager.start_link(opts)
    lease = issue_credential(context.broker)

    launch_spec =
      spec(lease.id)
      |> Map.put(:resource_id, "sandbox_restart_recovery")

    assert {:ok, "sandbox_restart_recovery", _record} =
             Manager.launch(launch_spec, server: manager, test_pid: self())

    assert_receive {:recovery_started, "sandbox_restart_recovery"}

    assert {:ok, %{value: durable}} =
             OperationsStore.get(:sandbox_resource, "sandbox_restart_recovery", server: store)

    assert durable.resource_id == "sandbox_restart_recovery"
    refute inspect(durable) =~ "must-not-escape"

    GenServer.stop(manager)
    {:ok, restarted} = Manager.start_link(opts)
    assert_receive {:recovery_destroyed, "sandbox_restart_recovery"}

    assert {:error, :not_found} =
             OperationsStore.get(:sandbox_resource, "sandbox_restart_recovery", server: store)

    assert %{used: %{sandboxes: 0}} = Admission.snapshot(server: context.admission)

    assert {:error, :credential_lease_revoked} =
             Broker.authorize(
               lease.access_token,
               %{session_id: "session", model: "model", destination: "provider", amount: 1},
               server: context.broker
             )

    checkpoint_ids = checkpoints |> Agent.get(& &1) |> MapSet.new()

    for boundary <- [
          :resource_intent_persist,
          :credential_revoke,
          :egress_revoke,
          :boundary_revoke,
          :worker_destroy,
          :boundary_destroy,
          :admission_release,
          :resource_record_delete
        ],
        position <- [:before, :after] do
      assert "sandbox_resource_cleanup.#{boundary}.#{position}" in checkpoint_ids
    end

    GenServer.stop(restarted)
  end

  test "restart cleanup is idempotent before and after every recovery boundary", context do
    root =
      Path.join(
        System.tmp_dir!(),
        "sandbox-manager-fault-matrix-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    store =
      start_supervised!({OperationsStore, name: nil, path: Path.join(root, "operations.sqlite3")})

    boundaries = [
      :credential_revoke,
      :egress_revoke,
      :boundary_revoke,
      :worker_destroy,
      :boundary_destroy,
      :admission_release,
      :resource_record_delete
    ]

    for boundary <- boundaries, position <- [:before, :after] do
      target = "sandbox_resource_cleanup.#{boundary}.#{position}"

      resource_id =
        "sandbox_fault_#{boundary}_#{position}_#{System.unique_integer([:positive])}"

      lease = issue_credential(context.broker)

      base_opts = [
        name: nil,
        admission: context.admission,
        credential_broker: context.broker,
        backend: RecoveryBackend,
        operations_store: store,
        recovery_opts: [test_pid: self()]
      ]

      {:ok, creator} = Manager.start_link(base_opts)

      assert {:ok, ^resource_id, _record} =
               Manager.launch(
                 spec(lease.id) |> Map.put(:resource_id, resource_id),
                 server: creator,
                 test_pid: self()
               )

      assert_receive {:recovery_started, ^resource_id}
      GenServer.stop(creator)

      crash_opts =
        Keyword.put(base_opts, :fault_checkpoint_fun, fn event ->
          if event.id == target, do: exit({:simulated_sandbox_crash, target}), else: :ok
        end)

      previous_trap_exit = Process.flag(:trap_exit, true)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:simulated_sandbox_crash, ^target}} = Manager.start_link(crash_opts)
      end)

      Process.flag(:trap_exit, previous_trap_exit)

      {:ok, recovered} = Manager.start_link(base_opts)

      assert {:error, :not_found} =
               OperationsStore.get(:sandbox_resource, resource_id, server: store)

      assert %{used: %{sandboxes: 0}} = Admission.snapshot(server: context.admission)

      assert {:error, :credential_lease_revoked} =
               Broker.authorize(
                 lease.access_token,
                 %{session_id: "session", model: "model", destination: "provider", amount: 1},
                 server: context.broker
               )

      GenServer.stop(recovered)
    end
  end

  @tag :fault_matrix
  test "workspace completion survives termination at every export and cleanup boundary",
       context do
    boundaries = [
      :completion_intent_persist,
      :credential_revoke,
      :egress_revoke,
      :boundary_revoke,
      :worker_stop,
      :quiescence_persist,
      :workspace_export,
      :workspace_export_persist,
      :boundary_destroy,
      :worker_destroy,
      :admission_release,
      :resource_record_delete
    ]

    for boundary <- boundaries, position <- [:before, :after] do
      target = "sandbox_resource_cleanup.#{boundary}.#{position}"

      root =
        Path.join(
          System.tmp_dir!(),
          "sandbox-completion-fault-#{boundary}-#{position}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)
      {:ok, trace} = Agent.start_link(fn -> [] end)
      Process.unlink(trace)

      resource_id = "sandbox_completion_#{boundary}_#{position}"
      destination = Path.join(root, "workspace")
      File.mkdir_p!(destination)
      lease = issue_credential(context.broker)

      base_opts = [
        name: nil,
        admission: context.admission,
        credential_broker: context.broker,
        backend: DurableCompletionBackend,
        operations_store: store,
        recovery_opts: [trace: trace, allowed_export_roots: [root]],
        fault_checkpoint_fun: fn event ->
          if event.id == target,
            do: exit({:simulated_sandbox_completion_crash, target}),
            else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(base_opts)
      Process.unlink(manager)

      launch_spec =
        spec(lease.id)
        |> Map.merge(%{
          resource_id: resource_id,
          result_destination: destination,
          workspace_transport: :copy_snapshot
        })

      assert {:ok, ^resource_id, record} =
               Manager.launch(launch_spec,
                 server: manager,
                 trace: trace,
                 allowed_export_roots: [root]
               )

      refute Map.has_key?(record.manifest, :result_destination)

      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.complete_workspace(resource_id, destination,
                   server: manager,
                   trace: trace,
                   allowed_export_roots: [root]
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager,
                      {:simulated_sandbox_completion_crash, ^target}}

      restart_opts = Keyword.delete(base_opts, :fault_checkpoint_fun)
      {:ok, restarted} = Manager.start_link(restart_opts)
      Process.unlink(restarted)

      assert {:error, :not_found} =
               OperationsStore.get(:sandbox_resource, resource_id, server: store)

      assert %{used: %{sandboxes: 0}} = Admission.snapshot(server: context.admission)

      assert {:error, :credential_lease_revoked} =
               Broker.authorize(
                 lease.access_token,
                 %{session_id: "session", model: "model", destination: "provider", amount: 1},
                 server: context.broker
               )

      trace_events = Agent.get(trace, & &1)
      exports = Enum.filter(trace_events, &match?({:exported, ^resource_id, ^destination}, &1))
      destroys = Enum.filter(trace_events, &match?({:destroyed, ^resource_id}, &1))
      assert exports != []
      assert destroys != []

      export_index =
        Enum.find_index(trace_events, &match?({:exported, ^resource_id, ^destination}, &1))

      destroy_index = Enum.find_index(trace_events, &match?({:destroyed, ^resource_id}, &1))
      assert export_index < destroy_index

      FaultEvidence.record_case(target, :safe_resume, %{suite: "sandbox_manager"})

      GenServer.stop(restarted)
      GenServer.stop(store)
      Agent.stop(trace)
    end
  end

  @tag :fault_matrix
  test "launch intent and admission survive termination before sandbox creation", context do
    for boundary <- [:resource_intent_persist, :admission_reserve, :creation_intent_persist],
        position <- [:before, :after] do
      target = "sandbox_resource_cleanup.#{boundary}.#{position}"

      root =
        Path.join(
          System.tmp_dir!(),
          "sandbox-launch-fault-#{boundary}-#{position}-#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)
      {:ok, trace} = Agent.start_link(fn -> [] end)
      Process.unlink(trace)

      resource_id = "sandbox_launch_#{boundary}_#{position}"
      lease = issue_credential(context.broker)

      base_opts = [
        name: nil,
        admission: context.admission,
        credential_broker: context.broker,
        backend: DurableCompletionBackend,
        operations_store: store,
        recovery_opts: [trace: trace],
        fault_checkpoint_fun: fn event ->
          if event.id == target,
            do: exit({:simulated_sandbox_launch_crash, target}),
            else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(base_opts)
      Process.unlink(manager)
      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.launch(
                   spec(lease.id)
                   |> Map.merge(%{
                     resource_id: resource_id,
                     workspace_transport: :copy_snapshot
                   }),
                   server: manager,
                   trace: trace
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager,
                      {:simulated_sandbox_launch_crash, ^target}}

      {:ok, restarted} =
        Manager.start_link(Keyword.delete(base_opts, :fault_checkpoint_fun))

      Process.unlink(restarted)

      assert {:error, :not_found} =
               OperationsStore.get(:sandbox_resource, resource_id, server: store)

      assert %{used: %{sandboxes: 0}} = Admission.snapshot(server: context.admission)
      refute Enum.any?(Agent.get(trace, & &1), &match?({:started, ^resource_id}, &1))

      if {boundary, position} == {:resource_intent_persist, :before} do
        assert :ok = Broker.revoke(lease.id, server: context.broker)
      else
        assert {:error, :credential_lease_revoked} =
                 Broker.authorize(
                   lease.access_token,
                   %{session_id: "session", model: "model", destination: "provider", amount: 1},
                   server: context.broker
                 )
      end

      FaultEvidence.record_case(target, :validated_compensation, %{
        suite: "sandbox_manager"
      })

      GenServer.stop(restarted)
      GenServer.stop(store)
      Agent.stop(trace)
    end
  end

  test "broker-only launch materializes a lease and revokes the sidecar before cleanup",
       context do
    egress = start_supervised!({Twelvgaige.Egress.Broker, name: nil})
    now = DateTime.utc_now()

    {:ok, lease} =
      Twelvgaige.Egress.Broker.issue(
        %{
          session_id: "session-egress",
          allowed_hosts: ["api.example.com"],
          allowed_ports: [443],
          expires_at: DateTime.add(now, 300)
        },
        server: egress,
        now: now
      )

    manager =
      start_supervised!(
        {Manager,
         admission: context.admission,
         credential_broker: context.broker,
         egress_broker: egress,
         egress_boundary: FakeBoundary,
         egress_boundary_backend: :podman,
         backend: CompletionBackend}
      )

    launch_spec =
      spec(nil)
      |> Map.merge(%{
        network_mode: :broker_only,
        proxy_lease_id: lease.id,
        egress_access_token: lease.access_token,
        workspace_transport: :bind_worktree
      })

    assert {:ok, resource_id, record} =
             Manager.launch(launch_spec,
               server: manager,
               test_pid: self(),
               egress_image_reference: "localhost/twelvgaige/egress-proxy",
               egress_image_digest: "sha256:" <> String.duplicate("a", 64),
               egress_runtime_root: System.tmp_dir!()
             )

    assert record.manifest.environment_names == ~w(HTTP_PROXY HTTPS_PROXY NO_PROXY)
    assert_receive {:boundary_step, :provisioned, :podman, lease_id}
    assert lease_id == lease.id

    assert :ok = Manager.cancel(resource_id, server: manager, test_pid: self())
    assert_receive {:boundary_step, :revoked}
    assert_receive {:boundary_step, :destroyed}

    assert {:error, :invalid_egress_lease} =
             Twelvgaige.Egress.Broker.materialize(lease.id, lease.access_token,
               server: egress,
               now: now
             )
  end

  defp issue_credential(broker) do
    {:ok, lease} =
      Broker.issue(
        %{
          session_id: "session",
          round_id: "round",
          shot_id: "shot",
          attempt: 1,
          runtime: :codex,
          principal: "operator",
          provider_account: "account",
          models: ["model"],
          destinations: ["provider"],
          budget: 100,
          expires_at: DateTime.add(Twelvgaige.Clock.utc_now(), 60, :second),
          upstream_secret: "must-not-escape"
        },
        server: broker
      )

    lease
  end

  defp spec(credential_lease_id) do
    %{
      credential_lease_id: credential_lease_id,
      reservation: %{sandboxes: 1}
    }
  end
end
