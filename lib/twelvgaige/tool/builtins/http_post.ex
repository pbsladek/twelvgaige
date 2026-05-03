defmodule Twelvgaige.Tool.Builtins.HTTPPost do
  @moduledoc """
  Bounded HTTP POST tool with local network policy checks.

  POST is treated as destructive because a generic remote endpoint may create
  work, send notifications, or mutate state. Callers must allow destructive
  tools through the executor and pass `confirm: true` in structured input.
  """

  @behaviour Twelvgaige.Tool

  import Bitwise

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor
  alias Twelvgaige.Tool.Idempotency

  @default_max_body_bytes 64 * 1024
  @default_max_response_bytes 64 * 1024
  @hard_max_bytes 1_048_576
  @redirect_statuses 300..399
  @blocked_input_headers ~w(authorization cookie proxy-authorization x-api-key host connection transfer-encoding content-length)

  @impl true
  def name, do: "http_post"

  @impl true
  def description, do: "Send a bounded HTTP or HTTPS POST body to an allowed host."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "required" => ["url", "body", "confirm"],
      "properties" => %{
        "url" => %{"type" => "string"},
        "body" => %{"type" => "string"},
        "content_type" => %{"type" => "string"},
        "headers" => %{"type" => "object"},
        "max_body_bytes" => %{"type" => "integer"},
        "max_bytes" => %{"type" => "integer"},
        "confirm" => %{"type" => "boolean"}
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def safety_level, do: :destructive

  @impl true
  def idempotency do
    Idempotency.non_idempotent(
      reconciliation_strategy: :manual,
      side_effect_phase: :unknown
    )
  end

  @impl true
  def execute(input, opts) do
    with :ok <- require_confirm(input),
         {:ok, url} <- fetch_url(input),
         {:ok, uri} <- validate_uri(url, opts),
         {:ok, body} <- fetch_body(input),
         {:ok, max_body_bytes} <- max_body_bytes(input, opts),
         :ok <- ensure_body_size(body, max_body_bytes),
         {:ok, max_response_bytes} <- max_response_bytes(input, opts),
         {:ok, content_type} <- content_type(input),
         {:ok, headers} <- request_headers(input, opts),
         {:ok, response} <-
           call_transport(url, uri, body, content_type, headers, max_response_bytes, opts),
         :ok <- ensure_not_redirect(response),
         :ok <- ensure_response_size(response, max_response_bytes) do
      redacted_body = redact_body(response.body)

      {:ok,
       %{
         "url" => url,
         "status" => response.status,
         "headers" => normalize_headers(response.headers),
         "request_bytes" => byte_size(body),
         "bytes" => byte_size(redacted_body),
         "body" => redacted_body
       }}
    end
  end

  defp require_confirm(input) do
    if value(input, "confirm") == true do
      :ok
    else
      {:error,
       Error.new(:policy_error, :policy_denied, "http_post requires explicit confirm=true",
         safety_required: true,
         details: %{tool: name(), required: "confirm=true"}
       )}
    end
  end

  defp fetch_url(input) do
    case value(input, "url") do
      url when is_binary(url) -> {:ok, url}
      _value -> tool_error(:tool_input_invalid, "url must be a string")
    end
  end

  defp fetch_body(input) do
    case value(input, "body") do
      body when is_binary(body) -> {:ok, body}
      _value -> tool_error(:tool_input_invalid, "body must be a string")
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
    tool_error(:network_policy_denied, "http_post only supports http and https URLs")
  end

  defp ensure_host(%URI{host: host}) when is_binary(host) and host != "", do: :ok

  defp ensure_host(_uri),
    do: tool_error(:network_policy_denied, "http_post URL must include a host")

  defp ensure_no_userinfo(%URI{userinfo: nil}), do: :ok
  defp ensure_no_userinfo(_uri), do: tool_error(:network_policy_denied, "userinfo is not allowed")

  defp ensure_allowed_host(host, nil) do
    tool_error(:network_policy_denied, "allowed_hosts policy is required for http_post",
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

  defp max_body_bytes(input, opts) do
    input
    |> value("max_body_bytes")
    |> bounded_bytes(
      Keyword.get(opts, :default_max_body_bytes, @default_max_body_bytes),
      Keyword.get(opts, :hard_max_body_bytes, @hard_max_bytes),
      "max_body_bytes"
    )
  end

  defp max_response_bytes(input, opts) do
    input
    |> value("max_bytes")
    |> bounded_bytes(
      Keyword.get(opts, :default_max_bytes, @default_max_response_bytes),
      Keyword.get(opts, :hard_max_bytes, @hard_max_bytes),
      "max_bytes"
    )
  end

  defp bounded_bytes(nil, default, hard_max, _field), do: {:ok, min(default, hard_max)}

  defp bounded_bytes(value, _default, hard_max, field) do
    cond do
      not is_integer(value) or value <= 0 ->
        tool_error(:tool_input_invalid, "#{field} must be a positive integer")

      value > hard_max ->
        {:ok, hard_max}

      true ->
        {:ok, value}
    end
  end

  defp ensure_body_size(body, max_body_bytes) when byte_size(body) <= max_body_bytes, do: :ok

  defp ensure_body_size(body, max_body_bytes) do
    {:error,
     Error.new(:tool_error, :http_request_too_large, "HTTP POST body exceeded byte limit",
       details: %{bytes: byte_size(body), max_body_bytes: max_body_bytes}
     )}
  end

  defp content_type(input) do
    case value(input, "content_type") do
      nil -> {:ok, "application/json"}
      content_type when is_binary(content_type) and content_type != "" -> {:ok, content_type}
      _value -> tool_error(:tool_input_invalid, "content_type must be a non-empty string")
    end
  end

  defp request_headers(input, opts) do
    with {:ok, input_headers} <- input_headers(value(input, "headers")),
         {:ok, trusted_headers} <- trusted_headers(Keyword.get(opts, :headers, [])) do
      {:ok, trusted_headers ++ input_headers}
    end
  end

  defp input_headers(nil), do: {:ok, []}

  defp input_headers(headers) when is_map(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn {name, value}, {:ok, acc} ->
      name = to_string(name)

      cond do
        blocked_input_header?(name) ->
          {:halt,
           tool_error(:network_policy_denied, "header is not allowed in http_post input",
             header: name
           )}

        is_binary(value) ->
          {:cont, {:ok, [{name, value} | acc]}}

        true ->
          {:halt, tool_error(:tool_input_invalid, "headers values must be strings")}
      end
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      {:error, _error} = error -> error
    end
  end

  defp input_headers(_headers), do: tool_error(:tool_input_invalid, "headers must be an object")

  defp trusted_headers(headers) when is_list(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn
      {name, value}, {:ok, acc} ->
        {:cont, {:ok, [{to_string(name), to_string(value)} | acc]}}

      _other, {:ok, _acc} ->
        {:halt, tool_error(:tool_input_invalid, "trusted headers must be pairs")}
    end)
    |> case do
      {:ok, headers} -> {:ok, Enum.reverse(headers)}
      {:error, _error} = error -> error
    end
  end

  defp trusted_headers(_headers),
    do: tool_error(:tool_input_invalid, "trusted headers must be a list")

  defp blocked_input_header?(name) do
    name
    |> String.downcase()
    |> then(&(&1 in @blocked_input_headers))
  end

  defp call_transport(url, uri, body, content_type, headers, max_bytes, opts) do
    transport = Keyword.get(opts, :transport, &default_transport/2)

    request_opts = [
      method: :post,
      uri: uri,
      timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
      max_bytes: max_bytes,
      headers: headers,
      body: body,
      content_type: content_type
    ]

    case transport.(url, request_opts) do
      {:ok, %{status: status, headers: response_headers, body: response_body}}
      when is_integer(status) and is_list(response_headers) and is_binary(response_body) ->
        {:ok, %{status: status, headers: response_headers, body: response_body}}

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
      headers = opts |> Keyword.fetch!(:headers) |> charlist_headers()
      content_type = opts |> Keyword.fetch!(:content_type) |> String.to_charlist()
      body = Keyword.fetch!(opts, :body)
      request = {String.to_charlist(url), headers, content_type, body}
      http_opts = [timeout: timeout_ms, autoredirect: false]
      body_opts = [body_format: :binary]

      case apply(:httpc, :request, [:post, request, http_opts, body_opts]) do
        {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
          {:ok, %{status: status, headers: response_headers, body: response_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      {String.to_charlist(name), String.to_charlist(value)}
    end)
  end

  defp ensure_not_redirect(%{status: status}) when status in @redirect_statuses do
    tool_error(:http_redirect_denied, "redirect responses are denied")
  end

  defp ensure_not_redirect(_response), do: :ok

  defp ensure_response_size(%{body: body}, max_bytes) when byte_size(body) <= max_bytes, do: :ok

  defp ensure_response_size(%{body: body}, max_bytes) do
    {:error,
     Error.new(:tool_error, :http_response_too_large, "HTTP response exceeded byte limit",
       details: %{bytes: byte_size(body), max_bytes: max_bytes}
     )}
  end

  defp normalize_headers(headers) do
    headers
    |> Enum.map(fn {key, value} -> [to_string(key), Redactor.redact_text(to_string(value))] end)
    |> Redactor.redact_json()
  end

  defp redact_body(body) do
    case Jason.decode(body) do
      {:ok, decoded} ->
        decoded
        |> Redactor.redact_json()
        |> Jason.encode!()

      {:error, _reason} ->
        Redactor.redact_text(body)
    end
  end

  defp value(map, key) do
    case Enum.find(map, fn {map_key, _value} -> key_string(map_key) == key end) do
      {_map_key, value} -> value
      nil -> nil
    end
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: inspect(key)

  defp tool_error(reason, message, details \\ %{}) do
    {:error,
     Error.new(:tool_error, reason, message,
       retryable: reason == :tool_retryable,
       safety_required: reason in [:network_policy_denied, :http_redirect_denied],
       details: Map.new(details)
     )}
  end
end
