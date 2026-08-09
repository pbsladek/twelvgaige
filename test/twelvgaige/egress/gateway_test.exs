defmodule Twelvgaige.Egress.GatewayTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Egress.{Broker, Gateway}

  test "CONNECT requires a scoped capability and relays only to the broker-pinned address" do
    {echo_port, close_echo} = echo_server()
    on_exit(close_echo)

    broker = broker()
    lease = lease!(broker)

    connect_fun = fn {93, 184, 216, 34}, 443, opts ->
      :gen_tcp.connect(
        {127, 0, 0, 1},
        echo_port,
        [:binary, active: false],
        Keyword.fetch!(opts, :timeout_ms)
      )
    end

    gateway =
      start_supervised!(
        {Gateway, name: nil, broker: broker, connect_fun: connect_fun, idle_timeout_ms: 2_000}
      )

    assert Gateway.status(gateway).loopback_only

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Gateway.port(gateway), [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "CONNECT api.example.com:443 HTTP/1.1\r\n" <>
          "Host: api.example.com:443\r\n" <>
          "Proxy-Authorization: Bearer #{lease.access_token}\r\n\r\n"
      )

    assert {:ok, "HTTP/1.1 200 Connection Established\r\n\r\n"} = :gen_tcp.recv(socket, 0, 2_000)
    :ok = :gen_tcp.send(socket, "bounded tunnel")
    assert {:ok, "bounded tunnel"} = :gen_tcp.recv(socket, 0, 2_000)
    :gen_tcp.close(socket)

    {:ok, denied} =
      :gen_tcp.connect({127, 0, 0, 1}, Gateway.port(gateway), [:binary, active: false])

    :ok =
      :gen_tcp.send(
        denied,
        "CONNECT api.example.com:443 HTTP/1.1\r\n" <>
          "Proxy-Authorization: Bearer #{String.duplicate("x", 43)}\r\n\r\n"
      )

    assert {:ok, response} = :gen_tcp.recv(denied, 0, 2_000)
    assert response =~ "407 Proxy Authentication Required"
    :gen_tcp.close(denied)
  end

  test "plain HTTP strips proxy authority and rejects host smuggling and undeclared destinations" do
    test_pid = self()
    {upstream_port, close_upstream} = capture_http_server(test_pid)
    on_exit(close_upstream)

    broker = broker()
    lease = lease!(broker, allowed_ports: [80, 443])

    connect_fun = fn {93, 184, 216, 34}, 80, opts ->
      :gen_tcp.connect(
        {127, 0, 0, 1},
        upstream_port,
        [:binary, active: false],
        Keyword.fetch!(opts, :timeout_ms)
      )
    end

    gateway =
      start_supervised!(
        {Gateway, name: nil, broker: broker, connect_fun: connect_fun},
        id: :plain_http_gateway
      )

    {:ok, socket} =
      :gen_tcp.connect({127, 0, 0, 1}, Gateway.port(gateway), [:binary, active: false])

    :ok =
      :gen_tcp.send(
        socket,
        "GET http://api.example.com/package HTTP/1.1\r\n" <>
          "Host: api.example.com\r\n" <>
          "Proxy-Authorization: Bearer #{lease.access_token}\r\n\r\n"
      )

    assert {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
    assert response =~ "200 OK"
    assert_receive {:upstream_request, request}
    assert request =~ "GET /package HTTP/1.1"
    refute String.downcase(request) =~ "proxy-authorization"
    refute request =~ lease.access_token

    {:ok, smuggled} =
      :gen_tcp.connect({127, 0, 0, 1}, Gateway.port(gateway), [:binary, active: false])

    :ok =
      :gen_tcp.send(
        smuggled,
        "GET http://api.example.com/ HTTP/1.1\r\n" <>
          "Host: metadata.internal\r\n" <>
          "Proxy-Authorization: Bearer #{lease.access_token}\r\n\r\n"
      )

    assert {:ok, denied} = :gen_tcp.recv(smuggled, 0, 2_000)
    assert denied =~ "403 Forbidden"
  end

  test "refuses a non-loopback control listener" do
    assert {:error, {:egress_gateway_nonloopback_denied, _child}} =
             start_supervised({Gateway, name: nil, bind_address: {0, 0, 0, 0}})
  end

  defp broker do
    resolver = fn
      "api.example.com" -> {:ok, [{93, 184, 216, 34}]}
      _host -> {:ok, [{127, 0, 0, 1}]}
    end

    start_supervised!({Broker, name: nil, resolver: resolver})
  end

  defp lease!(broker, opts \\ []) do
    now = DateTime.utc_now()

    {:ok, lease} =
      Broker.issue(
        %{
          session_id: "gateway-session",
          allowed_hosts: ["api.example.com"],
          allowed_ports: Keyword.get(opts, :allowed_ports, [443]),
          expires_at: DateTime.add(now, 300)
        },
        server: broker,
        now: now
      )

    lease
  end

  defp echo_server do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        echo(socket)
      end)

    {port,
     fn ->
       Process.exit(pid, :kill)
       :gen_tcp.close(listener)
     end}
  end

  defp echo(socket) do
    case :gen_tcp.recv(socket, 0, 2_000) do
      {:ok, bytes} ->
        :ok = :gen_tcp.send(socket, bytes)
        echo(socket)

      {:error, _reason} ->
        :gen_tcp.close(socket)
    end
  end

  defp capture_http_server(test_pid) do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, {_address, port}} = :inet.sockname(listener)

    pid =
      spawn_link(fn ->
        {:ok, socket} = :gen_tcp.accept(listener)
        {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)
        send(test_pid, {:upstream_request, request})

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
          )

        :gen_tcp.close(socket)
      end)

    {port,
     fn ->
       Process.exit(pid, :kill)
       :gen_tcp.close(listener)
     end}
  end
end
