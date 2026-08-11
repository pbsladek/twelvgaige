defmodule Twelvgaige.Breech.IPCTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.IPC.Client
  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.Breech.IPC.Protocol
  alias Twelvgaige.Breech.IPC.Server
  alias Twelvgaige.Breech.Lock
  alias Twelvgaige.Operations.{SessionControl, Store}

  @token "test-token"
  @workflow_path "test/fixtures/shells/simple_workflow.yaml"
  @safety_workflow_path "test/fixtures/shells/safety_workflow.yaml"

  setup do
    server = start_supervised!({Server, port: 0, token: @token})
    address = {:tcp, {127, 0, 0, 1}, Server.port(server)}
    %{address: address}
  end

  test "serves status over length-prefixed JSON IPC", %{address: address} do
    assert {:ok, status} = Client.status(address, token: @token)

    assert status["status"] == "running"
    assert status["version"] == Twelvgaige.version()
    assert status["profile"] == "laptop"
  end

  test "starts a governed session over IPC and preserves the request boundary" do
    parent = self()

    starter = fn body, opts ->
      send(parent, {:session_start, body, opts[:server]})

      {:ok,
       %{
         plan_id: "mgr_ipc",
         child_id: "child_ipc",
         session_id: "sess_ipc",
         status: :submitted
       }}
    end

    server =
      start_supervised!(
        {Server,
         port: 0,
         token: @token,
         session_start_fun: starter,
         manager_scheduler: :configured_manager},
        id: :session_start_ipc_server
      )

    address = {:tcp, {127, 0, 0, 1}, Server.port(server)}

    attrs = %{
      "runtime" => "codex",
      "repository" => "/tmp/repository",
      "task" => "Fix the failing test",
      "auth_profile" => "codex-service",
      "sandbox" => "podman",
      "saved_plan" => %{
        "schema" => "twelvgaige.session-plan",
        "schema_version" => 1,
        "plan_digest" => "sha256:ipc-boundary"
      }
    }

    assert {:ok,
            %{
              "plan_id" => "mgr_ipc",
              "child_id" => "child_ipc",
              "session_id" => "sess_ipc",
              "status" => "submitted"
            }} =
             Client.start_session(address, attrs,
               token: @token,
               request_id: "evt_session_start"
             )

    assert_receive {:session_start, request, :configured_manager}
    assert request == Map.put(attrs, "request_id", "evt_session_start")
  end

  test "streams session events, reviews handoffs, and requests bounded repair over IPC" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige-session-ipc-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    store = start_supervised!({Store, name: nil, path: Path.join(root, "operations.sqlite3")})

    operations =
      start_supervised!(
        {SessionControl, name: nil, store: store, workspace_root: Path.join(root, "workspaces")}
      )

    assert {:ok, _session} =
             SessionControl.register(
               %{
                 id: "sess_lifecycle",
                 plan_id: "plan_lifecycle",
                 status: :completed,
                 runtime: :codex,
                 start_request: %{"task" => "Fix it"},
                 credential_lease_id: "must-not-leak",
                 created_at: ~U[2026-08-09 00:00:00Z]
               },
               server: operations
             )

    assert {:ok, _event} =
             SessionControl.append_event(
               "sess_lifecycle",
               %{id: "event_one", seq: 1, type: :turn_completed, payload: %{ok: true}},
               server: operations
             )

    parent = self()

    review = fn "plan_lifecycle", opts ->
      send(parent, {:review_server, opts[:server]})
      {:ok, %{status: :completed, children: [%{handoff: %{summary: "done"}}]}}
    end

    retry = fn "sess_lifecycle", attrs, opts ->
      send(parent, {:retry_server, attrs, opts[:server], opts[:session_control]})

      {:ok,
       %{session_id: "sess_repair", retry_of_session_id: "sess_lifecycle", retry_mode: :repair}}
    end

    server =
      start_supervised!(
        {Server,
         port: 0,
         token: @token,
         operations: operations,
         manager_scheduler: :manager,
         session_review_fun: review,
         session_retry_fun: retry},
        id: :session_lifecycle_ipc_server
      )

    address = {:tcp, {127, 0, 0, 1}, Server.port(server)}

    assert {:ok, [%{"seq" => 1, "type" => "turn_completed"}]} =
             Client.list_session_events(address, "sess_lifecycle",
               token: @token,
               after_seq: 0
             )

    assert {:ok, reviewed} = Client.review_session(address, "sess_lifecycle", token: @token)
    assert reviewed["mutates_state"] == false
    refute Map.has_key?(reviewed["session"], "credential_lease_id")
    assert_receive {:review_server, :manager}

    assert {:ok, %{"session_id" => "sess_repair", "retry_mode" => "repair"}} =
             Client.retry_session(address, "sess_lifecycle", token: @token, repair?: true)

    assert_receive {:retry_server, %{"repair" => true}, :manager, ^operations}
  end

  test "rejects missing or invalid bearer token", %{address: address} do
    assert {:error, error} = Client.status(address, token: "wrong")

    assert error.reason == :daemon_auth_failed
    assert error.class == :policy_error
  end

  test "rotates the control token and invalidates the old token immediately", %{address: address} do
    assert {:ok, replacement} = Client.rotate_token(address, token: @token)
    refute replacement == @token
    assert {:error, %{reason: :daemon_auth_failed}} = Client.status(address, token: @token)
    assert {:ok, _status} = Client.status(address, token: replacement)
  end

  test "rejects oversized IPC envelopes before JSON decode" do
    server =
      start_supervised!(
        {Server, port: 0, token: @token, max_frame_bytes: 16},
        id: :small_frame_ipc_server
      )

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Server.port(server), [:binary, packet: 4, active: false])

    :ok = :gen_tcp.send(socket, String.duplicate("x", 17))
    assert {:ok, payload} = :gen_tcp.recv(socket, 0, 1_000)
    assert {:ok, response} = Protocol.decode(payload)
    assert response["ok"] == false
    assert response["error"]["message"] == ":ipc_frame_too_large"
  end

  test "rejects approve_all_safety over IPC unless explicitly enabled", %{address: address} do
    round_id = "round_ipc_inline_safety_denied_#{System.unique_integer([:positive])}"

    assert {:error, error} =
             Client.start_round(address, @safety_workflow_path, %{"cluster" => "dev"},
               token: @token,
               round_id: round_id,
               approve_all_safety?: true
             )

    assert error.class == :policy_error
    assert error.reason == :policy_denied

    server =
      start_supervised!(
        {Server, port: 0, token: @token, allow_approve_all_safety?: true},
        id: :inline_safety_ipc_server
      )

    allowed_address = {:tcp, {127, 0, 0, 1}, Server.port(server)}
    allowed_round_id = "round_ipc_inline_safety_#{System.unique_integer([:positive])}"

    assert {:ok, ^allowed_round_id} =
             Client.start_round(allowed_address, @safety_workflow_path, %{"cluster" => "dev"},
               token: @token,
               round_id: allowed_round_id,
               approve_all_safety?: true
             )
  end

  test "runs and inspects rounds over IPC", %{address: address} do
    round_id = "round_ipc_#{System.unique_integer([:positive])}"

    assert {:ok, ^round_id} =
             Client.start_round(address, @workflow_path, %{"cluster" => "dev"},
               token: @token,
               round_id: round_id
             )

    assert eventually(fn ->
             case Client.get_round(address, round_id, token: @token) do
               {:ok, snapshot} -> snapshot.status == :complete
               _other -> false
             end
           end)

    assert {:ok, snapshot} = Client.get_round(address, round_id, token: @token)
    assert snapshot.status == :complete

    assert {:ok, rounds} = Client.list_rounds(address, token: @token, status: :complete)
    assert Enum.any?(rounds, &(&1.id == round_id))

    assert {:ok, events} = Client.list_round_events(address, round_id, token: @token)
    event = List.last(events)
    assert Enum.map(events, & &1.seq) == Enum.to_list(1..length(events))
    assert event.event_type == :round_completed
    assert event.payload["status"] == "complete"
  end

  test "approves safety over IPC", %{address: address} do
    round_id = "round_ipc_approve_#{System.unique_integer([:positive])}"

    assert {:ok, ^round_id} =
             Client.start_round(address, @safety_workflow_path, %{"cluster" => "dev"},
               token: @token,
               round_id: round_id
             )

    assert eventually(fn ->
             match?(
               {:ok, %{status: :awaiting_safety}},
               Client.get_round(address, round_id, token: @token)
             )
           end)

    assert {:ok, awaiting_events} = Client.list_round_events(address, round_id, token: @token)
    awaiting_event = List.last(awaiting_events)
    assert awaiting_event.event_type == :safety_awaiting

    waiter =
      Task.async(fn ->
        Client.await_round_events(address, round_id,
          token: @token,
          after_seq: awaiting_event.seq,
          timeout_ms: 1_000
        )
      end)

    assert :ok =
             Client.approve_safety(address, round_id, "approval",
               token: @token,
               reason: "reviewed",
               actor: "human:test"
             )

    assert {:ok, [event]} = Task.await(waiter)
    assert event.event_type == :safety_approved

    assert eventually(fn ->
             match?(
               {:ok, %{status: :complete}},
               Client.get_round(address, round_id, token: @token)
             )
           end)
  end

  test "rejects safety over IPC", %{address: address} do
    round_id = "round_ipc_reject_#{System.unique_integer([:positive])}"

    assert {:ok, ^round_id} =
             Client.start_round(address, @safety_workflow_path, %{"cluster" => "dev"},
               token: @token,
               round_id: round_id
             )

    assert eventually(fn ->
             match?(
               {:ok, %{status: :awaiting_safety}},
               Client.get_round(address, round_id, token: @token)
             )
           end)

    assert :ok =
             Client.reject_safety(address, round_id, "approval",
               token: @token,
               reason: "too risky",
               actor: "human:test"
             )

    assert eventually(fn ->
             match?({:ok, %{status: :halted}}, Client.get_round(address, round_id, token: @token))
           end)
  end

  test "cancels rounds over IPC", %{address: address} do
    round_id = "round_ipc_cancel_#{System.unique_integer([:positive])}"

    assert {:ok, ^round_id} =
             Client.start_round(address, @safety_workflow_path, %{"cluster" => "dev"},
               token: @token,
               round_id: round_id
             )

    assert eventually(fn ->
             match?(
               {:ok, %{status: :awaiting_safety}},
               Client.get_round(address, round_id, token: @token)
             )
           end)

    assert :ok =
             Client.cancel_round(address, round_id,
               token: @token,
               reason: "operator stop",
               actor: "human:test"
             )

    assert {:ok, snapshot} = Client.get_round(address, round_id, token: @token)
    assert snapshot.status == :cancelled
  end

  test "public API can use explicit IPC address", %{address: address} do
    assert {:ok, status} = Twelvgaige.status(ipc_addr: address, token: @token)

    assert status["status"] == "running"
  end

  test "a response timeout preserves the accepted request identity and unknown disposition" do
    parent = self()
    {:ok, listener} = :gen_tcp.listen(0, [:binary, packet: 4, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)

    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      {:ok, payload} = :gen_tcp.recv(socket, 0, 1_000)
      {:ok, request} = Protocol.decode(payload)
      send(parent, {:timeout_request, request})
      Process.sleep(100)
      :gen_tcp.close(socket)
      :gen_tcp.close(listener)
    end)

    assert {:error, %Twelvgaige.Error{} = error} =
             Client.call(
               {:tcp, {127, 0, 0, 1}, port},
               "workspace.cleanup",
               %{"workspace_id" => "ws_timeout"},
               request_id: "req_timeout_lookup",
               timeout_ms: 25
             )

    assert_receive {:timeout_request, %{"request_id" => "req_timeout_lookup"}}

    assert error.class == :timeout_error
    assert error.reason == :client_timeout
    assert error.retryable
    assert error.details.request_id == "req_timeout_lookup"
    assert error.details.disposition == "unknown"
    assert error.details.operation_may_continue

    assert error.details.lookup_command ==
             "twelvgaige operation show req_timeout_lookup"
  end

  test "looks up a durable session operation by its request ID" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-operation-ipc-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    store = start_supervised!({Store, name: nil, path: Path.join(root, "operations.sqlite3")})

    operations =
      start_supervised!(
        {SessionControl, name: nil, store: store, workspace_root: Path.join(root, "workspaces")}
      )

    assert {:ok, _session} =
             SessionControl.register(
               %{
                 id: "sess_operation_lookup",
                 plan_id: "plan_operation_lookup",
                 status: :running,
                 runtime: :codex,
                 start_request: %{"request_id" => "req_operation_lookup"}
               },
               server: operations
             )

    server =
      start_supervised!(
        {Server, port: 0, token: @token, operations: operations},
        id: {:operation_lookup_server, root}
      )

    address = {:tcp, {127, 0, 0, 1}, Server.port(server)}

    assert {:ok, operation} =
             Client.get_operation(address, "req_operation_lookup", token: @token)

    assert operation == %{
             "kind" => "session_start",
             "request_id" => "req_operation_lookup",
             "session_id" => "sess_operation_lookup",
             "status" => "running",
             "terminal" => false,
             "updated_at" => operation["updated_at"]
           }

    assert {:error, %Twelvgaige.Error{reason: :operation_not_found}} =
             Client.get_operation(address, "req_missing", token: @token)
  end

  test "server publishes endpoint file for discovery" do
    dir = Path.join(System.tmp_dir!(), "twelvgaige_ipc_#{System.unique_integer([:positive])}")
    path = Path.join(dir, "breech.endpoint.json")
    lock_path = Path.join(dir, "breech.lock")
    on_exit(fn -> File.rm_rf(dir) end)

    server =
      start_supervised!(%{
        id: {:ipc_server, path},
        start: {Server, :start_link, [[port: 0, endpoint_path: path, lock_path: lock_path]]},
        restart: :temporary
      })

    assert {:ok, owner} = Lock.read_owner(lock_path)
    assert owner["kind"] == "twelvgaige.breech.lock"

    assert {:ok, endpoint} = Endpoint.read(path: path)
    assert endpoint.token
    assert {:tcp, {127, 0, 0, 1}, _port} = endpoint.address

    assert {:ok, status} =
             Twelvgaige.status(endpoint_path: path, discover_breech?: true)

    assert status["status"] == "running"

    :ok = GenServer.stop(server)
    assert :none = Endpoint.discover(path: path)
    refute File.exists?(lock_path)
  end

  test "stop command shuts down an endpoint-published daemon listener" do
    dir = Path.join(System.tmp_dir!(), "twelvgaige_stop_#{System.unique_integer([:positive])}")
    endpoint_path = Path.join(dir, "breech.endpoint.json")
    lock_path = Path.join(dir, "breech.lock")
    on_exit(fn -> File.rm_rf(dir) end)

    server =
      start_supervised!(%{
        id: {:ipc_stop_server, endpoint_path},
        start:
          {Server, :start_link, [[port: 0, endpoint_path: endpoint_path, lock_path: lock_path]]},
        restart: :temporary
      })

    ref = Process.monitor(server)
    assert :ok = Twelvgaige.stop_daemon(endpoint_path: endpoint_path, discover_breech?: true)
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 1_000
    assert :none = Endpoint.discover(path: endpoint_path)
    refute File.exists?(lock_path)
  end

  @tag :daemon
  test "serves status over Unix socket IPC" do
    dir =
      Path.join(System.tmp_dir!(), "twelvgaige_unix_ipc_#{System.unique_integer([:positive])}")

    socket_path = Path.join(dir, "breech.sock")
    endpoint_path = Path.join(dir, "breech.endpoint.json")
    on_exit(fn -> File.rm_rf(dir) end)

    server =
      start_supervised!(%{
        id: {:unix_ipc_server, socket_path},
        start:
          {Server, :start_link,
           [[transport: :unix, socket_path: socket_path, endpoint_path: endpoint_path]]},
        restart: :temporary
      })

    assert Server.address(server) == {:unix, socket_path}
    assert {:ok, endpoint} = Endpoint.read(path: endpoint_path)
    assert endpoint.address == {:unix, socket_path}
    assert endpoint.token == nil

    assert {:ok, status} = Client.status({:unix, socket_path})
    assert status["status"] == "running"

    :ok = GenServer.stop(server)
    assert not File.exists?(socket_path)
    assert :none = Endpoint.discover(path: endpoint_path)
  end

  test "protocol reports version mismatch" do
    request = Protocol.request("status", %{}, api_version: 999, token: @token)

    assert %{
             "ok" => false,
             "error" => %{reason: "daemon_version_mismatch"}
           } = Protocol.error(request, :daemon_version_mismatch)
  end

  test "serves workspace inspection, diff, and guarded cleanup over IPC" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-workspace-ipc-#{System.unique_integer([:positive])}"
      )

    repository = Path.join(root, "repository")
    File.mkdir_p!(repository)
    on_exit(fn -> File.rm_rf!(root) end)
    git!(repository, ["init", "--quiet"])
    git!(repository, ["config", "user.name", "Test"])
    git!(repository, ["config", "user.email", "test@localhost"])
    File.write!(Path.join(repository, "base.txt"), "base")
    git!(repository, ["add", "base.txt"])
    git!(repository, ["commit", "--quiet", "-m", "base"])

    artifact_store =
      start_supervised!(
        {Twelvgaige.Artifact.Store,
         name: nil, root: Path.join(root, "artifacts"), key: :crypto.strong_rand_bytes(32)},
        id: {:workspace_ipc_artifact_store, root}
      )

    manager =
      start_supervised!(
        {Twelvgaige.Workspace.Manager,
         name: nil, root: Path.join(root, "workspaces"), artifact_store: artifact_store},
        id: {:workspace_ipc_manager, root}
      )

    assert {:ok, workspace} =
             Twelvgaige.Workspace.Manager.create(repository,
               server: manager,
               workspace_id: "ws_ipc_result"
             )

    File.write!(Path.join(workspace.path, "result.txt"), "captured over IPC")

    assert {:ok, _workspace} =
             Twelvgaige.Workspace.Manager.quiesce(
               workspace.id,
               %{
                 runtime_stopped: true,
                 runtime_identity: "sandbox-ipc",
                 stopped_at: DateTime.utc_now()
               },
               server: manager
             )

    assert {:ok, finalized, _report} =
             Twelvgaige.Workspace.Manager.finalize(workspace.id, server: manager)

    assert {:ok, workspace_set} =
             Twelvgaige.Workspace.Manager.create_set(%{app: repository},
               server: manager,
               set_id: "wsset_ipc",
               owner_session_id: "sess_ipc_owner"
             )

    server =
      start_supervised!(
        {Server,
         port: 0, token: @token, workspace_manager: manager, artifact_store: artifact_store},
        id: {:workspace_ipc_server, root}
      )

    address = {:tcp, {127, 0, 0, 1}, Server.port(server)}

    assert {:ok, listed_workspaces} = Client.list_workspaces(address, token: @token)

    assert Enum.any?(
             listed_workspaces,
             &match?(%{"id" => "ws_ipc_result", "state" => "reviewable"}, &1)
           )

    assert {:ok, [%{"id" => "wsset_ipc"}]} =
             Client.list_workspace_sets(address, token: @token)

    assert {:ok, %{"id" => "wsset_ipc", "repositories" => repositories}} =
             Client.get_workspace_set(address, workspace_set.id, token: @token)

    assert repositories["app"]["base_commit"] == workspace_set.repositories["app"].base_commit

    assert {:ok, %{"path" => path, "control_epoch" => epoch}} =
             Client.get_workspace(address, workspace.id, token: @token)

    assert path == workspace.path
    assert epoch == finalized.control_epoch

    assert {:ok, %{"patch" => %{"encoding" => "utf-8", "data" => patch}}} =
             Client.workspace_diff(address, workspace.id, token: @token)

    assert patch =~ "result.txt"

    assert {:ok, %{"dry_run" => true, "expected_epoch" => ^epoch}} =
             Client.cleanup_workspace(address, workspace.id, token: @token)

    assert {:ok, %{"deleted" => true, "dry_run" => false}} =
             Client.cleanup_workspace(address, workspace.id,
               token: @token,
               write?: true,
               yes?: true,
               expected_epoch: epoch,
               request_id: "workspace-ipc-cleanup"
             )

    refute File.exists?(workspace.path)
  end

  defp git!(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
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
end
