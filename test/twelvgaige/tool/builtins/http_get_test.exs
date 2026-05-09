defmodule Twelvgaige.Tool.Builtins.HTTPGetTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.HTTPGet

  test "fetches through an injected transport" do
    transport = fn url, opts ->
      assert url == "https://example.com/status"
      assert opts[:max_bytes] == 64
      {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "ok"}}
    end

    assert {:ok, result} =
             HTTPGet.execute(%{"url" => "https://example.com/status", "max_bytes" => 64},
               allowed_hosts: ["example.com"],
               dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
               transport: transport
             )

    assert result["status"] == 200
    assert result["headers"] == [["content-type", "text/plain"]]
    assert result["body"] == "ok"
  end

  test "denies localhost and private IPs before transport" do
    transport = fn _url, _opts -> flunk("transport should not be called") end

    assert {:error, localhost} =
             HTTPGet.execute(%{"url" => "http://localhost"},
               allowed_hosts: ["localhost"],
               transport: transport
             )

    assert localhost.reason == :network_policy_denied

    assert {:error, private_ip} =
             HTTPGet.execute(%{"url" => "http://169.254.169.254"},
               allowed_hosts: ["169.254.169.254"],
               transport: transport
             )

    assert private_ip.reason == :network_policy_denied
  end

  test "denies non-public literal address ranges before transport" do
    transport = fn _url, _opts -> flunk("transport should not be called") end

    cases = [
      {"http://localhost.", "localhost"},
      {"http://100.64.0.1", "100.64.0.1"},
      {"http://192.0.0.1", "192.0.0.1"},
      {"http://192.0.2.1", "192.0.2.1"},
      {"http://192.88.99.1", "192.88.99.1"},
      {"http://198.18.0.1", "198.18.0.1"},
      {"http://198.51.100.1", "198.51.100.1"},
      {"http://203.0.113.1", "203.0.113.1"},
      {"http://224.0.0.1", "224.0.0.1"},
      {"http://[::ffff:127.0.0.1]", "::ffff:127.0.0.1"},
      {"http://[2001:db8::1]", "2001:db8::1"},
      {"http://[fec0::1]", "fec0::1"}
    ]

    for {url, allowed_host} <- cases do
      assert {:error, error} =
               HTTPGet.execute(%{"url" => url},
                 allowed_hosts: [allowed_host],
                 transport: transport
               )

      assert error.reason == :network_policy_denied
    end
  end

  test "validates malformed allowed host policies without raising" do
    assert {:error, error} =
             HTTPGet.execute(%{"url" => "https://example.com"},
               allowed_hosts: [:example],
               transport: fn _url, _opts -> flunk("transport should not be called") end
             )

    assert error.reason == :network_policy_denied
  end

  test "wildcard host policies require a subdomain match" do
    transport = fn _url, _opts -> {:ok, %{status: 200, headers: [], body: "ok"}} end

    assert {:error, apex_error} =
             HTTPGet.execute(%{"url" => "https://example.com"},
               allowed_hosts: ["*.example.com"],
               transport: transport
             )

    assert apex_error.reason == :network_policy_denied

    assert {:ok, %{"status" => 200}} =
             HTTPGet.execute(%{"url" => "https://api.example.com"},
               allowed_hosts: ["*.example.com"],
               dns_resolver: fn "api.example.com" -> {:ok, [{93, 184, 216, 34}]} end,
               transport: transport
             )
  end

  test "requires explicit allowed host policy" do
    assert {:error, error} =
             HTTPGet.execute(%{"url" => "https://example.com"},
               transport: fn _url, _opts -> flunk("transport should not be called") end
             )

    assert error.reason == :network_policy_denied
    assert error.details.host == "example.com"
  end

  test "enforces allowed host policy" do
    transport = fn _url, _opts -> {:ok, %{status: 200, headers: [], body: "ok"}} end

    assert {:error, error} =
             HTTPGet.execute(%{"url" => "https://blocked.example"},
               allowed_hosts: ["example.com"],
               transport: transport
             )

    assert error.reason == :network_policy_denied
  end

  test "denies hostnames that resolve to private addresses before transport" do
    transport = fn _url, _opts -> flunk("transport should not be called") end

    assert {:error, error} =
             HTTPGet.execute(%{"url" => "https://metadata.example"},
               allowed_hosts: ["metadata.example"],
               dns_resolver: fn "metadata.example" ->
                 {:ok, [{93, 184, 216, 34}, {169, 254, 169, 254}]}
               end,
               transport: transport
             )

    assert error.reason == :network_policy_denied
    assert error.safety_required
    assert error.details.host == "metadata.example"
    assert error.details.address == "169.254.169.254"
  end

  test "treats DNS failures as retryable tool failures" do
    transport = fn _url, _opts -> flunk("transport should not be called") end

    assert {:error, error} =
             HTTPGet.execute(%{"url" => "https://temporary.example"},
               allowed_hosts: ["temporary.example"],
               dns_resolver: fn "temporary.example" -> {:error, :timeout} end,
               transport: transport
             )

    assert error.reason == :tool_retryable
    assert error.retryable
    assert error.details.host == "temporary.example"
  end

  test "denies redirects" do
    transport = fn _url, _opts ->
      {:ok, %{status: 302, headers: [{"location", "https://example.com/next"}], body: ""}}
    end

    assert {:error, error} =
             HTTPGet.execute(%{"url" => "https://example.com"},
               allowed_hosts: ["example.com"],
               dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
               transport: transport
             )

    assert error.reason == :http_redirect_denied
    assert error.safety_required
  end

  test "rejects oversized responses" do
    transport = fn _url, _opts ->
      {:ok, %{status: 200, headers: [], body: "abcdef"}}
    end

    assert {:error, error} =
             HTTPGet.execute(%{"url" => "https://example.com", "max_bytes" => 3},
               allowed_hosts: ["example.com"],
               dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
               transport: transport
             )

    assert error.reason == :http_response_too_large
  end

  test "rejects explicitly invalid max_bytes instead of falling back to defaults" do
    transport = fn _url, _opts -> flunk("transport should not be called") end

    for max_bytes <- [0, false] do
      assert {:error, error} =
               HTTPGet.execute(%{"url" => "https://example.com", "max_bytes" => max_bytes},
                 allowed_hosts: ["example.com"],
                 dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
                 transport: transport
               )

      assert error.reason == :tool_input_invalid
    end
  end
end
