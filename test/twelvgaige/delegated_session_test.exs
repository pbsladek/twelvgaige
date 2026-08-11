defmodule Twelvgaige.DelegatedSessionTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession
  alias Twelvgaige.DelegatedSession.Controller
  alias Twelvgaige.DelegatedSession.Event

  defmodule AttachedBackend do
    @behaviour Twelvgaige.Sandbox.Backend

    def probe(_opts), do: {:ok, %{available: true}}
    def prepare(spec, _opts), do: {:ok, Map.put(spec, :backend, :attached_test)}

    def create(manifest, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:sandbox_created, Keyword.fetch!(opts, :command)})
      {:ok, "sandbox_attached_controller", %{manifest: manifest}}
    end

    def start(_resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), :detached_start_called)
      {:error, :detached_start_called}
    end

    def stdio_transport(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:stdio_transport, resource_id})

      {:ok,
       %{
         binary: "/qualified/podman",
         arguments: ["start", "--attach", "--interactive", resource_id],
         environment: [{"PATH", "/qualified/bin"}]
       }}
    end

    def inspect(resource_id, _opts), do: {:ok, %{resource_id: resource_id, status: :created}}

    def stop(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:sandbox_stopped, resource_id})
      :ok
    end

    def destroy(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:sandbox_destroyed, resource_id})
      :ok
    end

    def export_workspace(resource_id, destination, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:workspace_exported, resource_id, destination})
      {:ok, %{destination: destination, bytes: 0, entries: 0}}
    end

    def reconcile(durable, _opts), do: {:ok, :resume, durable}
  end

  defmodule AttachedAdapter do
    @behaviour Twelvgaige.DelegatedSession.Adapter

    def capabilities(_config), do: {:ok, %{}}

    def prepare(%{adapter_config: config} = spec) do
      send(config.test_pid, {:adapter_prepared, config, spec.sandbox_resource_id})
      {:ok, config}
    end

    def authenticate(config, lease) do
      send(config.test_pid, {:adapter_authenticated, lease})
      {:ok, config}
    end

    def start(config, _spec) do
      send(config.test_pid, :adapter_started)
      {:ok, config, %{external_session_id: "thread_attached", external_turn_id: "turn_attached"}}
    end

    def resume(external_id, prepared, _spec),
      do: {:ok, prepared, %{external_session_id: external_id}}

    def send_input(_handle, _input), do: :ok
    def decide(_handle, _approval_id, _decision), do: :ok
    def cancel(_handle, _reason), do: :ok
    def snapshot(_handle), do: {:ok, %{}}
    def reconcile(_durable, observed), do: {:ok, :resume, observed}
    def finalize(_handle), do: {:ok, %{events: []}}
  end

  defmodule FailingFinalizeAdapter do
    @behaviour Twelvgaige.DelegatedSession.Adapter

    def capabilities(_config), do: {:ok, %{}}
    def prepare(spec), do: {:ok, spec}
    def authenticate(prepared, _lease), do: {:ok, prepared}

    def start(prepared, _spec),
      do: {:ok, prepared, %{external_session_id: "mock-failing-finalize"}}

    def resume(external_id, prepared, _spec),
      do: {:ok, prepared, %{external_session_id: external_id}}

    def send_input(_handle, _input), do: :ok
    def decide(_handle, _approval_id, _decision), do: :ok
    def cancel(_handle, _reason), do: :ok
    def snapshot(_handle), do: {:ok, %{}}
    def reconcile(_durable, observed), do: {:ok, :resume, observed}
    def finalize(_handle), do: {:error, :provider_finalize_failed}
  end

  test "exact resume rejects workspace, auth, sandbox, and policy drift" do
    durable = session()

    assert :ok = DelegatedSession.resume_compatible?(durable, durable)

    candidate = %{
      durable
      | workspace_id: "ws_other",
        auth_revision: "auth-2",
        sandbox_manifest_digest: String.duplicate("c", 64),
        policy_revision: "policy-2"
    }

    assert {:error,
            {:identity_drift,
             [:workspace_id, :auth_revision, :sandbox_manifest_digest, :policy_revision]}} =
             DelegatedSession.resume_compatible?(durable, candidate)
  end

  test "controller deduplicates events and reserves cancellation under a delta flood" do
    {:ok, controller} =
      Controller.start_link(
        session: session(),
        event_capacity: 8,
        critical_event_reserve: 2
      )

    on_exit(fn -> if Process.alive?(controller), do: GenServer.stop(controller) end)
    assert {:ok, started} = Controller.start(controller)
    assert started.status == :running

    for index <- 1..1_000 do
      event =
        Event.new(
          session_id: started.id,
          event_type: :message_delta,
          native_session_id: started.external_session_id,
          native_event_id: "delta-#{index}",
          payload: %{index: index},
          occurred_at: DateTime.utc_now()
        )

      assert :ok = Controller.ingest(controller, event)
    end

    assert {:ok, cancelled} = Controller.cancel(controller, :user_requested)
    assert cancelled.status == :cancelled
    assert {:ok, finalized} = Controller.finalize(controller)
    assert finalized.status == :finalized
    assert finalized.result.runtime_quiescence.runtime_stopped
    assert finalized.result.runtime_quiescence.runtime_identity
    assert %DateTime{} = finalized.result.runtime_quiescence.stopped_at
  end

  test "controller destroys the runtime even when provider finalization fails" do
    {:ok, controller} =
      Controller.start_link(
        session: session(),
        adapter: FailingFinalizeAdapter
      )

    on_exit(fn -> if Process.alive?(controller), do: GenServer.stop(controller) end)
    assert {:ok, %{status: :running}} = Controller.start(controller)

    assert {:error, :provider_finalize_failed,
            %{
              runtime_quiescence: %{
                runtime_stopped: true,
                runtime_identity: runtime_identity,
                stopped_at: %DateTime{}
              },
              session: %{status: :failed}
            }} = Controller.finalize(controller)

    assert is_binary(runtime_identity)
    assert {:ok, %{session: %{status: :failed}}} = Controller.snapshot(controller)
  end

  test "controller starts the adapter through the sandbox manager's attached transport" do
    admission =
      start_supervised!(
        {Twelvgaige.Sandbox.Admission,
         name: nil,
         limits: [
           sandboxes: 1,
           cpu: 1,
           memory_bytes: 1_024,
           pids: 10,
           workspace_bytes: 1_024,
           artifact_bytes: 1_024,
           provider_tokens: 100
         ]}
      )

    sandbox_manager =
      start_supervised!(
        {Twelvgaige.Sandbox.Manager, name: nil, admission: admission, backend: AttachedBackend}
      )

    runtime_command = ["/opt/codex/bin/codex", "app-server", "--stdio", "--strict-config"]

    result_destination =
      Path.join(System.tmp_dir!(), "controller-result-#{System.unique_integer([:positive])}")

    File.mkdir_p!(result_destination)
    on_exit(fn -> File.rm_rf!(result_destination) end)

    {:ok, controller} =
      Controller.start_link(
        session: session(),
        adapter: AttachedAdapter,
        adapter_config: %{test_pid: self(), client_opts: [binary: "/host/codex"]},
        sandbox_manager: sandbox_manager,
        sandbox_launch_spec: %{reservation: %{sandboxes: 1}},
        sandbox_opts: [test_pid: self()],
        runtime_command: runtime_command,
        result_destination: result_destination
      )

    on_exit(fn -> if Process.alive?(controller), do: GenServer.stop(controller) end)

    assert {:ok,
            %{
              status: :running,
              sandbox_resource_id: "sandbox_attached_controller",
              external_session_id: "thread_attached"
            }} = Controller.start(controller)

    assert_receive {:sandbox_created, ^runtime_command}
    assert_receive {:stdio_transport, "sandbox_attached_controller"}

    assert_receive {:adapter_prepared, config, "sandbox_attached_controller"}
    assert config.sandbox_authority == :outer
    assert config.client_opts[:binary] == "/qualified/podman"

    assert config.client_opts[:arguments] == [
             "start",
             "--attach",
             "--interactive",
             "sandbox_attached_controller"
           ]

    assert config.client_opts[:environment] == [{"PATH", "/qualified/bin"}]
    refute_received :detached_start_called

    assert {:ok, %{status: :finalized, result: %{runtime_quiescence: evidence}}} =
             Controller.finalize(controller)

    assert evidence.runtime_stopped
    assert evidence.runtime_identity == "sandbox_attached_controller"
    assert_receive {:sandbox_stopped, "sandbox_attached_controller"}
    assert_receive {:sandbox_destroyed, "sandbox_attached_controller"}
    assert_receive {:workspace_exported, "sandbox_attached_controller", ^result_destination}
  end

  defp session do
    now = ~U[2026-08-02 12:00:00Z]

    DelegatedSession.new(%{
      id: "sess_1",
      round_id: "round_1",
      shot_id: "delegate",
      attempt: 1,
      runtime: :mock,
      driver: :mock,
      runtime_version: "1",
      integration_descriptor_id: "mock-1",
      workspace_id: "ws_1",
      base_commit: String.duplicate("a", 40),
      auth_profile_id: "auth",
      auth_revision: "auth-1",
      sandbox_profile: :coding_restricted,
      sandbox_manifest_digest: String.duplicate("b", 64),
      policy_revision: "policy-1",
      budgets: %{tokens: 100},
      deadline: DateTime.add(now, 3_600),
      created_at: now
    })
  end
end
