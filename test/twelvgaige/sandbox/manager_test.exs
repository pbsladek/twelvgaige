defmodule Twelvgaige.Sandbox.ManagerTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Credential.Broker
  alias Twelvgaige.Sandbox.{Admission, Manager}

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
