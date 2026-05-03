defmodule Twelvgaige.API.Server do
  @moduledoc """
  Minimal local HTTP/1.1 listener for the pure control-plane router.

  The production dependency stack may eventually move this adapter to Plug and
  Bandit, but this first listener keeps the Phase 5 surface dependency-free and
  local by default. It supports fixed-length requests and closes each connection
  after one response.
  """

  use GenServer

  alias Twelvgaige.API.Response
  alias Twelvgaige.API.Router
  alias Twelvgaige.API.EventStream
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Round.Watch

  @default_ip {127, 0, 0, 1}
  @default_port 0
  @default_header_bytes 16 * 1024
  @default_body_bytes 4 * 1024 * 1024
  @default_timeout_ms 15_000
  @default_stream_clients 16
  @default_stream_send_timeout_ms 5_000
  @default_stream_idle_timeout_ms 15_000
  @default_stream_duration_ms 10 * 60 * 1_000
  @default_stream_event_limit 1_000
  @default_stream_batch_limit 100
  @default_stream_fetches 10_000

  defstruct [
    :listen_socket,
    :acceptor,
    :ip,
    :port,
    :breech,
    :bearer_token,
    :router_opts,
    :acceptor_ref,
    max_header_bytes: @default_header_bytes,
    max_body_bytes: @default_body_bytes,
    request_timeout_ms: @default_timeout_ms,
    max_stream_clients: @default_stream_clients,
    stream_send_timeout_ms: @default_stream_send_timeout_ms,
    stream_idle_timeout_ms: @default_stream_idle_timeout_ms,
    stream_duration_ms: @default_stream_duration_ms,
    stream_event_limit: @default_stream_event_limit,
    stream_batch_limit: @default_stream_batch_limit,
    stream_max_fetches: @default_stream_fetches,
    active_streams: %{}
  ]

  @type start_option ::
          {:ip, :inet.ip_address()}
          | {:port, :inet.port_number()}
          | {:breech, GenServer.server()}
          | {:bearer_token, String.t()}
          | {:allow_remote?, boolean()}
          | {:behind_tls_proxy?, boolean()}
          | {:max_header_bytes, pos_integer()}
          | {:max_body_bytes, pos_integer()}
          | {:request_timeout_ms, pos_integer()}
          | {:max_stream_clients, pos_integer()}
          | {:stream_send_timeout_ms, pos_integer()}
          | {:stream_idle_timeout_ms, pos_integer()}
          | {:stream_duration_ms, pos_integer()}
          | {:stream_event_limit, pos_integer()}
          | {:stream_batch_limit, pos_integer()}
          | {:stream_max_fetches, pos_integer()}
          | {:router_opts, keyword()}
          | GenServer.option()

  @spec start_link([start_option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    start_fun(:start_link, opts)
  end

  @spec start([start_option()]) :: GenServer.on_start()
  def start(opts \\ []) do
    start_fun(:start, opts)
  end

  defp start_fun(fun, opts) do
    name = Keyword.get(opts, :name)

    if name do
      apply(GenServer, fun, [__MODULE__, opts, [name: name]])
    else
      apply(GenServer, fun, [__MODULE__, opts])
    end
  end

  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  @spec address(GenServer.server()) :: {:http, :inet.ip_address(), :inet.port_number()}
  def address(server), do: GenServer.call(server, :address)

  @impl true
  def init(opts) do
    ip = Keyword.get(opts, :ip, @default_ip)
    port = Keyword.get(opts, :port, @default_port)

    with :ok <- validate_bind_policy(ip, opts),
         {:ok, listen_socket} <- listen(ip, port),
         {:ok, {bound_ip, bound_port}} <- :inet.sockname(listen_socket) do
      state = %__MODULE__{
        listen_socket: listen_socket,
        ip: bound_ip,
        port: bound_port,
        breech: Keyword.get(opts, :breech, Twelvgaige.Breech),
        bearer_token: Keyword.get(opts, :bearer_token, Keyword.get(opts, :auth_token)),
        router_opts: Keyword.get(opts, :router_opts, []),
        max_header_bytes: Keyword.get(opts, :max_header_bytes, @default_header_bytes),
        max_body_bytes: Keyword.get(opts, :max_body_bytes, @default_body_bytes),
        request_timeout_ms: Keyword.get(opts, :request_timeout_ms, @default_timeout_ms),
        max_stream_clients: Keyword.get(opts, :max_stream_clients, @default_stream_clients),
        stream_send_timeout_ms:
          Keyword.get(opts, :stream_send_timeout_ms, @default_stream_send_timeout_ms),
        stream_idle_timeout_ms:
          Keyword.get(opts, :stream_idle_timeout_ms, @default_stream_idle_timeout_ms),
        stream_duration_ms: Keyword.get(opts, :stream_duration_ms, @default_stream_duration_ms),
        stream_event_limit: Keyword.get(opts, :stream_event_limit, @default_stream_event_limit),
        stream_batch_limit: Keyword.get(opts, :stream_batch_limit, @default_stream_batch_limit),
        stream_max_fetches: Keyword.get(opts, :stream_max_fetches, @default_stream_fetches)
      }

      {:ok, state, {:continue, :accept}}
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
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:address, _from, state), do: {:reply, {:http, state.ip, state.port}, state}

  def handle_call({:acquire_stream_client, pid}, _from, state) do
    if map_size(state.active_streams) < state.max_stream_clients do
      ref = Process.monitor(pid)
      {:reply, :ok, put_in(state.active_streams[pid], ref)}
    else
      {:reply, {:error, :stream_client_limit}, state}
    end
  end

  def handle_call({:release_stream_client, pid}, _from, state) do
    {:reply, :ok, release_stream_client(state, pid)}
  end

  @impl true
  def handle_info({:http_accept_failed, reason}, state) do
    {:stop, {:http_accept_failed, reason}, state}
  end

  def handle_info(
        {:DOWN, ref, :process, pid, reason},
        %{acceptor_ref: ref, acceptor: pid} = state
      ) do
    case reason do
      :normal -> {:noreply, %{state | acceptor: nil, acceptor_ref: nil}}
      _reason -> {:stop, {:http_acceptor_down, reason}, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.fetch(state.active_streams, pid) do
      {:ok, ^ref} -> {:noreply, %{state | active_streams: Map.delete(state.active_streams, pid)}}
      _other -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.listen_socket, do: :gen_tcp.close(state.listen_socket)
    :ok
  end

  defp validate_bind_policy(ip, opts) do
    cond do
      local_ip?(ip) ->
        :ok

      not Keyword.get(opts, :allow_remote?, false) ->
        {:error, {:http_remote_bind_requires_opt_in, ip}}

      is_nil(Keyword.get(opts, :bearer_token, Keyword.get(opts, :auth_token))) ->
        {:error, {:http_remote_bind_requires_auth, ip}}

      not remote_bind_has_transport_protection?(opts) ->
        {:error, {:http_remote_bind_requires_tls_or_proxy, ip}}

      true ->
        :ok
    end
  end

  defp remote_bind_has_transport_protection?(opts) do
    Keyword.get(opts, :behind_tls_proxy?, false) or Keyword.has_key?(opts, :tls_options)
  end

  defp listen(ip, port) do
    :gen_tcp.listen(port, [
      :binary,
      active: false,
      reuseaddr: true,
      ip: ip
    ])
  end

  defp accept_loop(parent, listen_socket, state) do
    case :gen_tcp.accept(listen_socket) do
      {:ok, socket} ->
        spawn(fn -> handle_socket(parent, socket, state) end)
        accept_loop(parent, listen_socket, state)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        send(parent, {:http_accept_failed, reason})
    end
  end

  defp handle_socket(parent, socket, state) do
    result =
      with {:ok, method, target, headers, body} <- read_request(socket, state) do
        router_opts =
          state.router_opts
          |> Keyword.put(:server, state.breech)
          |> Keyword.put(:headers, headers)
          |> Keyword.put(:max_body_bytes, state.max_body_bytes)
          |> maybe_put(:bearer_token, state.bearer_token)

        dispatch_or_stream(parent, socket, state, method, target, body, router_opts)
      else
        {:error, reason} -> {:response, request_error_response(reason)}
      end

    case result do
      {:response, response} ->
        _result = :gen_tcp.send(socket, encode_response(response))

      :streamed ->
        :ok
    end

    :gen_tcp.close(socket)
  end

  defp dispatch_or_stream(parent, socket, state, method, target, body, router_opts) do
    case stream_spec(method, target, state) do
      :not_stream ->
        {:response, Router.dispatch(method, target, body, router_opts)}

      {:error_response, response} ->
        {:response, response}

      {:ok, spec} ->
        probe = Router.dispatch(method, bounded_probe_target(target), body, router_opts)

        if probe.status >= 400 do
          {:response, probe}
        else
          stream_response(parent, socket, state, spec, router_opts)
        end
    end
  end

  defp stream_response(parent, socket, state, spec, router_opts) do
    case GenServer.call(parent, {:acquire_stream_client, self()}, state.request_timeout_ms) do
      :ok ->
        try do
          :inet.setopts(socket,
            send_timeout: state.stream_send_timeout_ms,
            send_timeout_close: true
          )

          do_stream_response(socket, state, spec, router_opts)
        after
          GenServer.call(parent, {:release_stream_client, self()}, state.request_timeout_ms)
        end

      {:error, :stream_client_limit} ->
        {:response,
         problem(
           429,
           "Too Many Requests",
           "stream_client_limit",
           "too many active event stream clients"
         )}
    end
  end

  defp do_stream_response(socket, state, spec, router_opts) do
    with :ok <- send_response_head(socket, 200, stream_headers(spec.format)),
         :ok <- maybe_send_heartbeat(socket, spec.format),
         :ok <-
           stream_loop(socket, state, spec, router_opts, %{
             after_seq: spec.after_seq,
             remaining: spec.limit,
             fetches: 0,
             deadline_mono_ms: monotonic_ms() + state.stream_duration_ms
           }) do
      _result = send_final_chunk(socket)
      :streamed
    else
      {:error, _reason} -> :streamed
    end
  end

  defp stream_loop(_socket, _state, _spec, _router_opts, %{remaining: remaining})
       when remaining <= 0 do
    :ok
  end

  defp stream_loop(socket, state, spec, router_opts, loop_state) do
    now = monotonic_ms()

    cond do
      now >= loop_state.deadline_mono_ms ->
        :ok

      loop_state.fetches >= state.stream_max_fetches ->
        :ok

      true ->
        stream_once(socket, state, spec, router_opts, loop_state)
    end
  end

  defp stream_once(socket, state, spec, router_opts, loop_state) do
    batch_limit = min(loop_state.remaining, state.stream_batch_limit)

    timeout_ms =
      spec.timeout_ms
      |> min(max(loop_state.deadline_mono_ms - monotonic_ms(), 0))
      |> max(10)

    result =
      Watch.stream(
        spec.round_id,
        fn events ->
          body = encode_stream_events(events, spec.format)

          case send_chunk(socket, body) do
            :ok -> :ok
            {:error, reason} -> {:halt, reason}
          end
        end,
        after_seq: loop_state.after_seq,
        limit: batch_limit,
        follow?: true,
        until_terminal?: false,
        timeout_ms: timeout_ms,
        max_fetches: 2,
        source: Twelvgaige.Breech,
        source_opts: [server: Keyword.fetch!(router_opts, :server)]
      )

    case result do
      {:ok, %{after_seq: after_seq, delivered: delivered}} ->
        loop_state = %{
          loop_state
          | after_seq: after_seq,
            remaining: loop_state.remaining - delivered,
            fetches: loop_state.fetches + 1
        }

        cond do
          delivered == 0 and spec.format == :sse ->
            with :ok <- send_chunk(socket, EventStream.heartbeat()) do
              maybe_continue_stream(socket, state, spec, router_opts, loop_state)
            end

          true ->
            maybe_continue_stream(socket, state, spec, router_opts, loop_state)
        end

      {:halt, _reason} ->
        {:error, :stream_client_closed}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_continue_stream(socket, state, spec, router_opts, loop_state) do
    with {:ok, terminal?} <- stream_terminal?(spec.round_id, router_opts) do
      if spec.until_terminal? and terminal? do
        :ok
      else
        stream_loop(socket, state, spec, router_opts, loop_state)
      end
    end
  end

  defp stream_terminal?(round_id, router_opts) do
    case Twelvgaige.Breech.get_round(round_id, server: Keyword.fetch!(router_opts, :server)) do
      {:ok, %Snapshot{} = snapshot} -> {:ok, Snapshot.terminal?(snapshot)}
      {:ok, %{status: status}} -> {:ok, status in Twelvgaige.Round.State.terminal_statuses()}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stream_spec(method, target, state) do
    uri = URI.parse(target)
    query = URI.decode_query(uri.query || "")
    segments = path_segments(uri.path || "/")

    case {String.upcase(method), segments, truthy?(Map.get(query, "stream"))} do
      {"GET", ["api", "v1", "rounds", round_id, "events"], true} ->
        stream_spec_from_query(round_id, query, state)

      {_method, _segments, _stream?} ->
        :not_stream
    end
  end

  defp stream_spec_from_query(round_id, query, state) do
    with {:ok, format} <- stream_format(query),
         {:ok, after_seq} <- stream_non_negative(query, "after_seq", 0),
         {:ok, limit} <- stream_positive(query, "limit", state.stream_event_limit),
         {:ok, timeout_ms} <-
           stream_non_negative(query, "timeout_ms", state.stream_idle_timeout_ms) do
      {:ok,
       %{
         round_id: round_id,
         format: format,
         after_seq: after_seq,
         limit: min(limit, state.stream_event_limit),
         timeout_ms: timeout_ms,
         until_terminal?: truthy?(Map.get(query, "until_terminal"))
       }}
    else
      {:error, detail} ->
        {:error_response, problem(400, "Bad Request", "bad_request", detail)}
    end
  end

  defp stream_format(query) do
    case Map.get(query, "format", "sse") do
      "sse" -> {:ok, :sse}
      "ndjson" -> {:ok, :ndjson}
      other -> {:error, "stream=true supports format=sse or format=ndjson, got #{other}"}
    end
  end

  defp stream_non_negative(query, key, default) do
    case Map.get(query, key) do
      nil -> {:ok, default}
      value -> parse_non_negative_integer(value, "#{key} must be >= 0")
    end
  end

  defp stream_positive(query, key, default) do
    case Map.get(query, key) do
      nil -> {:ok, default}
      value -> parse_positive_integer(value, "#{key} must be > 0")
    end
  end

  defp parse_non_negative_integer(value, error) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, error}
    end
  end

  defp parse_positive_integer(value, error) do
    case Integer.parse(to_string(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, error}
    end
  end

  defp bounded_probe_target(target) do
    uri = URI.parse(target)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Map.delete("stream")
      |> Map.put("follow", "false")
      |> Map.put("until_terminal", "false")
      |> Map.put("timeout_ms", "0")
      |> Map.put("limit", "1")
      |> URI.encode_query()

    path = uri.path || "/"

    if query == "" do
      path
    else
      path <> "?" <> query
    end
  end

  defp stream_headers(:sse) do
    [
      {"content-type", EventStream.sse_content_type()},
      {"cache-control", "no-cache"},
      {"transfer-encoding", "chunked"},
      {"connection", "close"},
      {"x-twelvgaige-stream-mode", "chunked-push"}
    ]
  end

  defp stream_headers(:ndjson) do
    [
      {"content-type", EventStream.ndjson_content_type()},
      {"transfer-encoding", "chunked"},
      {"connection", "close"},
      {"x-twelvgaige-stream-mode", "chunked-push"}
    ]
  end

  defp maybe_send_heartbeat(socket, :sse), do: send_chunk(socket, EventStream.heartbeat())
  defp maybe_send_heartbeat(_socket, :ndjson), do: :ok

  defp encode_stream_events(events, :sse) do
    events
    |> Enum.map(&Event.to_map/1)
    |> EventStream.sse()
  end

  defp encode_stream_events(events, :ndjson) do
    events
    |> Enum.map(&Event.to_map/1)
    |> EventStream.ndjson()
  end

  defp send_response_head(socket, status, headers) do
    :gen_tcp.send(socket, [
      "HTTP/1.1 ",
      Integer.to_string(status),
      " ",
      reason_phrase(status),
      "\r\n",
      Enum.map(headers, fn {name, value} -> [to_string(name), ": ", to_string(value), "\r\n"] end),
      "\r\n"
    ])
  end

  defp send_chunk(_socket, ""), do: :ok

  defp send_chunk(socket, chunk) do
    chunk = IO.iodata_to_binary(chunk)

    :gen_tcp.send(socket, [
      Integer.to_string(byte_size(chunk), 16),
      "\r\n",
      chunk,
      "\r\n"
    ])
  end

  defp send_final_chunk(socket), do: :gen_tcp.send(socket, "0\r\n\r\n")

  defp release_stream_client(state, pid) do
    case Map.fetch(state.active_streams, pid) do
      {:ok, ref} ->
        Process.demonitor(ref, [:flush])
        %{state | active_streams: Map.delete(state.active_streams, pid)}

      :error ->
        state
    end
  end

  defp path_segments(path), do: String.split(path, "/", trim: true)

  defp truthy?(value), do: value in [true, "true", "1", 1]

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp read_request(socket, state) do
    with {:ok, header_block, remainder} <-
           read_headers(socket, "", state.max_header_bytes, state.request_timeout_ms),
         {:ok, method, target, headers} <- parse_headers(header_block),
         :ok <- reject_transfer_encoding(headers),
         {:ok, content_length} <- content_length(headers),
         :ok <- ensure_body_size(content_length, state.max_body_bytes),
         {:ok, body} <-
           read_body(socket, remainder, content_length, state.request_timeout_ms) do
      {:ok, method, target, headers, body}
    end
  end

  defp read_headers(socket, buffer, max_header_bytes, timeout) do
    cond do
      byte_size(buffer) > max_header_bytes ->
        {:error, :request_headers_too_large}

      true ->
        case :binary.match(buffer, "\r\n\r\n") do
          {offset, 4} ->
            header_block = binary_part(buffer, 0, offset)
            remainder = binary_part(buffer, offset + 4, byte_size(buffer) - offset - 4)
            {:ok, header_block, remainder}

          :nomatch ->
            case :gen_tcp.recv(socket, 0, timeout) do
              {:ok, chunk} -> read_headers(socket, buffer <> chunk, max_header_bytes, timeout)
              {:error, reason} -> {:error, {:socket_recv_failed, reason}}
            end
        end
    end
  end

  defp parse_headers(header_block) do
    case String.split(header_block, "\r\n") do
      [request_line | header_lines] ->
        with {:ok, method, target} <- parse_request_line(request_line),
             {:ok, headers} <- parse_header_lines(header_lines) do
          {:ok, method, target, headers}
        end

      _other ->
        {:error, :malformed_request}
    end
  end

  defp parse_request_line(request_line) do
    case String.split(request_line, " ", parts: 3) do
      [method, target, version] when version in ["HTTP/1.0", "HTTP/1.1"] ->
        {:ok, method, target}

      [_method, _target, _version] ->
        {:error, :unsupported_http_version}

      _other ->
        {:error, :malformed_request_line}
    end
  end

  defp parse_header_lines(lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, headers} ->
      case String.split(line, ":", parts: 2) do
        [name, value] ->
          {:cont, {:ok, [{String.downcase(String.trim(name)), String.trim(value)} | headers]}}

        _other ->
          {:halt, {:error, :malformed_header}}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      {:error, _reason} = error -> error
    end
  end

  defp reject_transfer_encoding(headers) do
    if header(headers, "transfer-encoding") do
      {:error, :transfer_encoding_unsupported}
    else
      :ok
    end
  end

  defp content_length(headers) do
    values = headers |> Enum.filter(fn {name, _value} -> name == "content-length" end)

    case values do
      [] ->
        {:ok, 0}

      [{_name, value}] ->
        case Integer.parse(value) do
          {length, ""} when length >= 0 -> {:ok, length}
          _other -> {:error, :invalid_content_length}
        end

      _multiple ->
        {:error, :invalid_content_length}
    end
  end

  defp ensure_body_size(content_length, max_body_bytes) do
    if content_length > max_body_bytes do
      {:error, :request_body_too_large}
    else
      :ok
    end
  end

  defp read_body(_socket, remainder, 0, _timeout), do: {:ok, binary_part(remainder, 0, 0)}

  defp read_body(socket, remainder, content_length, timeout) do
    already_read = byte_size(remainder)

    cond do
      already_read == content_length ->
        {:ok, remainder}

      already_read > content_length ->
        {:ok, binary_part(remainder, 0, content_length)}

      true ->
        remaining = content_length - already_read

        case :gen_tcp.recv(socket, remaining, timeout) do
          {:ok, chunk} -> {:ok, remainder <> chunk}
          {:error, reason} -> {:error, {:socket_recv_failed, reason}}
        end
    end
  end

  defp request_error_response(:request_body_too_large) do
    problem(413, "Payload Too Large", "request_body_too_large", "request body is too large")
  end

  defp request_error_response(:request_headers_too_large) do
    problem(
      431,
      "Request Header Fields Too Large",
      "request_headers_too_large",
      "request headers are too large"
    )
  end

  defp request_error_response(:transfer_encoding_unsupported) do
    problem(
      501,
      "Not Implemented",
      "transfer_encoding_unsupported",
      "transfer-encoding is not supported"
    )
  end

  defp request_error_response(:unsupported_http_version) do
    problem(
      505,
      "HTTP Version Not Supported",
      "unsupported_http_version",
      "only HTTP/1.0 and HTTP/1.1 are supported"
    )
  end

  defp request_error_response(reason) do
    problem(400, "Bad Request", "bad_request", inspect(reason))
  end

  defp problem(status, title, reason, detail) do
    %Response{
      status: status,
      headers: [{"content-type", "application/problem+json"}],
      body:
        Jason.encode!(%{
          type: "about:blank",
          title: title,
          status: status,
          reason: reason,
          detail: detail
        })
    }
  end

  defp encode_response(%Response{} = response) do
    body = response.body || ""

    headers =
      response.headers
      |> put_header_if_missing("content-length", byte_size(body))
      |> put_header_if_missing("connection", "close")

    [
      "HTTP/1.1 ",
      Integer.to_string(response.status),
      " ",
      reason_phrase(response.status),
      "\r\n",
      Enum.map(headers, fn {name, value} -> [to_string(name), ": ", to_string(value), "\r\n"] end),
      "\r\n",
      body
    ]
  end

  defp put_header_if_missing(headers, name, value) do
    if Enum.any?(headers, fn {header_name, _value} ->
         String.downcase(to_string(header_name)) == name
       end) do
      headers
    else
      headers ++ [{name, value}]
    end
  end

  defp reason_phrase(200), do: "OK"
  defp reason_phrase(202), do: "Accepted"
  defp reason_phrase(400), do: "Bad Request"
  defp reason_phrase(401), do: "Unauthorized"
  defp reason_phrase(403), do: "Forbidden"
  defp reason_phrase(404), do: "Not Found"
  defp reason_phrase(413), do: "Payload Too Large"
  defp reason_phrase(429), do: "Too Many Requests"
  defp reason_phrase(431), do: "Request Header Fields Too Large"
  defp reason_phrase(500), do: "Internal Server Error"
  defp reason_phrase(501), do: "Not Implemented"
  defp reason_phrase(503), do: "Service Unavailable"
  defp reason_phrase(505), do: "HTTP Version Not Supported"
  defp reason_phrase(_status), do: "Unknown"

  defp header(headers, name) do
    headers
    |> Enum.find_value(fn
      {^name, value} -> value
      _other -> nil
    end)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp local_ip?({127, _a, _b, _c}), do: true
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local_ip?(_ip), do: false
end
