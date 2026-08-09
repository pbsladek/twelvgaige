defmodule Twelvgaige.API.ServerTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.API.Server
  alias Twelvgaige.Breech
  alias Twelvgaige.Store.File, as: FileStore

  @token "http-secret-token-32-bytes-minimum"

  @workflow %{
    kind: :workflow,
    id: "api_server_workflow",
    version: "1.0.0",
    shots: [
      %{id: "only", kind: :slug, agent: "agent", prompt: "hello"}
    ]
  }

  @safety_workflow %{
    kind: :workflow,
    id: "api_server_safety_workflow",
    version: "1.0.0",
    shots: [
      %{id: "approval", kind: :safety, description: "review"},
      %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"], prompt: "after"}
    ]
  }

  setup do
    dir =
      Path.join(System.tmp_dir!(), "twelvgaige_api_server_#{System.unique_integer([:positive])}")

    path = Path.join(dir, "store.etf")
    breech_name = :"api_server_breech_#{System.unique_integer([:positive])}"

    on_exit(fn -> File.rm_rf(dir) end)

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name, store: FileStore})

    server =
      start_supervised!(
        {Server, port: 0, breech: breech_name, bearer_token: @token, request_timeout_ms: 1_000}
      )

    %{breech: breech_name, server: server, port: Server.port(server)}
  end

  test "serves router responses over local HTTP", %{port: port} do
    response =
      http_request(port, """
      GET /api/v1/health HTTP/1.1\r
      host: localhost\r
      authorization: Bearer #{@token}\r
      \r
      """)

    assert response.status == 200
    assert response.headers["content-type"] == "application/json"
    assert String.to_integer(response.headers["content-length"]) == byte_size(response.body)

    assert %{"status" => "ok", "breech" => %{"status" => "running"}} =
             Jason.decode!(response.body)
  end

  test "enforces bearer auth at the concrete listener boundary", %{port: port} do
    response =
      http_request(port, """
      GET /api/v1/health HTTP/1.1\r
      host: localhost\r
      \r
      """)

    assert response.status == 401
    assert response.headers["www-authenticate"] == ~s(Bearer realm="twelvgaige")
    assert %{"reason" => "daemon_auth_failed"} = Jason.decode!(response.body)
  end

  test "requires local bearer auth and rotates it without retaining the old token", %{
    server: server,
    port: port
  } do
    assert {:error, :http_local_auth_required} = Server.start(port: 0)
    assert {:ok, replacement} = Server.rotate_token(server)

    old =
      http_request(port, """
      GET /api/v1/health HTTP/1.1\r
      host: localhost\r
      authorization: Bearer #{@token}\r
      \r
      """)

    assert old.status == 401

    current =
      http_request(port, """
      GET /api/v1/health HTTP/1.1\r
      host: localhost\r
      authorization: Bearer #{replacement}\r
      \r
      """)

    assert current.status == 200
  end

  test "accepts POST round creation with fixed content length", %{port: port} do
    body =
      Jason.encode!(%{
        workflow: @workflow,
        input: %{"cluster" => "dev"},
        round_id: "round_http_1"
      })

    response =
      http_request(port, [
        "POST /api/v1/rounds HTTP/1.1\r\n",
        "host: localhost\r\n",
        "authorization: Bearer #{@token}\r\n",
        "content-type: application/json\r\n",
        "content-length: #{byte_size(body)}\r\n",
        "\r\n",
        body
      ])

    assert response.status == 202
    assert %{"id" => "round_http_1", "status" => "queued"} = Jason.decode!(response.body)

    assert eventually(fn ->
             response =
               http_request(port, """
               GET /api/v1/rounds/round_http_1 HTTP/1.1\r
               host: localhost\r
               authorization: Bearer #{@token}\r
               \r
               """)

             response.status == 200 and Jason.decode!(response.body)["status"] == "complete"
           end)

    response =
      http_request(port, """
      GET /api/v1/rounds/round_http_1/events?format=sse HTTP/1.1\r
      host: localhost\r
      authorization: Bearer #{@token}\r
      \r
      """)

    assert response.status == 200
    assert response.headers["content-type"] == "text/event-stream; charset=utf-8"
    assert response.body =~ "event: round_completed\n"
  end

  test "streams round events over chunked SSE until terminal", %{port: port} do
    body =
      Jason.encode!(%{
        workflow: @safety_workflow,
        input: %{"cluster" => "dev"},
        round_id: "round_http_stream"
      })

    response =
      http_request(port, [
        "POST /api/v1/rounds HTTP/1.1\r\n",
        "host: localhost\r\n",
        "authorization: Bearer #{@token}\r\n",
        "content-type: application/json\r\n",
        "content-length: #{byte_size(body)}\r\n",
        "\r\n",
        body
      ])

    assert response.status == 202

    assert eventually(fn ->
             response =
               http_request(port, """
               GET /api/v1/rounds/round_http_stream HTTP/1.1\r
               host: localhost\r
               authorization: Bearer #{@token}\r
               \r
               """)

             response.status == 200 and
               Jason.decode!(response.body)["status"] == "awaiting_safety"
           end)

    {:ok, socket} = open_http_socket(port)

    :ok =
      :gen_tcp.send(socket, """
      GET /api/v1/rounds/round_http_stream/events?format=sse&stream=true&after_seq=1&until_terminal=true&timeout_ms=1000 HTTP/1.1\r
      host: localhost\r
      authorization: Bearer #{@token}\r
      \r
      """)

    {head, first_body} = recv_response_head(socket)
    response_head = parse_response_head(head)

    assert response_head.status == 200
    assert response_head.headers["content-type"] == "text/event-stream; charset=utf-8"
    assert response_head.headers["transfer-encoding"] == "chunked"
    assert response_head.headers["x-twelvgaige-stream-mode"] == "chunked-push"
    refute Map.has_key?(response_head.headers, "content-length")
    first_body = recv_until(socket, first_body, ": heartbeat\n\n")
    assert first_body =~ ": heartbeat\n\n"

    approval_body = Jason.encode!(%{reason: "reviewed", actor: "human:test"})

    assert %{status: 202} =
             http_request(port, [
               "POST /api/v1/rounds/round_http_stream/safety/approval/approve HTTP/1.1\r\n",
               "host: localhost\r\n",
               "authorization: Bearer #{@token}\r\n",
               "content-type: application/json\r\n",
               "content-length: #{byte_size(approval_body)}\r\n",
               "\r\n",
               approval_body
             ])

    streamed_body = first_body <> recv_all(socket, "")
    assert streamed_body =~ "event: round_completed\n"
    assert streamed_body =~ ~s("event_type":"round_completed")
    assert streamed_body =~ "0\r\n\r\n"
  end

  test "enforces the chunked stream client cap", %{breech: breech} do
    server =
      start_supervised!(
        {Server, port: 0, breech: breech, bearer_token: @token, max_stream_clients: 0},
        id: :capped_http_stream_server
      )

    port = Server.port(server)

    body =
      Jason.encode!(%{
        workflow: @workflow,
        input: %{"cluster" => "dev"},
        round_id: "round_http_stream_cap"
      })

    assert %{status: 202} =
             http_request(port, [
               "POST /api/v1/rounds HTTP/1.1\r\n",
               "host: localhost\r\n",
               "authorization: Bearer #{@token}\r\n",
               "content-type: application/json\r\n",
               "content-length: #{byte_size(body)}\r\n",
               "\r\n",
               body
             ])

    assert eventually(fn ->
             response =
               http_request(port, """
               GET /api/v1/rounds/round_http_stream_cap HTTP/1.1\r
               host: localhost\r
               authorization: Bearer #{@token}\r
               \r
               """)

             response.status == 200 and Jason.decode!(response.body)["status"] == "complete"
           end)

    response =
      http_request(port, """
      GET /api/v1/rounds/round_http_stream_cap/events?format=sse&stream=true HTTP/1.1\r
      host: localhost\r
      authorization: Bearer #{@token}\r
      \r
      """)

    assert response.status == 429
    assert %{"reason" => "stream_client_limit"} = Jason.decode!(response.body)
  end

  test "rejects oversized request bodies before router dispatch", %{port: port} do
    body = "{}"

    server =
      start_supervised!(
        {Server, port: 0, breech: Twelvgaige.Breech, bearer_token: @token, max_body_bytes: 1},
        id: :small_http_server
      )

    response =
      http_request(Server.port(server), [
        "POST /api/v1/rounds HTTP/1.1\r\n",
        "host: localhost\r\n",
        "authorization: Bearer #{@token}\r\n",
        "content-length: #{byte_size(body)}\r\n",
        "\r\n",
        body
      ])

    assert response.status == 413
    assert %{"reason" => "request_body_too_large"} = Jason.decode!(response.body)

    assert is_integer(port)
  end

  test "non-loopback HTTP bind is unsupported even with former remote options" do
    assert {:error, {:http_non_loopback_bind_unsupported, {0, 0, 0, 0}}} =
             Server.start(ip: {0, 0, 0, 0}, port: 0)

    assert {:error, {:http_non_loopback_bind_unsupported, {0, 0, 0, 0}}} =
             Server.start(ip: {0, 0, 0, 0}, port: 0, allow_remote?: true)

    assert {:error, {:http_non_loopback_bind_unsupported, {0, 0, 0, 0}}} =
             Server.start(
               ip: {0, 0, 0, 0},
               port: 0,
               allow_remote?: true,
               bearer_token: @token
             )

    assert {:error, {:http_non_loopback_bind_unsupported, {0, 0, 0, 0}}} =
             Server.start(
               ip: {0, 0, 0, 0},
               port: 0,
               allow_remote?: true,
               bearer_token: @token,
               behind_tls_proxy?: true
             )

    assert {:error, {:http_non_loopback_bind_unsupported, {0, 0, 0, 0}}} =
             Server.start(
               ip: {0, 0, 0, 0},
               port: 0,
               allow_remote?: true,
               bearer_token: @token,
               behind_tls_proxy?: true,
               trusted_proxy_cidrs: ["127.0.0.1/32"]
             )
  end

  test "rejects forwarded identity headers outside trusted proxy mode", %{port: port} do
    response =
      http_request(port, """
      GET /api/v1/health HTTP/1.1\r
      host: localhost\r
      authorization: Bearer #{@token}\r
      x-forwarded-user: attacker\r
      \r
      """)

    assert response.status == 400
    assert %{"reason" => "untrusted_forwarded_headers"} = Jason.decode!(response.body)
  end

  test "accepts forwarded identity headers from configured trusted proxy", %{breech: breech} do
    server =
      start_supervised!(
        {Server,
         port: 0,
         breech: breech,
         bearer_token: @token,
         behind_tls_proxy?: true,
         trusted_proxy_cidrs: ["127.0.0.1/32"]},
        id: :trusted_proxy_http_server
      )

    response =
      http_request(Server.port(server), """
      GET /api/v1/health HTTP/1.1\r
      host: localhost\r
      authorization: Bearer #{@token}\r
      x-forwarded-user: platform@example.test\r
      x-forwarded-for: 203.0.113.10\r
      \r
      """)

    assert response.status == 200
    assert %{"status" => "ok"} = Jason.decode!(response.body)
  end

  test "rejects forwarded identity headers from peers outside trusted proxy cidrs", %{
    breech: breech
  } do
    server =
      start_supervised!(
        {Server,
         port: 0,
         breech: breech,
         bearer_token: @token,
         behind_tls_proxy?: true,
         trusted_proxy_cidrs: ["192.0.2.0/24"]},
        id: :untrusted_proxy_http_server
      )

    response =
      http_request(Server.port(server), """
      GET /api/v1/health HTTP/1.1\r
      host: localhost\r
      authorization: Bearer #{@token}\r
      forwarded: for=203.0.113.10;proto=https\r
      \r
      """)

    assert response.status == 400
    assert %{"reason" => "untrusted_forwarded_headers"} = Jason.decode!(response.body)
  end

  defp http_request(port, request) do
    {:ok, socket} = open_http_socket(port)
    :ok = :gen_tcp.send(socket, request)
    response = recv_all(socket, "")
    parse_response(response)
  end

  defp open_http_socket(port) do
    :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1_000)
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} -> recv_all(socket, acc <> chunk)
      {:error, :closed} -> acc
    end
  end

  defp recv_until(socket, acc, pattern) when is_binary(acc) do
    if acc =~ pattern do
      acc
    else
      recv_more_until(socket, acc, pattern)
    end
  end

  defp recv_more_until(socket, acc, pattern) do
    case :gen_tcp.recv(socket, 0, 1_000) do
      {:ok, chunk} ->
        next = acc <> chunk

        if next =~ pattern do
          next
        else
          recv_more_until(socket, next, pattern)
        end

      {:error, :closed} ->
        acc
    end
  end

  defp recv_response_head(socket), do: recv_response_head(socket, "")

  defp recv_response_head(socket, acc) do
    case :binary.match(acc, "\r\n\r\n") do
      {offset, 4} ->
        head = binary_part(acc, 0, offset)
        body = binary_part(acc, offset + 4, byte_size(acc) - offset - 4)
        {head, body}

      :nomatch ->
        {:ok, chunk} = :gen_tcp.recv(socket, 0, 1_000)
        recv_response_head(socket, acc <> chunk)
    end
  end

  defp parse_response(response) do
    [head, body] = String.split(response, "\r\n\r\n", parts: 2)
    response = parse_response_head(head)
    Map.put(response, :body, body)
  end

  defp parse_response_head(head) do
    [status_line | header_lines] = String.split(head, "\r\n")
    ["HTTP/1.1", status_text | _reason] = String.split(status_line, " ", parts: 3)

    headers =
      Map.new(header_lines, fn line ->
        [name, value] = String.split(line, ":", parts: 2)
        {String.downcase(name), String.trim(value)}
      end)

    %{status: String.to_integer(status_text), headers: headers}
  end

  defp eventually(fun), do: eventually(fun, 30)
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
