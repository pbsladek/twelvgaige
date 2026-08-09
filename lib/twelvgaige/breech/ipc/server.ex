defmodule Twelvgaige.Breech.IPC.Server do
  @moduledoc """
  Local Breech IPC listener.

  Phase 3 uses loopback TCP for the fallback transport and tests. The protocol
  itself is transport-neutral length-prefixed JSON, so Unix sockets and named
  pipe transports can reuse the same dispatcher.
  """

  use GenServer

  alias Twelvgaige.Breech
  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.Breech.IPC.Protocol
  alias Twelvgaige.Breech.Lock
  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.Error
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot

  @max_unix_socket_path_bytes 103
  @default_max_frame_bytes 4 * 1024 * 1024

  defstruct [
    :listen_socket,
    :transport,
    :address,
    :port,
    :socket_path,
    :pipe_path,
    :token,
    :breech,
    :acceptor,
    :acceptor_ref,
    :endpoint_path,
    :lock,
    :operations,
    :provider_limiter,
    :scheduler,
    :retention,
    :artifact_store,
    :keyring,
    :audit_export_key,
    :audit_anchor,
    max_frame_bytes: @default_max_frame_bytes,
    allow_approve_all_safety?: false
  ]

  @type start_option ::
          {:port, :inet.port_number()}
          | {:transport, :tcp | :unix | :npipe}
          | {:socket_path, Path.t()}
          | {:pipe_path, String.t()}
          | {:token, String.t()}
          | {:breech, GenServer.server()}
          | {:endpoint_path, Path.t()}
          | {:lock_path, Path.t()}
          | {:max_frame_bytes, pos_integer()}
          | {:allow_approve_all_safety?, boolean()}
          | {:npipe_server_transport, module()}
          | {:pipe_server_transport, module()}
          | GenServer.option()

  @spec start_link([start_option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @spec child_spec([start_option()]) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :id, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @spec address(GenServer.server()) :: Twelvgaige.Breech.IPC.Client.address()
  def address(server), do: GenServer.call(server, :address)

  @spec rotate_token(GenServer.server()) :: {:ok, String.t()} | {:error, term()}
  def rotate_token(server), do: GenServer.call(server, :rotate_token)

  @impl true
  def init(opts) do
    transport = Keyword.get(opts, :transport, :tcp)
    endpoint_path = Keyword.get(opts, :endpoint_path)

    with {:ok, lock} <- acquire_lock(opts),
         {:ok, listen_socket, address} <- listen(transport, opts) do
      token = Keyword.get_lazy(opts, :token, fn -> default_token(transport, endpoint_path) end)

      state = %__MODULE__{
        listen_socket: listen_socket,
        transport: transport,
        address: address,
        port: port_from_address(address),
        socket_path: socket_path_from_address(address),
        pipe_path: pipe_path_from_address(address),
        token: token,
        breech: Keyword.get(opts, :breech, Breech),
        endpoint_path: endpoint_path,
        lock: lock,
        operations:
          Keyword.get(opts, :operations, Process.whereis(Twelvgaige.Operations.SessionControl)),
        provider_limiter:
          Keyword.get(
            opts,
            :provider_limiter,
            Process.whereis(Twelvgaige.Operations.ProviderLimiter)
          ),
        scheduler: Keyword.get(opts, :scheduler, Process.whereis(Twelvgaige.Scheduler)),
        retention:
          Keyword.get(opts, :retention, Process.whereis(Twelvgaige.Operations.RetentionEnforcer)),
        artifact_store:
          Keyword.get(opts, :artifact_store, Process.whereis(Twelvgaige.Artifact.Store)),
        keyring: Keyword.get(opts, :keyring, Process.whereis(Twelvgaige.Operations.Keyring)),
        audit_export_key:
          Keyword.get(
            opts,
            :audit_export_key,
            Application.get_env(:twelvgaige, :operations_audit_export_key) ||
              keyring_key(Process.whereis(Twelvgaige.Operations.Keyring), :audit_export)
          ),
        audit_anchor:
          Keyword.get(opts, :audit_anchor, Process.whereis(Twelvgaige.Operations.AuditAnchor)),
        max_frame_bytes: Keyword.get(opts, :max_frame_bytes, @default_max_frame_bytes),
        allow_approve_all_safety?: Keyword.get(opts, :allow_approve_all_safety?, false)
      }

      case write_endpoint(state) do
        :ok ->
          {:ok, state, {:continue, :accept}}

        {:error, reason} ->
          close_transport(listen_socket)
          cleanup_socket_path(state)
          release_lock(lock)
          {:stop, reason}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:accept, state) do
    parent = self()
    listen_socket = state.listen_socket

    {acceptor, acceptor_ref} =
      spawn_monitor(fn ->
        accept_loop(parent, listen_socket, state)
      end)

    {:noreply, %{state | acceptor: acceptor, acceptor_ref: acceptor_ref}}
  end

  @impl true
  def handle_call(:port, _from, state) do
    {:reply, state.port, state}
  end

  def handle_call(:address, _from, state) do
    {:reply, state.address, state}
  end

  def handle_call(:request_state, _from, state), do: {:reply, state, state}

  def handle_call(:rotate_token, _from, state) do
    token = Endpoint.token()
    next = %{state | token: token}

    with :ok <- write_endpoint(next),
         {:ok, _event} <- append_control_audit(state, :control_token_rotated, %{}) do
      {:reply, {:ok, token}, next}
    else
      {:error, reason} ->
        _ = write_endpoint(state)
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info(:stop_requested, state) do
    {:stop, :normal, state}
  end

  def handle_info({:ipc_accept_failed, reason}, state) do
    {:stop, {:ipc_accept_failed, reason}, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{acceptor_ref: ref, acceptor: pid} = state
      ) do
    case reason do
      :normal -> {:noreply, %{state | acceptor: nil, acceptor_ref: nil}}
      _reason -> {:stop, {:ipc_acceptor_down, reason}, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.endpoint_path, do: Endpoint.remove(path: state.endpoint_path)
    cleanup_socket_path(state)
    if state.listen_socket, do: close_transport(state.listen_socket)
    release_lock(state.lock)
    :ok
  end

  defp write_endpoint(%{endpoint_path: nil}), do: :ok

  defp write_endpoint(state) do
    Endpoint.write(
      %{address: state.address, token: state.token},
      path: state.endpoint_path
    )
  end

  defp acquire_lock(opts) do
    case Keyword.get(opts, :lock_path) do
      nil -> {:ok, nil}
      path -> Lock.acquire(path: path)
    end
  end

  defp release_lock(nil), do: :ok
  defp release_lock(%Lock{} = lock), do: Lock.release(lock)

  defp listen(:tcp, opts) do
    port = Keyword.get(opts, :port, 0)

    with {:ok, listen_socket} <-
           :gen_tcp.listen(port, [
             :binary,
             packet: 4,
             active: false,
             reuseaddr: true,
             ip: {127, 0, 0, 1}
           ]),
         {:ok, {{127, 0, 0, 1}, bound_port}} <- :inet.sockname(listen_socket) do
      {:ok, listen_socket, {:tcp, {127, 0, 0, 1}, bound_port}}
    end
  end

  defp listen(:unix, opts) do
    case Keyword.fetch(opts, :socket_path) do
      {:ok, path} ->
        path = Path.expand(path)

        with :ok <- ensure_unix_socket_path(path),
             {:ok, listen_socket} <-
               :gen_tcp.listen(0, [
                 :binary,
                 packet: 4,
                 active: false,
                 ifaddr: {:local, path}
               ]) do
          {:ok, listen_socket, {:unix, path}}
        end

      :error ->
        {:error, :socket_path_required}
    end
  end

  defp listen(:npipe, opts) do
    case Keyword.fetch(opts, :pipe_path) do
      {:ok, path} when is_binary(path) ->
        case Keyword.get(opts, :npipe_server_transport, Keyword.get(opts, :pipe_server_transport)) do
          nil ->
            if windows?() do
              {:error, :named_pipe_transport_unimplemented}
            else
              {:error, :named_pipe_unsupported}
            end

          transport when is_atom(transport) ->
            with {:ok, listener} <- transport.listen(path, opts) do
              {:ok, {:transport_driver, transport, listener}, {:npipe, path}}
            end

          _transport ->
            {:error, :invalid_named_pipe_transport}
        end

      :error ->
        {:error, :pipe_path_required}
    end
  end

  defp listen(transport, _opts), do: {:error, {:unsupported_ipc_transport, transport}}

  defp ensure_unix_socket_path(path) do
    cond do
      windows?() ->
        {:error, :unix_socket_unsupported}

      byte_size(path) > @max_unix_socket_path_bytes ->
        {:error, {:unix_socket_path_too_long, path}}

      true ->
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- chmod_if_supported(Path.dirname(path), 0o700) do
          :ok
        end
    end
  end

  defp default_token(:tcp, endpoint_path), do: if(endpoint_path, do: Endpoint.token())
  defp default_token(:unix, _endpoint_path), do: nil
  defp default_token(_transport, _endpoint_path), do: nil

  defp port_from_address({:tcp, _ip, port}), do: port
  defp port_from_address(_address), do: nil

  defp socket_path_from_address({:unix, path}), do: path
  defp socket_path_from_address(_address), do: nil

  defp pipe_path_from_address({:npipe, path}), do: path
  defp pipe_path_from_address(_address), do: nil

  defp cleanup_socket_path(%{socket_path: nil}), do: :ok

  defp cleanup_socket_path(%{socket_path: path}) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp chmod_if_supported(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, :eperm} -> if(windows?(), do: :ok, else: {:error, :eperm})
      {:error, _reason} = error -> error
    end
  end

  defp windows? do
    match?({:win32, _name}, :os.type())
  end

  defp accept_loop(parent, listen_socket, state) do
    case accept_transport(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> handle_socket(parent, socket, state) end)
        accept_loop(parent, listen_socket, state)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(parent, {:ipc_accept_failed, reason})
    end
  end

  defp handle_socket(server, socket, state) do
    response =
      with {:ok, payload} <- recv_transport(socket, 30_000),
           :ok <- ensure_frame_size(payload, state.max_frame_bytes),
           {:ok, request} <- Protocol.decode(payload),
           current <- GenServer.call(server, :request_state) do
        dispatch(request, current, server)
      else
        {:error, reason} ->
          Protocol.error(%{}, reason)
      end

    send_transport(socket, Protocol.encode(response))
    close_transport(socket)
  end

  defp accept_transport({:transport_driver, transport, listener}) do
    case transport.accept(listener) do
      {:ok, socket} -> {:ok, {:transport_driver, transport, socket}}
      {:error, _reason} = error -> error
    end
  end

  defp accept_transport(listen_socket), do: :gen_tcp.accept(listen_socket)

  defp recv_transport({:transport_driver, transport, socket}, timeout) do
    transport.recv(socket, timeout)
  end

  defp recv_transport(socket, timeout), do: :gen_tcp.recv(socket, 0, timeout)

  defp ensure_frame_size(payload, max_frame_bytes)
       when is_binary(payload) and is_integer(max_frame_bytes) and max_frame_bytes > 0 do
    if byte_size(payload) <= max_frame_bytes do
      :ok
    else
      {:error, :ipc_frame_too_large}
    end
  end

  defp ensure_frame_size(_payload, _max_frame_bytes), do: {:error, :invalid_envelope}

  defp send_transport({:transport_driver, transport, socket}, payload) do
    transport.send(socket, payload)
  end

  defp send_transport(socket, payload), do: :gen_tcp.send(socket, payload)

  defp close_transport({:transport_driver, transport, resource}) do
    transport.close(resource)
  end

  defp close_transport(socket), do: :gen_tcp.close(socket)

  defp dispatch(request, state, server) do
    cond do
      Map.get(request, "api_version") != Protocol.api_version() ->
        Protocol.error(request, :daemon_version_mismatch)

      not Protocol.valid_request?(request) ->
        Protocol.error(request, :invalid_envelope)

      not Protocol.authorized?(request, state.token) ->
        _ =
          append_control_audit(state, :control_authentication_failed, %{
            command: Map.get(request, "command")
          })

        Protocol.error(request, :daemon_auth_failed)

      true ->
        execute(request, state, server)
    end
  end

  defp execute(%{"command" => "daemon.stop"} = request, _state, server) do
    send(server, :stop_requested)
    Protocol.ok(request, %{"status" => "stopping"})
  end

  defp execute(%{"command" => "daemon.token.rotate"} = request, _state, server) do
    case rotate_token(server) do
      {:ok, token} -> Protocol.ok(request, %{"token" => token, "status" => "rotated"})
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "status"} = request, state, _server) do
    breech = state.breech

    case Breech.status(breech) do
      {:ok, status} -> Protocol.ok(request, status)
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "session.list", "body" => body} = request, state, _server) do
    with {:ok, operations} <- require_operations(state),
         {:ok, sessions} <-
           Twelvgaige.Operations.SessionControl.list(
             server: operations,
             status: parse_session_status(body["status"])
           ) do
      Protocol.ok(request, sessions)
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "session.show", "body" => body} = request, state, _server) do
    with {:ok, operations} <- require_operations(state),
         {:ok, session} <-
           Twelvgaige.Operations.SessionControl.get(body["session_id"], server: operations) do
      Protocol.ok(request, Map.drop(session, [:controller_pid, :credential_lease_id]))
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "session.attach", "body" => body} = request, state, _server) do
    with {:ok, operations} <- require_operations(state),
         {:ok, lease, session} <-
           Twelvgaige.Operations.SessionControl.attach(body["session_id"], server: operations) do
      Protocol.ok(request, %{lease: lease, session: session})
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "session.takeover", "body" => body} = request, state, _server) do
    with {:ok, operations} <- require_operations(state),
         epoch <- body["expected_epoch"],
         true <- is_integer(epoch),
         {:ok, lease, session} <-
           Twelvgaige.Operations.SessionControl.takeover(body["session_id"], epoch,
             server: operations
           ) do
      Protocol.ok(request, %{lease: lease, session: session})
    else
      false -> Protocol.error(request, :session_control_epoch_required)
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "session.revoke", "body" => body} = request, state, _server) do
    with {:ok, operations} <- require_operations(state),
         {:ok, session} <-
           Twelvgaige.Operations.SessionControl.revoke(body["session_id"], server: operations) do
      Protocol.ok(request, session)
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "sandbox.health"} = request, state, _server) do
    with {:ok, operations} <- require_operations(state),
         {:ok, health} <-
           Twelvgaige.Operations.SessionControl.backend_health(server: operations) do
      Protocol.ok(request, health)
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "sandbox.reconcile", "body" => body} = request, state, _server) do
    with {:ok, operations} <- require_operations(state),
         {:ok, report} <-
           Twelvgaige.Operations.SessionControl.reconcile(
             server: operations,
             apply?: body["apply"] == true,
             destroy_orphans?: body["destroy_orphans"] == true
           ) do
      Protocol.ok(request, report)
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "operations.dashboard"} = request, state, _server) do
    with {:ok, operations} <- require_operations(state) do
      dashboard =
        Twelvgaige.Operations.Dashboard.snapshot(
          session_control: operations,
          provider_limiter: state.provider_limiter,
          scheduler: state.scheduler,
          audit_anchor: state.audit_anchor
        )

      Protocol.ok(request, dashboard)
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "operations.audit.status"} = request, state, _server) do
    with {:ok, audit_anchor} <- require_audit_anchor(state) do
      Protocol.ok(request, Twelvgaige.Operations.AuditAnchor.status(server: audit_anchor))
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "operations.audit.checkpoint"} = request, state, _server) do
    with {:ok, audit_anchor} <- require_audit_anchor(state),
         {:ok, report} <- Twelvgaige.Operations.AuditAnchor.run(server: audit_anchor) do
      Protocol.ok(request, report)
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(
         %{"command" => "operations.audit.export", "body" => body} = request,
         state,
         _server
       ) do
    with {:ok, operations} <- require_operations(state),
         key when is_binary(key) <- state.audit_export_key,
         destination when is_binary(destination) <- body["destination"],
         {:ok, _event} <-
           append_control_audit(state, :audit_export_requested, %{
             destination_digest: sha256_text(destination)
           }),
         {:ok, report} <-
           Twelvgaige.Operations.AuditExport.export(destination, key,
             store: operations_store(operations),
             authorize: fn -> :ok end
           ) do
      Protocol.ok(request, report)
    else
      nil -> Protocol.error(request, :audit_export_configuration_unavailable)
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "operations.store.stats"} = request, state, _server) do
    with {:ok, operations} <- require_operations(state),
         {:ok, stats} <-
           Twelvgaige.Operations.Store.stats(server: operations_store(operations)) do
      Protocol.ok(request, stats)
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(
         %{"command" => "operations.store.backup", "body" => body} = request,
         state,
         _server
       ) do
    with {:ok, operations} <- require_operations(state),
         {:ok, audit_anchor} <- require_audit_anchor(state),
         {:ok, _checkpoint} <-
           Twelvgaige.Operations.AuditAnchor.run(server: audit_anchor),
         destination when is_binary(destination) <- body["destination"],
         {:ok, report} <-
           Twelvgaige.Operations.Store.backup(destination,
             server: operations_store(operations),
             timeout: 60_000
           ) do
      Protocol.ok(request, report)
    else
      nil -> Protocol.error(request, :operations_destination_required)
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(
         %{"command" => "operations.store.restore", "body" => body} = request,
         state,
         _server
       ) do
    with {:ok, audit_anchor} <- require_audit_anchor(state),
         key when is_binary(key) <- state.audit_export_key,
         %{path: checkpoint_path, status: status} <-
           Twelvgaige.Operations.AuditAnchor.status(server: audit_anchor),
         true <- status in [:healthy, :stale],
         source when is_binary(source) <- body["source"],
         destination when is_binary(destination) <- body["destination"],
         {:ok, report} <-
           Twelvgaige.Operations.Store.restore_backup(source, destination,
             audit_checkpoint_path: checkpoint_path,
             audit_signing_key: key
           ) do
      Protocol.ok(request, report)
    else
      nil -> Protocol.error(request, :operations_restore_paths_required)
      false -> Protocol.error(request, :audit_checkpoint_unhealthy)
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "operations.retention.status"} = request, state, _server) do
    with {:ok, retention} <- require_retention(state) do
      Protocol.ok(request, Twelvgaige.Operations.RetentionEnforcer.status(server: retention))
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "operations.retention.run"} = request, state, _server) do
    with {:ok, retention} <- require_retention(state),
         {:ok, report} <- Twelvgaige.Operations.RetentionEnforcer.run(server: retention) do
      Protocol.ok(request, report)
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "operations.artifact.inventory"} = request, state, _server) do
    with {:ok, artifact_store} <- require_artifact_store(state),
         {:ok, inventory} <- Twelvgaige.Artifact.Store.inventory(server: artifact_store) do
      Protocol.ok(request, inventory)
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(
         %{"command" => "operations.artifact.rotate"} = request,
         state,
         _server
       ) do
    with {:ok, keyring} <- require_keyring(state),
         {:ok, report} <- Twelvgaige.Operations.Keyring.rotate_artifact(server: keyring) do
      Protocol.ok(request, report)
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "operations.release.check"} = request, _state, _server) do
    Protocol.ok(request, Twelvgaige.Operations.ReleaseGate.evaluate(File.cwd!()))
  end

  defp execute(%{"command" => "round.list", "body" => body} = request, state, _server) do
    breech = state.breech

    opts =
      case Map.get(body, "status") do
        nil -> [server: breech]
        status -> [server: breech, status: status]
      end

    case Breech.list_rounds(opts) do
      {:ok, snapshots} -> Protocol.ok(request, Enum.map(snapshots, &Snapshot.to_map/1))
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "round.show", "body" => body} = request, state, _server) do
    breech = state.breech

    case Breech.get_round(Map.get(body, "round_id"), server: breech) do
      {:ok, snapshot} -> Protocol.ok(request, Snapshot.to_map(snapshot))
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "round.events", "body" => body} = request, state, _server) do
    breech = state.breech

    opts =
      [server: breech]
      |> maybe_put(:after_seq, parse_non_negative_integer(Map.get(body, "after_seq")))
      |> maybe_put(:limit, parse_positive_integer(Map.get(body, "limit")))

    case Breech.list_round_events(Map.get(body, "round_id"), opts) do
      {:ok, events} -> Protocol.ok(request, Enum.map(events, &Event.to_map/1))
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "round.events.await", "body" => body} = request, state, _server) do
    breech = state.breech

    opts =
      [server: breech]
      |> maybe_put(:after_seq, parse_non_negative_integer(Map.get(body, "after_seq")))
      |> maybe_put(:limit, parse_positive_integer(Map.get(body, "limit")))
      |> maybe_put(:timeout_ms, parse_non_negative_integer(Map.get(body, "timeout_ms")))

    case Breech.await_round_events(Map.get(body, "round_id"), opts) do
      {:ok, events} -> Protocol.ok(request, Enum.map(events, &Event.to_map/1))
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "round.audit", "body" => body} = request, state, _server) do
    breech = state.breech

    opts =
      [server: breech]
      |> maybe_put(:after_seq, parse_non_negative_integer(Map.get(body, "after_seq")))
      |> maybe_put(:limit, parse_positive_integer(Map.get(body, "limit")))

    case Breech.list_audit_events(Map.get(body, "round_id"), opts) do
      {:ok, events} -> Protocol.ok(request, Enum.map(events, &AuditEvent.to_map/1))
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "round.run", "body" => body} = request, state, _server) do
    breech = state.breech

    with {:ok, opts} <- body |> Map.get("opts", %{}) |> run_opts(state),
         opts <- Keyword.put(opts, :server, breech) do
      case Breech.start_round(Map.get(body, "workflow_path"), Map.get(body, "input", %{}), opts) do
        {:ok, round_id} -> Protocol.ok(request, %{"id" => round_id, "status" => "queued"})
        {:error, reason} -> Protocol.error(request, reason)
      end
    else
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(%{"command" => "round.approve", "body" => body} = request, state, _server) do
    safety_decision(request, state.breech, body, :approved)
  end

  defp execute(%{"command" => "round.reject", "body" => body} = request, state, _server) do
    safety_decision(request, state.breech, body, :rejected)
  end

  defp execute(%{"command" => "round.cancel", "body" => body} = request, state, _server) do
    breech = state.breech

    opts =
      [server: breech]
      |> maybe_put(:reason, Map.get(body, "reason"))
      |> maybe_put(:actor, Map.get(body, "actor"))

    case Breech.cancel_round(Map.get(body, "round_id"), opts) do
      :ok -> Protocol.ok(request, %{"status" => "accepted"})
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp execute(request, _state, _server) do
    Protocol.error(request, :unknown_command)
  end

  defp require_operations(%{operations: operations}) when is_pid(operations),
    do: {:ok, operations}

  defp require_operations(_state), do: {:error, :operations_control_plane_unavailable}

  defp require_retention(%{retention: retention}) when is_pid(retention), do: {:ok, retention}
  defp require_retention(_state), do: {:error, :retention_enforcer_unavailable}

  defp require_artifact_store(%{artifact_store: store}) when is_pid(store), do: {:ok, store}
  defp require_artifact_store(_state), do: {:error, :artifact_store_unavailable}

  defp require_keyring(%{keyring: keyring}) when is_pid(keyring), do: {:ok, keyring}
  defp require_keyring(_state), do: {:error, :operations_keyring_unavailable}

  defp require_audit_anchor(%{audit_anchor: audit_anchor}) when is_pid(audit_anchor),
    do: {:ok, audit_anchor}

  defp require_audit_anchor(_state), do: {:error, :audit_anchor_unavailable}

  defp operations_store(operations), do: Twelvgaige.Operations.SessionControl.store(operations)

  defp append_control_audit(%{operations: operations}, event_type, details)
       when is_pid(operations) do
    Twelvgaige.Operations.Store.append_audit(
      %{
        event_type: event_type,
        occurred_at: DateTime.utc_now(),
        details: details
      },
      server: operations_store(operations)
    )
  catch
    :exit, reason -> {:error, {:operations_audit_unavailable, reason}}
  end

  defp append_control_audit(_state, _event_type, _details), do: {:ok, nil}

  defp sha256_text(value) when is_binary(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp keyring_key(nil, _purpose), do: nil

  defp keyring_key(keyring, purpose) do
    case Twelvgaige.Operations.Keyring.fetch(purpose, server: keyring) do
      {:ok, key} -> key
      {:error, _reason} -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp parse_session_status(nil), do: nil

  defp parse_session_status(status) when is_binary(status) do
    try do
      String.to_existing_atom(status)
    rescue
      ArgumentError -> status
    end
  end

  defp safety_decision(request, breech, body, decision) do
    opts =
      [server: breech]
      |> maybe_put(:reason, Map.get(body, "reason"))
      |> maybe_put(:actor, Map.get(body, "actor"))

    result =
      case decision do
        :approved ->
          Breech.approve_safety(Map.get(body, "round_id"), Map.get(body, "shot_id"), opts)

        :rejected ->
          Breech.reject_safety(Map.get(body, "round_id"), Map.get(body, "shot_id"), opts)
      end

    case result do
      :ok -> Protocol.ok(request, %{"status" => "accepted"})
      {:error, reason} -> Protocol.error(request, reason)
    end
  end

  defp run_opts(%{} = opts, state) do
    Enum.reduce_while(opts, {:ok, []}, fn
      {"approve_all_safety?", true}, {:ok, acc} ->
        if state.allow_approve_all_safety? do
          {:cont, {:ok, Keyword.put(acc, :approve_all_safety?, true)}}
        else
          {:halt,
           {:error,
            Error.new(
              :policy_error,
              :policy_denied,
              "approve_all_safety? is not accepted over IPC",
              safety_required: true,
              details: %{required: "allow_approve_all_safety?"}
            )}}
        end

      {"approve_all_safety?", false}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      {"approve_all_safety?", nil}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      {"agent_shells", value}, {:ok, acc} when is_list(value) ->
        {:cont, {:ok, Keyword.put(acc, :agent_shells, Enum.filter(value, &is_binary/1))}}

      {"discover_agents?", value}, {:ok, acc} when is_boolean(value) ->
        {:cont, {:ok, Keyword.put(acc, :discover_agents?, value)}}

      {"trusted_root?", value}, {:ok, acc} when is_boolean(value) ->
        {:cont, {:ok, Keyword.put(acc, :trusted_root?, value)}}

      {"untrusted_root?", value}, {:ok, acc} when is_boolean(value) ->
        {:cont, {:ok, Keyword.put(acc, :untrusted_root?, value)}}

      {"allow_untrusted_agent_discovery?", value}, {:ok, acc} when is_boolean(value) ->
        {:cont, {:ok, Keyword.put(acc, :allow_untrusted_agent_discovery?, value)}}

      {"profile", value}, {:ok, acc} when is_binary(value) ->
        {:cont, {:ok, Keyword.put(acc, :profile, value)}}

      {"round_id", value}, {:ok, acc} when is_binary(value) ->
        {:cont, {:ok, Keyword.put(acc, :round_id, value)}}

      _other, {:ok, acc} ->
        {:cont, {:ok, acc}}
    end)
  end

  defp run_opts(_opts, _state), do: {:ok, []}

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp parse_non_negative_integer(_value), do: nil

  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil
end
