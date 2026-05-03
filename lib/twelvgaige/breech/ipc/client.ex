defmodule Twelvgaige.Breech.IPC.Client do
  @moduledoc """
  Client for the local Breech IPC protocol.
  """

  alias Twelvgaige.Breech.IPC.Protocol
  alias Twelvgaige.Error
  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot

  @timeout_ms 30_000
  @windows_pipe_prefix "\\\\.\\pipe\\"

  @type address ::
          {:tcp, :inet.ip_address(), :inet.port_number()}
          | {:unix, Path.t()}
          | {:npipe, String.t()}

  @spec status(address(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(address, opts \\ []) do
    call(address, "status", %{}, opts)
  end

  @spec stop_daemon(address(), keyword()) :: :ok | {:error, term()}
  def stop_daemon(address, opts \\ []) do
    case call(address, "daemon.stop", %{}, opts) do
      {:ok, %{"status" => "stopping"}} -> :ok
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec start_round(address(), Path.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_round(address, workflow_path, input, opts \\ []) do
    body = %{
      "workflow_path" => workflow_path,
      "input" => input,
      "opts" => run_opts(opts)
    }

    case call(address, "round.run", body, opts) do
      {:ok, %{"id" => round_id}} when is_binary(round_id) -> {:ok, round_id}
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec get_round(address(), String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def get_round(address, round_id, opts \\ []) do
    case call(address, "round.show", %{"round_id" => round_id}, opts) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, Snapshot.new(snapshot)}
      {:error, _reason} = error -> error
    end
  end

  @spec list_rounds(address(), keyword()) :: {:ok, [Snapshot.t()]} | {:error, term()}
  def list_rounds(address, opts \\ []) do
    body =
      case Keyword.get(opts, :status) do
        nil -> %{}
        status -> %{"status" => to_string(status)}
      end

    case call(address, "round.list", body, opts) do
      {:ok, snapshots} when is_list(snapshots) -> {:ok, Enum.map(snapshots, &Snapshot.new/1)}
      {:error, _reason} = error -> error
    end
  end

  @spec list_round_events(address(), String.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def list_round_events(address, round_id, opts \\ []) do
    body =
      %{"round_id" => round_id}
      |> maybe_put("after_seq", Keyword.get(opts, :after_seq))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    case call(address, "round.events", body, opts) do
      {:ok, events} when is_list(events) -> {:ok, Enum.map(events, &Event.new/1)}
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec list_audit_events(address(), String.t(), keyword()) ::
          {:ok, [AuditEvent.t()]} | {:error, term()}
  def list_audit_events(address, round_id, opts \\ []) do
    body =
      %{"round_id" => round_id}
      |> maybe_put("after_seq", Keyword.get(opts, :after_seq))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    case call(address, "round.audit", body, opts) do
      {:ok, events} when is_list(events) -> {:ok, events}
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec await_round_events(address(), String.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def await_round_events(address, round_id, opts \\ []) do
    wait_timeout_ms = normalize_timeout_ms(Keyword.get(opts, :timeout_ms, @timeout_ms))

    body =
      %{"round_id" => round_id}
      |> maybe_put("after_seq", Keyword.get(opts, :after_seq))
      |> maybe_put("limit", Keyword.get(opts, :limit))
      |> maybe_put("timeout_ms", wait_timeout_ms)

    call_opts = Keyword.put(opts, :timeout_ms, wait_timeout_ms + 1_000)

    case call(address, "round.events.await", body, call_opts) do
      {:ok, events} when is_list(events) -> {:ok, Enum.map(events, &Event.new/1)}
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec approve_safety(address(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def approve_safety(address, round_id, shot_id, opts \\ []) do
    safety_decision(address, "round.approve", round_id, shot_id, opts)
  end

  @spec reject_safety(address(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def reject_safety(address, round_id, shot_id, opts \\ []) do
    safety_decision(address, "round.reject", round_id, shot_id, opts)
  end

  @spec cancel_round(address(), String.t(), keyword()) :: :ok | {:error, term()}
  def cancel_round(address, round_id, opts \\ []) do
    body = %{
      "round_id" => round_id,
      "reason" => Keyword.get(opts, :reason),
      "actor" => Keyword.get(opts, :actor)
    }

    case call(address, "round.cancel", body, opts) do
      {:ok, %{"status" => "accepted"}} -> :ok
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec call(address(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call({:tcp, ip, port}, command, body, opts)
      when is_tuple(ip) and is_integer(port) and is_binary(command) and is_map(body) do
    request = Protocol.request(command, body, token: Keyword.get(opts, :token))
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    with {:ok, socket} <- connect_tcp(ip, port, timeout),
         :ok <- :gen_tcp.send(socket, Protocol.encode(request)),
         {:ok, payload} <- :gen_tcp.recv(socket, 0, timeout),
         :ok <- :gen_tcp.close(socket),
         {:ok, response} <- Protocol.decode(payload) do
      decode_response(response)
    else
      {:error, reason} ->
        {:error, transport_error(reason)}
    end
  end

  def call({:unix, path}, command, body, opts)
      when is_binary(path) and is_binary(command) and is_map(body) do
    request = Protocol.request(command, body, token: Keyword.get(opts, :token))
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    with {:ok, socket} <- connect_unix(path, timeout),
         :ok <- :gen_tcp.send(socket, Protocol.encode(request)),
         {:ok, payload} <- :gen_tcp.recv(socket, 0, timeout),
         :ok <- :gen_tcp.close(socket),
         {:ok, response} <- Protocol.decode(payload) do
      decode_response(response)
    else
      {:error, reason} ->
        {:error, transport_error(reason)}
    end
  end

  def call({:npipe, path}, command, body, opts)
      when is_binary(path) and is_binary(command) and is_map(body) do
    request = Protocol.request(command, body, token: Keyword.get(opts, :token))
    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    with {:ok, payload} <- call_npipe_transport(path, Protocol.encode(request), timeout, opts),
         {:ok, response} <- Protocol.decode(payload) do
      decode_response(response)
    else
      {:error, reason} ->
        {:error, transport_error(reason)}
    end
  end

  def call(_address, _command, _body, _opts), do: {:error, :invalid_ipc_address}

  defp safety_decision(address, command, round_id, shot_id, opts) do
    body = %{
      "round_id" => round_id,
      "shot_id" => shot_id,
      "reason" => Keyword.get(opts, :reason),
      "actor" => Keyword.get(opts, :actor)
    }

    case call(address, command, body, opts) do
      {:ok, %{"status" => "accepted"}} -> :ok
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec parse_address(String.t()) :: {:ok, address()} | {:error, :invalid_ipc_address}
  def parse_address("tcp://" <> rest) do
    case String.split(rest, ":", parts: 2) do
      [host, port_string] ->
        with {port, ""} <- Integer.parse(port_string),
             {:ok, ip} <- parse_ip(host) do
          {:ok, {:tcp, ip, port}}
        else
          _error -> {:error, :invalid_ipc_address}
        end

      _other ->
        {:error, :invalid_ipc_address}
    end
  end

  def parse_address("unix://" <> path) when byte_size(path) > 0 do
    {:ok, {:unix, path}}
  end

  def parse_address("npipe://" <> rest), do: parse_npipe_uri(rest)

  def parse_address(address) when is_binary(address) do
    if String.starts_with?(address, @windows_pipe_prefix) and
         byte_size(address) > byte_size(@windows_pipe_prefix) do
      {:ok, {:npipe, address}}
    else
      {:error, :invalid_ipc_address}
    end
  end

  def parse_address(_address), do: {:error, :invalid_ipc_address}

  defp connect_tcp(ip, port, timeout) do
    :gen_tcp.connect(ip, port, [:binary, packet: 4, active: false], timeout)
  end

  defp connect_unix(path, timeout) do
    :gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: false], timeout)
  end

  defp call_npipe_transport(path, payload, timeout, opts) do
    case Keyword.get(opts, :npipe_transport, Keyword.get(opts, :pipe_transport)) do
      transport when is_function(transport, 3) ->
        transport.(path, payload, timeout_ms: timeout)

      transport when is_function(transport, 2) ->
        transport.(path, payload)

      _transport ->
        {:error, :named_pipe_unsupported}
    end
  end

  defp decode_response(%{"ok" => true, "body" => body}), do: {:ok, body}
  defp decode_response(%{"ok" => false, "error" => error}), do: {:error, decode_error(error)}
  defp decode_response(_response), do: {:error, :invalid_response}

  defp decode_error(%{"class" => class, "reason" => reason, "message" => message} = error) do
    with {:ok, class} <- known_class(class),
         {:ok, reason} <- known_reason(reason) do
      Error.new(class, reason, message,
        retryable: Map.get(error, "retryable", false),
        safety_required: Map.get(error, "safety_required", false),
        details: Map.get(error, "details", %{})
      )
    else
      :error -> Map.get(error, "reason", :unknown)
    end
  end

  defp decode_error(%{"reason" => "not_found"}), do: :not_found

  defp decode_error(%{"reason" => reason}) when is_binary(reason) do
    cond do
      reason in Enum.map(Error.reasons(), &Atom.to_string/1) -> String.to_existing_atom(reason)
      true -> :unknown
    end
  end

  defp decode_error(_error), do: :unknown

  defp known_class(class) when is_binary(class) do
    class = String.to_atom(class)
    if Error.valid_class?(class), do: {:ok, class}, else: :error
  end

  defp known_reason(reason) when is_binary(reason) do
    reason = String.to_atom(reason)
    if Error.valid_reason?(reason), do: {:ok, reason}, else: :error
  end

  defp run_opts(opts) do
    %{}
    |> maybe_put("approve_all_safety?", Keyword.get(opts, :approve_all_safety?))
    |> maybe_put("agent_shells", Keyword.get(opts, :agent_shells))
    |> maybe_put("discover_agents?", Keyword.get(opts, :discover_agents?))
    |> maybe_put("trusted_root?", Keyword.get(opts, :trusted_root?))
    |> maybe_put("untrusted_root?", Keyword.get(opts, :untrusted_root?))
    |> maybe_put(
      "allow_untrusted_agent_discovery?",
      Keyword.get(opts, :allow_untrusted_agent_discovery?)
    )
    |> maybe_put("profile", Keyword.get(opts, :profile) || Keyword.get(opts, :resource_profile))
    |> maybe_put("round_id", Keyword.get(opts, :round_id))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_timeout_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0,
    do: timeout_ms

  defp normalize_timeout_ms(timeout_ms) when is_binary(timeout_ms) do
    case Integer.parse(timeout_ms) do
      {integer, ""} when integer >= 0 -> integer
      _other -> @timeout_ms
    end
  end

  defp normalize_timeout_ms(_timeout_ms), do: @timeout_ms

  defp parse_ip(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp parse_npipe_uri(rest) do
    rest =
      rest
      |> URI.decode()
      |> String.trim_leading("/")

    case String.split(rest, "/", trim: true) do
      ["." | ["pipe" | segments]] when segments != [] ->
        {:ok, {:npipe, @windows_pipe_prefix <> Enum.join(segments, "\\")}}

      ["pipe" | segments] when segments != [] ->
        {:ok, {:npipe, @windows_pipe_prefix <> Enum.join(segments, "\\")}}

      _other ->
        {:error, :invalid_ipc_address}
    end
  end

  defp transport_error(:econnrefused), do: :daemon_unavailable
  defp transport_error(:closed), do: :daemon_unavailable
  defp transport_error(:timeout), do: :daemon_unavailable
  defp transport_error(reason), do: reason
end
