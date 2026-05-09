defmodule Twelvgaige.Tool.Builtins.HTTPPostTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.HTTPPost
  alias Twelvgaige.Tool.Executor

  test "posts through an injected transport with bounded request metadata" do
    transport = fn url, opts ->
      assert url == "https://example.com/hooks"
      assert opts[:method] == :post
      assert opts[:max_bytes] == 64
      assert opts[:body] == ~s({"ok":true})
      assert opts[:content_type] == "application/json"
      assert {"x-trusted", "runtime"} in opts[:headers]
      assert {"x-request-id", "abc"} in opts[:headers]

      {:ok,
       %{
         status: 202,
         headers: [{"content-type", "application/json"}],
         body: ~s({"status":"accepted","token":"secret"})
       }}
    end

    assert {:ok, result} =
             HTTPPost.execute(
               %{
                 "url" => "https://example.com/hooks",
                 "body" => ~s({"ok":true}),
                 "headers" => %{"x-request-id" => "abc"},
                 "max_bytes" => 64,
                 "confirm" => true
               },
               allowed_hosts: ["example.com"],
               dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
               headers: [{"x-trusted", "runtime"}],
               transport: transport
             )

    assert result["status"] == 202
    assert result["request_bytes"] == byte_size(~s({"ok":true}))
    assert result["body"] =~ ~s("token":"[REDACTED]")
  end

  test "requires explicit confirmation before transport" do
    assert {:error, error} =
             HTTPPost.execute(
               %{"url" => "https://example.com/hooks", "body" => "{}"},
               transport: unused_transport()
             )

    assert error.class == :policy_error
    assert error.reason == :policy_denied
    assert error.safety_required
  end

  test "denies private destinations and sensitive input headers" do
    assert {:error, private_host} =
             HTTPPost.execute(
               %{"url" => "http://localhost/hooks", "body" => "{}", "confirm" => true},
               allowed_hosts: ["localhost"],
               transport: unused_transport()
             )

    assert private_host.reason == :network_policy_denied

    assert {:error, header} =
             HTTPPost.execute(
               %{
                 "url" => "https://example.com/hooks",
                 "body" => "{}",
                 "headers" => %{"authorization" => "Bearer secret"},
                 "confirm" => true
               },
               allowed_hosts: ["example.com"],
               dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
               transport: unused_transport()
             )

    assert header.reason == :network_policy_denied
    assert header.details.header == "authorization"
  end

  test "denies non-public literal address ranges before transport" do
    cases = [
      {"http://localhost./hooks", "localhost"},
      {"http://100.64.0.1/hooks", "100.64.0.1"},
      {"http://192.0.0.1/hooks", "192.0.0.1"},
      {"http://192.0.2.1/hooks", "192.0.2.1"},
      {"http://192.88.99.1/hooks", "192.88.99.1"},
      {"http://198.18.0.1/hooks", "198.18.0.1"},
      {"http://198.51.100.1/hooks", "198.51.100.1"},
      {"http://203.0.113.1/hooks", "203.0.113.1"},
      {"http://224.0.0.1/hooks", "224.0.0.1"},
      {"http://[::ffff:127.0.0.1]/hooks", "::ffff:127.0.0.1"},
      {"http://[2001:db8::1]/hooks", "2001:db8::1"},
      {"http://[fec0::1]/hooks", "fec0::1"}
    ]

    for {url, allowed_host} <- cases do
      assert {:error, error} =
               HTTPPost.execute(
                 %{"url" => url, "body" => "{}", "confirm" => true},
                 allowed_hosts: [allowed_host],
                 transport: unused_transport()
               )

      assert error.reason == :network_policy_denied
    end
  end

  test "validates malformed allowed host policies without raising" do
    assert {:error, error} =
             HTTPPost.execute(
               %{"url" => "https://example.com/hooks", "body" => "{}", "confirm" => true},
               allowed_hosts: [:example],
               transport: unused_transport()
             )

    assert error.reason == :network_policy_denied
  end

  test "wildcard host policies require a subdomain match" do
    transport = fn _url, _opts -> {:ok, %{status: 204, headers: [], body: ""}} end

    assert {:error, apex_error} =
             HTTPPost.execute(
               %{"url" => "https://example.com/hooks", "body" => "{}", "confirm" => true},
               allowed_hosts: ["*.example.com"],
               transport: transport
             )

    assert apex_error.reason == :network_policy_denied

    assert {:ok, %{"status" => 204}} =
             HTTPPost.execute(
               %{
                 "url" => "https://api.example.com/hooks",
                 "body" => "{}",
                 "confirm" => true
               },
               allowed_hosts: ["*.example.com"],
               dns_resolver: fn "api.example.com" -> {:ok, [{93, 184, 216, 34}]} end,
               transport: transport
             )
  end

  test "requires explicit allowed host policy" do
    assert {:error, error} =
             HTTPPost.execute(
               %{"url" => "https://example.com/hooks", "body" => "{}", "confirm" => true},
               transport: unused_transport()
             )

    assert error.reason == :network_policy_denied
    assert error.details.host == "example.com"
  end

  test "enforces destructive safety threshold through executor" do
    transport = fn _url, _opts -> {:ok, %{status: 204, headers: [], body: ""}} end

    input = %{
      "url" => "https://example.com/hooks",
      "body" => "{}",
      "confirm" => true
    }

    assert {:error, policy} =
             Executor.execute("http_post", input,
               allowed_tools: ["http_post"],
               max_safety: :idempotent_write,
               limiter: nil,
               tool_opts: [
                 allowed_hosts: ["example.com"],
                 dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
                 transport: transport
               ]
             )

    assert policy.class == :policy_error
    assert policy.reason == :policy_denied

    assert {:ok, %{"status" => 204}} =
             Executor.execute("http_post", input,
               allowed_tools: ["http_post"],
               max_safety: :destructive,
               limiter: nil,
               tool_opts: [
                 allowed_hosts: ["example.com"],
                 dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
                 transport: transport
               ]
             )
  end

  test "rejects oversized request and response bodies" do
    assert {:error, request_error} =
             HTTPPost.execute(
               %{
                 "url" => "https://example.com/hooks",
                 "body" => "abcdef",
                 "max_body_bytes" => 3,
                 "confirm" => true
               },
               allowed_hosts: ["example.com"],
               dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
               transport: unused_transport()
             )

    assert request_error.reason == :http_request_too_large

    transport = fn _url, _opts -> {:ok, %{status: 200, headers: [], body: "abcdef"}} end

    assert {:error, response_error} =
             HTTPPost.execute(
               %{
                 "url" => "https://example.com/hooks",
                 "body" => "{}",
                 "max_bytes" => 3,
                 "confirm" => true
               },
               allowed_hosts: ["example.com"],
               dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
               transport: transport
             )

    assert response_error.reason == :http_response_too_large
  end

  defp unused_transport do
    fn _url, _opts -> flunk("transport should not be called") end
  end
end
