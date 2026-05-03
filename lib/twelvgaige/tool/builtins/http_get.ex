defmodule Twelvgaige.Tool.Builtins.HTTPGet do
  @moduledoc """
  Bounded HTTP GET tool with local network policy checks.

  Tests inject a transport function, so normal test runs never touch the
  network. The default transport uses Erlang's `:httpc` for later manual use.
  """

  @behaviour Twelvgaige.Tool

  import Bitwise

  alias Twelvgaige.Error
  alias Twelvgaige.Tool.Idempotency

  @default_max_bytes 64 * 1024
  @hard_max_bytes 1_048_576
  @redirect_statuses 300..399

  @impl true
  def name, do: "http_get"

  @impl true
  def description, do: "Fetch a bounded HTTP or HTTPS response body."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "required" => ["url"],
      "properties" => %{
        "url" => %{"type" => "string"},
        "max_bytes" => %{"type" => "integer"}
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def safety_level, do: :read_only

  @impl true
  def idempotency, do: Idempotency.read_only()

  @impl true
  def execute(input, opts) do
    with {:ok, url} <- fetch_url(input),
         {:ok, uri} <- validate_uri(url, opts),
         {:ok, max_bytes} <- max_bytes(input, opts),
         {:ok, response} <- call_transport(url, uri, max_bytes, opts),
         :ok <- ensure_not_redirect(response),
         :ok <- ensure_response_size(response, max_bytes) do
      {:ok,
       %{
         "url" => url,
         "status" => response.status,
         "headers" => normalize_headers(response.headers),
         "bytes" => byte_size(response.body),
         "body" => response.body
       }}
    end
  end

  defp fetch_url(input) do
    case Map.get(input, "url") || Map.get(input, :url) do
      url when is_binary(url) -> {:ok, url}
      _value -> tool_error(:tool_input_invalid, "url must be a string")
    end
  end

  defp validate_uri(url, opts) do
    uri = URI.parse(url)

    with :ok <- ensure_scheme(uri),
         :ok <- ensure_host(uri),
         :ok <- ensure_no_userinfo(uri),
         :ok <- ensure_allowed_host(uri.host, Keyword.get(opts, :allowed_hosts)),
         :ok <- ensure_public_host(uri.host, opts) do
      {:ok, uri}
    end
  end

  defp ensure_scheme(%URI{scheme: scheme}) when scheme in ["http", "https"], do: :ok

  defp ensure_scheme(_uri) do
    tool_error(:network_policy_denied, "http_get only supports http and https URLs")
  end

  defp ensure_host(%URI{host: host}) when is_binary(host) and host != "", do: :ok

  defp ensure_host(_uri),
    do: tool_error(:network_policy_denied, "http_get URL must include a host")

  defp ensure_no_userinfo(%URI{userinfo: nil}), do: :ok
  defp ensure_no_userinfo(_uri), do: tool_error(:network_policy_denied, "userinfo is not allowed")

  defp ensure_allowed_host(host, nil) do
    tool_error(:network_policy_denied, "allowed_hosts policy is required for http_get",
      host: host
    )
  end

  defp ensure_allowed_host(host, allowed_hosts) when is_list(allowed_hosts) do
    if Enum.any?(allowed_hosts, &host_allowed?(String.downcase(host), String.downcase(&1))) do
      :ok
    else
      tool_error(:network_policy_denied, "host is not in the allowed_hosts policy",
        host: host,
        allowed_hosts: allowed_hosts
      )
    end
  end

  defp ensure_allowed_host(host, _allowed_hosts) do
    tool_error(:network_policy_denied, "invalid allowed_hosts policy", host: host)
  end

  defp host_allowed?(host, "*." <> suffix),
    do: host == suffix or String.ends_with?(host, "." <> suffix)

  defp host_allowed?(host, allowed), do: host == allowed

  defp ensure_public_host(host, opts) do
    if Keyword.get(opts, :allow_private_hosts, false) do
      :ok
    else
      cond do
        private_host_name?(host) ->
          tool_error(:network_policy_denied, "private host names are denied", host: host)

        private_ip_host?(host) ->
          tool_error(:network_policy_denied, "private IP ranges are denied", host: host)

        true ->
          ensure_resolved_public_addresses(host, opts)
      end
    end
  end

  defp private_host_name?(host) do
    host = String.downcase(host)
    host in ["localhost", "localhost.localdomain"] or String.ends_with?(host, ".local")
  end

  defp private_ip_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, tuple} -> private_ip?(tuple)
      {:error, _reason} -> false
    end
  end

  defp ensure_resolved_public_addresses(host, opts) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, _ip} ->
        :ok

      {:error, _reason} ->
        with {:ok, addresses} <- resolve_host(host, opts),
             :ok <- ensure_addresses_present(host, addresses),
             :ok <- ensure_addresses_public(host, addresses) do
          :ok
        end
    end
  end

  defp resolve_host(host, opts) do
    resolver = Keyword.get(opts, :dns_resolver, &default_dns_resolver/1)

    result =
      cond do
        is_function(resolver, 1) -> resolver.(host)
        is_function(resolver, 2) -> resolver.(host, opts)
        true -> {:error, :invalid_dns_resolver}
      end

    case result do
      {:ok, addresses} when is_list(addresses) ->
        {:ok, addresses}

      {:error, reason} ->
        tool_error(:tool_retryable, "DNS resolution failed", host: host, reason: inspect(reason))

      other ->
        tool_error(:tool_non_retryable, "DNS resolver returned an invalid response",
          host: host,
          response: inspect(other)
        )
    end
  rescue
    error ->
      tool_error(:tool_retryable, "DNS resolver raised",
        host: host,
        reason: Exception.message(error)
      )
  end

  defp default_dns_resolver(host) do
    host = String.to_charlist(host)

    addresses =
      [:inet, :inet6]
      |> Enum.flat_map(fn family ->
        case :inet.getaddrs(host, family) do
          {:ok, family_addresses} -> family_addresses
          {:error, _reason} -> []
        end
      end)
      |> Enum.uniq()

    {:ok, addresses}
  end

  defp ensure_addresses_present(host, []),
    do: tool_error(:tool_retryable, "DNS resolution returned no addresses", host: host)

  defp ensure_addresses_present(_host, _addresses), do: :ok

  defp ensure_addresses_public(host, addresses) do
    case Enum.find(addresses, &private_ip?/1) do
      nil ->
        :ok

      address ->
        tool_error(:network_policy_denied, "DNS resolved to a private IP range",
          host: host,
          address: format_ip(address)
        )
    end
  end

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, second, _, _}) when second in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({255, 255, 255, 255}), do: true

  defp private_ip?({a, b, c, d, e, f, g, h}) do
    ip = {a, b, c, d, e, f, g, h}

    ipv6_loopback?(ip) or ipv6_unspecified?(ip) or ipv6_link_local?(a) or
      ipv6_unique_local?(a) or ipv6_multicast?(a)
  end

  defp private_ip?(_ip), do: false

  defp ipv6_loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp ipv6_loopback?(_ip), do: false

  defp ipv6_unspecified?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp ipv6_unspecified?(_ip), do: false

  defp ipv6_link_local?(first), do: (first &&& 0xFFC0) == 0xFE80
  defp ipv6_unique_local?(first), do: (first &&& 0xFE00) == 0xFC00
  defp ipv6_multicast?(first), do: (first &&& 0xFF00) == 0xFF00

  defp format_ip(address) do
    address
    |> :inet.ntoa()
    |> to_string()
  rescue
    _error -> inspect(address)
  end

  defp max_bytes(input, opts) do
    max_bytes =
      Map.get(input, "max_bytes") ||
        Map.get(input, :max_bytes) ||
        Keyword.get(opts, :default_max_bytes, @default_max_bytes)

    hard_max_bytes = Keyword.get(opts, :hard_max_bytes, @hard_max_bytes)

    cond do
      not is_integer(max_bytes) or max_bytes <= 0 ->
        tool_error(:tool_input_invalid, "max_bytes must be a positive integer")

      max_bytes > hard_max_bytes ->
        {:ok, hard_max_bytes}

      true ->
        {:ok, max_bytes}
    end
  end

  defp call_transport(url, uri, max_bytes, opts) do
    transport = Keyword.get(opts, :transport, &default_transport/2)

    request_opts = [
      uri: uri,
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
      max_bytes: max_bytes
    ]

    case transport.(url, request_opts) do
      {:ok, %{status: status, headers: headers, body: body}}
      when is_integer(status) and is_list(headers) and is_binary(body) ->
        {:ok, %{status: status, headers: headers, body: body}}

      {:ok, response} ->
        tool_error(:tool_non_retryable, "transport returned an invalid response",
          response: inspect(response)
        )

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        tool_error(:tool_retryable, "transport failed", reason: inspect(reason))
    end
  end

  defp default_transport(url, opts) do
    with {:ok, _apps} <- Application.ensure_all_started(:inets) do
      timeout_ms = Keyword.fetch!(opts, :timeout_ms)
      request = {String.to_charlist(url), []}
      http_opts = [timeout: timeout_ms, autoredirect: false]
      body_opts = [body_format: :binary]

      case :httpc.request(:get, request, http_opts, body_opts) do
        {:ok, {{_version, status, _reason}, headers, body}} ->
          {:ok, %{status: status, headers: headers, body: body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp ensure_not_redirect(%{status: status}) when status in @redirect_statuses do
    tool_error(:http_redirect_denied, "redirect responses are denied")
  end

  defp ensure_not_redirect(_response), do: :ok

  defp ensure_response_size(%{body: body}, max_bytes) when byte_size(body) <= max_bytes, do: :ok

  defp ensure_response_size(%{body: body}, max_bytes) do
    {:error,
     Error.new(:tool_error, :http_response_too_large, "HTTP response exceeded byte limit",
       retryable: false,
       details: %{bytes: byte_size(body), max_bytes: max_bytes}
     )}
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {key, value} -> [to_string(key), to_string(value)] end)
  end

  defp tool_error(reason, message, details \\ %{}) do
    {:error,
     Error.new(:tool_error, reason, message,
       retryable: reason in [:tool_retryable, :tool_timeout],
       safety_required: reason in [:network_policy_denied, :http_redirect_denied],
       details: Map.new(details)
     )}
  end
end
