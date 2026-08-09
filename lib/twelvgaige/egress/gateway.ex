defmodule Twelvgaige.Egress.Gateway do
  @moduledoc """
  Loopback-only authenticated HTTP CONNECT gateway for broker-only workers.

  Every connection is authorized by a short-lived egress lease. DNS is resolved
  and validated by the broker, and the gateway connects to that exact pinned
  address. Proxy authorization is consumed locally and never sent upstream.
  """

  use GenServer

  alias Twelvgaige.Egress.Broker

  @default_max_header_bytes 32_768
  @default_header_timeout_ms 10_000
  @default_connect_timeout_ms 10_000
  @default_idle_timeout_ms 60_000

  defstruct [
    :listener,
    :broker,
    :bind_address,
    :port,
    :connect_fun,
    :acceptor,
    max_header_bytes: @default_max_header_bytes,
    header_timeout_ms: @default_header_timeout_ms,
    connect_timeout_ms: @default_connect_timeout_ms,
    idle_timeout_ms: @default_idle_timeout_ms,
    accepted: 0
  ]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    options = Keyword.delete(opts, :name)

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, options),
      else: GenServer.start_link(__MODULE__, options, name: name)
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def port(server \\ __MODULE__), do: GenServer.call(server, :port)

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    bind_address = Keyword.get(opts, :bind_address, {127, 0, 0, 1})
    requested_port = Keyword.get(opts, :port, 0)

    with :ok <- loopback_only(bind_address),
         {:ok, listener} <-
           :gen_tcp.listen(requested_port, [
             :binary,
             packet: :raw,
             active: false,
             reuseaddr: true,
             nodelay: true,
             backlog: 128,
             ip: bind_address
           ]),
         {:ok, {_address, port}} <- :inet.sockname(listener) do
      state = %__MODULE__{
        listener: listener,
        broker: Keyword.get(opts, :broker, Broker),
        bind_address: bind_address,
        port: port,
        connect_fun: Keyword.get(opts, :connect_fun, &connect_upstream/3),
        max_header_bytes: Keyword.get(opts, :max_header_bytes, @default_max_header_bytes),
        header_timeout_ms: Keyword.get(opts, :header_timeout_ms, @default_header_timeout_ms),
        connect_timeout_ms: Keyword.get(opts, :connect_timeout_ms, @default_connect_timeout_ms),
        idle_timeout_ms: Keyword.get(opts, :idle_timeout_ms, @default_idle_timeout_ms)
      }

      {:ok, start_acceptor(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       bind_address: state.bind_address,
       port: state.port,
       loopback_only: true,
       accepted: state.accepted
     }, state}
  end

  @impl true
  def handle_info({:accepted, acceptor, socket}, %{acceptor: acceptor} = state) do
    handler = spawn_link(fn -> connection_wait(state) end)

    case :gen_tcp.controlling_process(socket, handler) do
      :ok -> send(handler, {:serve, socket})
      {:error, _reason} -> :gen_tcp.close(socket)
    end

    {:noreply, start_acceptor(%{state | accepted: state.accepted + 1})}
  end

  def handle_info({:accept_error, acceptor, :closed}, %{acceptor: acceptor} = state),
    do: {:noreply, %{state | acceptor: nil}}

  def handle_info({:accept_error, acceptor, _reason}, %{acceptor: acceptor} = state) do
    Process.send_after(self(), :restart_acceptor, 100)
    {:noreply, %{state | acceptor: nil}}
  end

  def handle_info(:restart_acceptor, %{acceptor: nil} = state),
    do: {:noreply, start_acceptor(state)}

  def handle_info(:restart_acceptor, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, _reason}, %{acceptor: pid} = state) do
    Process.send_after(self(), :restart_acceptor, 100)
    {:noreply, %{state | acceptor: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.listener, do: :gen_tcp.close(state.listener)
    :ok
  end

  defp start_acceptor(state) do
    owner = self()
    listener = state.listener

    acceptor =
      spawn_link(fn ->
        case :gen_tcp.accept(listener) do
          {:ok, socket} ->
            case :gen_tcp.controlling_process(socket, owner) do
              :ok -> send(owner, {:accepted, self(), socket})
              {:error, reason} -> send(owner, {:accept_error, self(), reason})
            end

          {:error, reason} ->
            send(owner, {:accept_error, self(), reason})
        end
      end)

    %{state | acceptor: acceptor}
  end

  defp connection_wait(state) do
    receive do
      {:serve, socket} ->
        try do
          serve(socket, state)
        after
          :gen_tcp.close(socket)
        end
    after
      5_000 -> :ok
    end
  end

  defp serve(socket, state) do
    with {:ok, header, rest} <-
           receive_header(socket, state.max_header_bytes, state.header_timeout_ms),
         {:ok, request} <- parse_request(header),
         {:ok, token} <- proxy_token(request.headers) do
      case request.method do
        "CONNECT" ->
          serve_connect(socket, request, token, rest, state)

        method when method in ["GET", "HEAD"] ->
          serve_plain_http(socket, request, token, rest, state)

        _other ->
          send_response(socket, 405, "Method Not Allowed")
      end
    else
      {:error, :proxy_auth_required} ->
        send_response(socket, 407, "Proxy Authentication Required")

      {:error, _reason} ->
        send_response(socket, 400, "Bad Request")
    end
  end

  defp serve_connect(socket, request, token, rest, state) do
    with {:ok, uri} <- connect_uri(request.target),
         {:ok, authorization} <- Broker.checkout(token, uri, server: state.broker),
         {:ok, upstream} <-
           state.connect_fun.(authorization.pinned_address, authorization.port,
             timeout_ms: state.connect_timeout_ms
           ) do
      try do
        :ok = :gen_tcp.send(socket, "HTTP/1.1 200 Connection Established\r\n\r\n")
        if rest != "", do: :ok = :gen_tcp.send(upstream, rest)
        relay_bidirectional(socket, upstream, state.idle_timeout_ms)
      after
        :gen_tcp.close(upstream)
        Broker.release(authorization.lease_id, server: state.broker)
      end
    else
      {:error, reason} when reason in [:invalid_egress_lease, :egress_lease_revoked] ->
        send_response(socket, 407, "Proxy Authentication Required")

      {:error, _reason} ->
        send_response(socket, 403, "Forbidden")
    end
  end

  defp serve_plain_http(socket, request, token, rest, state) do
    with "" <- rest,
         {:ok, uri} <- absolute_http_uri(request.target),
         :ok <- matching_host_header(request.headers, uri),
         {:ok, authorization} <- Broker.checkout(token, uri, server: state.broker),
         {:ok, upstream} <-
           state.connect_fun.(authorization.pinned_address, authorization.port,
             timeout_ms: state.connect_timeout_ms
           ) do
      try do
        outbound = encode_plain_request(request, uri)
        :ok = :gen_tcp.send(upstream, outbound)
        relay_one_way(upstream, socket, state.idle_timeout_ms)
      after
        :gen_tcp.close(upstream)
        Broker.release(authorization.lease_id, server: state.broker)
      end
    else
      {:error, reason} when reason in [:invalid_egress_lease, :egress_lease_revoked] ->
        send_response(socket, 407, "Proxy Authentication Required")

      _other ->
        send_response(socket, 403, "Forbidden")
    end
  end

  defp receive_header(socket, maximum, timeout, buffer \\ "") do
    case :binary.match(buffer, "\r\n\r\n") do
      {position, 4} ->
        header_size = position + 4
        <<header::binary-size(^header_size), rest::binary>> = buffer
        {:ok, header, rest}

      :nomatch when byte_size(buffer) >= maximum ->
        {:error, :proxy_header_too_large}

      :nomatch ->
        case :gen_tcp.recv(socket, 0, timeout) do
          {:ok, bytes} -> receive_header(socket, maximum, timeout, buffer <> bytes)
          {:error, reason} -> {:error, {:proxy_header_receive_failed, reason}}
        end
    end
  end

  defp parse_request(header) do
    lines = String.split(header, "\r\n", trim: true)

    with [request_line | header_lines] <- lines,
         [method, target, version] <- String.split(request_line, " ", parts: 3),
         true <- version in ["HTTP/1.0", "HTTP/1.1"],
         {:ok, headers} <- parse_headers(header_lines) do
      {:ok, %{method: method, target: target, version: version, headers: headers}}
    else
      _other -> {:error, :proxy_request_invalid}
    end
  end

  defp parse_headers(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, headers} ->
      case String.split(line, ":", parts: 2) do
        [name, value] when name != "" ->
          normalized = String.downcase(name)

          if Regex.match?(~r/^[a-z0-9!#$%&'*+.^_`|~-]+$/, normalized) do
            {:cont, {:ok, [{normalized, String.trim(value)} | headers]}}
          else
            {:halt, {:error, :proxy_header_invalid}}
          end

        _other ->
          {:halt, {:error, :proxy_header_invalid}}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      error -> error
    end
  end

  defp proxy_token(headers) do
    values = for {"proxy-authorization", value} <- headers, do: value

    case values do
      ["Bearer " <> token] when byte_size(token) >= 32 -> {:ok, token}
      _other -> {:error, :proxy_auth_required}
    end
  end

  defp connect_uri(authority) do
    uri = URI.parse("https://" <> authority)

    if is_binary(uri.host) and uri.host != "" and is_integer(uri.port) and
         uri.path in [nil, ""] and is_nil(uri.query) and is_nil(uri.fragment) and
         is_nil(uri.userinfo) do
      {:ok, uri}
    else
      {:error, :proxy_connect_authority_invalid}
    end
  end

  defp absolute_http_uri(target) do
    uri = URI.parse(target)

    if uri.scheme == "http" and is_binary(uri.host) and uri.host != "" and is_nil(uri.userinfo),
      do: {:ok, uri},
      else: {:error, :proxy_absolute_uri_required}
  end

  defp matching_host_header(headers, uri) do
    values = for {"host", value} <- headers, do: String.downcase(value)
    expected = authority(uri)

    case values do
      [] -> :ok
      [^expected] -> :ok
      _other -> {:error, :proxy_host_header_mismatch}
    end
  end

  defp encode_plain_request(request, uri) do
    path = if uri.path in [nil, ""], do: "/", else: uri.path
    path = if is_nil(uri.query), do: path, else: path <> "?" <> uri.query

    headers =
      request.headers
      |> Enum.reject(fn {name, _value} ->
        name in ["proxy-authorization", "proxy-connection", "connection", "host"]
      end)

    encoded_headers =
      [["Host: ", authority(uri), "\r\n"], ["Connection: close\r\n"]] ++
        Enum.map(headers, fn {name, value} -> [name, ": ", value, "\r\n"] end)

    IO.iodata_to_binary([
      request.method,
      " ",
      path,
      " ",
      request.version,
      "\r\n",
      encoded_headers,
      "\r\n"
    ])
  end

  defp authority(%URI{scheme: "http", host: host, port: port}) when port in [nil, 80],
    do: String.downcase(host)

  defp authority(%URI{host: host, port: port}), do: "#{String.downcase(host)}:#{port}"

  defp relay_bidirectional(left, right, timeout) do
    :ok = :inet.setopts(left, active: :once)
    :ok = :inet.setopts(right, active: :once)
    relay_active(left, right, timeout)
  end

  defp relay_active(left, right, timeout) do
    receive do
      {:tcp, ^left, bytes} ->
        with :ok <- :gen_tcp.send(right, bytes),
             :ok <- :inet.setopts(left, active: :once) do
          relay_active(left, right, timeout)
        else
          {:error, _reason} -> :ok
        end

      {:tcp, ^right, bytes} ->
        with :ok <- :gen_tcp.send(left, bytes),
             :ok <- :inet.setopts(right, active: :once) do
          relay_active(left, right, timeout)
        else
          {:error, _reason} -> :ok
        end

      {:tcp_closed, socket} when socket in [left, right] ->
        :ok

      {:tcp_error, socket, _reason} when socket in [left, right] ->
        :ok
    after
      timeout -> :ok
    end
  end

  defp relay_one_way(source, destination, timeout) do
    case :gen_tcp.recv(source, 0, timeout) do
      {:ok, bytes} ->
        case :gen_tcp.send(destination, bytes) do
          :ok -> relay_one_way(source, destination, timeout)
          {:error, _reason} -> :ok
        end

      {:error, _reason} ->
        :ok
    end
  end

  defp send_response(socket, status, reason) do
    :gen_tcp.send(
      socket,
      "HTTP/1.1 #{status} #{reason}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
    )

    :ok
  end

  defp connect_upstream(address, port, opts) do
    :gen_tcp.connect(
      address,
      port,
      [:binary, active: false, nodelay: true],
      Keyword.fetch!(opts, :timeout_ms)
    )
  end

  defp loopback_only({127, _b, _c, _d}), do: :ok
  defp loopback_only({0, 0, 0, 0, 0, 0, 0, 1}), do: :ok
  defp loopback_only(_address), do: {:error, :egress_gateway_nonloopback_denied}
end
