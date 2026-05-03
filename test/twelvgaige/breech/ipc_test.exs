defmodule Twelvgaige.Breech.IPCTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.IPC.Client
  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.Breech.IPC.Protocol
  alias Twelvgaige.Breech.IPC.Server
  alias Twelvgaige.Breech.Lock

  @token "test-token"
  @workflow_path "test/fixtures/shells/simple_workflow.yaml"
  @safety_workflow_path "test/fixtures/shells/safety_workflow.yaml"

  defmodule FakeNpipeServerTransport do
    @moduledoc false

    @table __MODULE__

    def listen(path, _opts) do
      ensure_table()
      {:ok, broker} = __MODULE__.Broker.start_link([])
      :ets.insert(@table, {path, broker})
      {:ok, {:listener, path, broker}}
    end

    def call(path, payload, opts) do
      ensure_table()
      timeout = Keyword.fetch!(opts, :timeout_ms)

      case :ets.lookup(@table, path) do
        [{^path, broker}] -> __MODULE__.Broker.connect(broker, payload, timeout)
        [] -> {:error, :named_pipe_unsupported}
      end
    end

    def accept({:listener, _path, broker}), do: __MODULE__.Broker.accept(broker)
    def recv({:connection, payload, _from}, _timeout), do: {:ok, payload}

    def send({:connection, _payload, from}, response) do
      GenServer.reply(from, {:ok, response})
      :ok
    end

    def close({:listener, path, broker}) do
      ensure_table()
      :ets.delete(@table, path)

      if Process.alive?(broker) do
        GenServer.stop(broker, :normal, 1_000)
      end

      :ok
    catch
      :exit, _reason -> :ok
    end

    def close({:connection, _payload, _from}), do: :ok

    defp ensure_table do
      case :ets.info(@table) do
        :undefined ->
          try do
            :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
          catch
            :error, :badarg -> :ok
          end

        _info ->
          :ok
      end
    end

    defmodule Broker do
      @moduledoc false

      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
      def accept(broker), do: GenServer.call(broker, :accept, :infinity)

      def connect(broker, payload, timeout),
        do: GenServer.call(broker, {:connect, payload}, timeout)

      @impl true
      def init(_opts), do: {:ok, %{acceptor: nil, queue: :queue.new()}}

      @impl true
      def handle_call(:accept, from, state) do
        case :queue.out(state.queue) do
          {{:value, connection}, queue} ->
            {:reply, {:ok, connection}, %{state | queue: queue}}

          {:empty, _queue} ->
            {:noreply, %{state | acceptor: from}}
        end
      end

      def handle_call({:connect, payload}, from, %{acceptor: nil} = state) do
        connection = {:connection, payload, from}
        {:noreply, %{state | queue: :queue.in(connection, state.queue)}}
      end

      def handle_call({:connect, payload}, from, %{acceptor: acceptor} = state) do
        GenServer.reply(acceptor, {:ok, {:connection, payload, from}})
        {:noreply, %{state | acceptor: nil}}
      end
    end
  end

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

  test "rejects missing or invalid bearer token", %{address: address} do
    assert {:error, error} = Client.status(address, token: "wrong")

    assert error.reason == :daemon_auth_failed
    assert error.class == :policy_error
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

    assert {:ok, [event]} = Client.list_round_events(address, round_id, token: @token)
    assert event.seq == 1
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

    assert {:ok, [awaiting_event]} = Client.list_round_events(address, round_id, token: @token)

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
    assert event.event_type == :round_completed
    assert event.payload["status"] == "complete"

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

  test "named pipe addresses carry the same length-prefixed JSON protocol through an injected transport" do
    pipe_path = ~S(\\.\pipe\twelvgaige-test-breech)

    transport = fn ^pipe_path, payload, opts ->
      assert Keyword.fetch!(opts, :timeout_ms) == 30_000
      assert {:ok, request} = Protocol.decode(payload)
      assert request["command"] == "status"

      {:ok,
       Protocol.encode(
         Protocol.ok(request, %{
           "status" => "running",
           "version" => Twelvgaige.version()
         })
       )}
    end

    assert {:ok, status} =
             Client.status({:npipe, pipe_path},
               npipe_transport: transport
             )

    assert status["status"] == "running"
    assert status["version"] == Twelvgaige.version()
  end

  test "server reports named pipe listener support explicitly when unavailable" do
    trap_exit = Process.flag(:trap_exit, true)

    try do
      assert {:error, :named_pipe_unsupported} =
               Server.start_link(
                 transport: :npipe,
                 pipe_path: ~S(\\.\pipe\twelvgaige-test-breech)
               )
    after
      Process.flag(:trap_exit, trap_exit)
    end
  end

  test "server dispatches named pipe listener protocol through an injected transport" do
    dir = Path.join(System.tmp_dir!(), "twelvgaige_npipe_#{System.unique_integer([:positive])}")
    endpoint_path = Path.join(dir, "breech.endpoint.json")
    pipe_path = ~S(\\.\pipe\twelvgaige-test-server-breech)
    on_exit(fn -> File.rm_rf(dir) end)

    server =
      start_supervised!(%{
        id: {:npipe_ipc_server, pipe_path},
        start:
          {Server, :start_link,
           [
             [
               transport: :npipe,
               pipe_path: pipe_path,
               token: @token,
               endpoint_path: endpoint_path,
               npipe_server_transport: FakeNpipeServerTransport
             ]
           ]}
      })

    assert Server.address(server) == {:npipe, pipe_path}

    assert {:ok, endpoint} = Endpoint.read(path: endpoint_path)
    assert endpoint.address == {:npipe, pipe_path}

    assert {:ok, status} =
             Client.status({:npipe, pipe_path},
               token: @token,
               npipe_transport: &FakeNpipeServerTransport.call/3
             )

    assert status["status"] == "running"

    assert {:ok, discovered_status} =
             Twelvgaige.status(
               endpoint_path: endpoint_path,
               discover_breech?: true,
               token: @token,
               npipe_transport: &FakeNpipeServerTransport.call/3
             )

    assert discovered_status["status"] == "running"
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
    if match?({:win32, _name}, :os.type()) do
      :ok
    else
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
  end

  test "protocol reports version mismatch" do
    request = Protocol.request("status", %{}, api_version: 999, token: @token)

    assert %{
             "ok" => false,
             "error" => %{reason: "daemon_version_mismatch"}
           } = Protocol.error(request, :daemon_version_mismatch)
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
