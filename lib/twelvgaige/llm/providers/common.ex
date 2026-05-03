defmodule Twelvgaige.LLM.Providers.Common do
  @moduledoc false

  import Bitwise

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor

  @retryable_transport_reasons [
    :closed,
    :econnrefused,
    :ehostunreach,
    :enetunreach,
    :nxdomain,
    :timeout,
    :transport_not_configured
  ]

  @max_timeout_ms 120_000
  @official_hosts %{
    "anthropic" => ["api.anthropic.com"],
    "openai" => ["api.openai.com"],
    "gemini" => ["generativelanguage.googleapis.com"]
  }

  @spec call_transport(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def call_transport(request, opts) do
    with :ok <- validate_request(request, opts) do
      transport = Keyword.get(opts, :transport, &default_transport/1)

      result =
        cond do
          is_function(transport, 1) -> transport.(request)
          is_function(transport, 2) -> transport.(request, opts)
          true -> {:error, :invalid_transport}
        end

      case result do
        {:ok, %{status: status} = response} when is_integer(status) ->
          {:ok, response}

        {:ok, response} ->
          {:error,
           Error.new(:llm_error, :llm_unknown, "provider transport returned invalid response",
             retryable: true,
             details: %{provider: request.provider, response: safe_inspect(response)}
           )}

        {:error, %Error{} = error} ->
          {:error, error}

        {:error, reason} ->
          {:error, transport_error(request.provider, reason)}
      end
    end
  rescue
    error ->
      {:error,
       Error.new(:llm_error, :llm_unknown, "provider transport raised",
         retryable: true,
         details: %{
           provider: request.provider,
           reason: Redactor.redact_text(Exception.message(error))
         }
       )}
  end

  @spec default_transport(map()) :: {:ok, map()} | {:error, term()}
  def default_transport(request) do
    with {:ok, _ssl} <- Application.ensure_all_started(:ssl),
         {:ok, _inets} <- Application.ensure_all_started(:inets),
         {:ok, body} <- encode_body(request.body) do
      headers = charlist_headers(request.headers)

      http_opts =
        [timeout: request.timeout_ms, autoredirect: false] ++ tls_http_options(request.url)

      body_opts = [body_format: :binary]
      http_request = {String.to_charlist(request.url), headers, ~c"application/json", body}

      case apply(:httpc, :request, [:post, http_request, http_opts, body_opts]) do
        {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
          {:ok,
           %{status: status, headers: normalize_headers(response_headers), body: response_body}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec response_body(map()) :: map()
  def response_body(%{body: body}) when is_map(body), do: body

  def response_body(%{body: body}) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      {:ok, decoded} -> %{"raw" => decoded}
      {:error, _error} -> %{"raw" => body}
    end
  end

  def response_body(_response), do: %{}

  @spec ok_status?(map()) :: boolean()
  def ok_status?(%{status: status}), do: status in 200..299

  @spec http_error(String.t(), map()) :: Error.t()
  def http_error(provider, %{status: status} = response) do
    body = response_body(response)
    headers = Map.get(response, :headers, [])
    message = error_message(body)

    {reason, retryable, safety_required} =
      cond do
        status in [401, 403] ->
          {:llm_auth_failed, false, false}

        status in [408, 504] ->
          {:llm_timeout, true, false}

        status == 429 ->
          {:llm_rate_limited, true, false}

        status in [500, 502, 503] ->
          {:llm_provider_unavailable, true, false}

        context_too_large?(body) ->
          {:llm_context_too_large, false, false}

        safety_block?(body) ->
          {:llm_bad_request, false, true}

        status in [400, 404, 422] ->
          {:llm_bad_request, false, false}

        true ->
          {:llm_unknown, true, false}
      end

    Error.new(:llm_error, reason, "#{provider} provider error: #{message}",
      retryable: retryable,
      safety_required: safety_required,
      details: %{
        provider: provider,
        status: status,
        retry_after: retry_after(headers),
        body: Redactor.redact_json(body)
      }
    )
  end

  @spec transport_error(String.t(), term()) :: Error.t()
  def transport_error(provider, reason) do
    normalized =
      case reason do
        :timeout -> :llm_timeout
        {:timeout, _details} -> :llm_timeout
        _other -> :llm_provider_unavailable
      end

    Error.new(:llm_error, normalized, "#{provider} provider transport failed",
      retryable: retryable_transport_reason?(reason),
      details: %{provider: provider, reason: safe_inspect(reason)}
    )
  end

  @spec request(map(), String.t(), String.t(), keyword()) :: map()
  def request(body, provider, default_url, opts) do
    api_key = Keyword.get(opts, :api_key)

    timeout_ms =
      opts
      |> Keyword.get(:timeout_ms, default_timeout_ms(provider))
      |> bounded_timeout_ms(opts)

    %{
      provider: provider,
      method: :post,
      url: Keyword.get(opts, :base_url, default_url),
      headers: request_headers(provider, api_key, opts),
      body: body,
      timeout_ms: timeout_ms
    }
  end

  @spec raw_redacted(map()) :: map()
  def raw_redacted(request) do
    request
    |> Map.take([:provider, :method, :url, :headers, :timeout_ms])
    |> Map.update(:url, nil, &redact_url/1)
    |> Map.update(:headers, [], &redact_headers/1)
  end

  @spec message_content(map()) :: String.t()
  def message_content(message) do
    content = Map.get(message, :content, Map.get(message, "content", ""))

    cond do
      is_binary(content) -> content
      is_list(content) -> content |> Jason.encode!()
      true -> to_string(content)
    end
  end

  @spec message_role(map()) :: String.t()
  def message_role(message) do
    message
    |> Map.get(:role, Map.get(message, "role", "user"))
    |> to_string()
  end

  @spec parse_arguments(term()) :: map()
  def parse_arguments(arguments) when is_map(arguments), do: arguments

  def parse_arguments(arguments) when is_binary(arguments) do
    case Jason.decode(arguments) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _other -> %{}
    end
  end

  def parse_arguments(_arguments), do: %{}

  @spec usage(non_neg_integer() | nil, non_neg_integer() | nil, map()) :: map()
  def usage(input_tokens, output_tokens, extra \\ %{}) do
    input_tokens = input_tokens || 0
    output_tokens = output_tokens || 0

    %{
      input_tokens: input_tokens,
      output_tokens: output_tokens,
      total_tokens: input_tokens + output_tokens
    }
    |> Map.merge(extra)
  end

  defp request_headers("anthropic", api_key, _opts) do
    [
      {"content-type", "application/json"},
      {"user-agent", user_agent()},
      {"anthropic-version", "2023-06-01"}
    ] ++ key_header("x-api-key", api_key)
  end

  defp request_headers("openai", api_key, _opts) do
    [{"content-type", "application/json"}, {"user-agent", user_agent()}] ++ bearer_header(api_key)
  end

  defp request_headers("gemini", api_key, _opts) do
    [{"content-type", "application/json"}, {"user-agent", user_agent()}] ++
      key_header("x-goog-api-key", api_key)
  end

  defp request_headers("ollama", _api_key, _opts) do
    [{"content-type", "application/json"}, {"user-agent", user_agent()}]
  end

  defp user_agent, do: "twelvgaige/#{Twelvgaige.version()}"

  defp encode_body(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, reason} -> {:error, reason}
    end
  end

  defp charlist_headers(headers) do
    headers
    |> Enum.reject(fn {key, _value} -> String.downcase(to_string(key)) == "content-type" end)
    |> Enum.map(fn {key, value} ->
      {String.to_charlist(to_string(key)), String.to_charlist(to_string(value))}
    end)
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp key_header(_key, nil), do: []
  defp key_header(key, value), do: [{key, value}]

  defp bearer_header(nil), do: []
  defp bearer_header(value), do: [{"authorization", "Bearer #{value}"}]

  defp redact_headers(headers) do
    Enum.map(headers, fn {key, value} ->
      if secret_header_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact_header_value(value)}
      end
    end)
  end

  defp secret_header_key?(key) when is_atom(key),
    do: key |> Atom.to_string() |> secret_header_key?()

  defp secret_header_key?(key) when is_binary(key) do
    key = String.downcase(key)

    key in ["authorization", "cookie", "proxy-authorization", "x-api-key", "x-goog-api-key"] or
      String.contains?(key, ["api-key", "apikey", "token", "secret"])
  end

  defp secret_header_key?(_key), do: false

  defp redact_header_value(value) when is_binary(value), do: Redactor.redact_text(value)
  defp redact_header_value(value), do: value

  defp redact_url(url) when is_binary(url), do: Redactor.redact_text(url)
  defp redact_url(url), do: url

  defp safe_inspect(value), do: value |> inspect() |> Redactor.redact_text()

  defp error_message(%{"error" => %{"message" => message}}) when is_binary(message), do: message
  defp error_message(%{"error" => message}) when is_binary(message), do: message
  defp error_message(%{"message" => message}) when is_binary(message), do: message
  defp error_message(%{"raw" => raw}) when is_binary(raw), do: raw
  defp error_message(_body), do: "request failed"

  defp context_too_large?(body) do
    body
    |> error_message()
    |> String.downcase()
    |> String.contains?(["context", "token limit", "maximum context", "too many tokens"])
  end

  defp safety_block?(body) do
    body
    |> error_message()
    |> String.downcase()
    |> String.contains?(["safety", "blocked"])
  end

  defp retry_after(headers) do
    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == "retry-after", do: value

      _other ->
        nil
    end)
  end

  defp retryable_transport_reason?(reason) do
    reason in @retryable_transport_reasons or
      match?({:timeout, _details}, reason)
  end

  defp validate_request(%{provider: provider, url: url, timeout_ms: timeout_ms}, opts)
       when is_binary(provider) and is_binary(url) do
    uri = URI.parse(url)

    with :ok <- validate_timeout(provider, timeout_ms),
         :ok <- ensure_scheme(provider, uri, opts),
         :ok <- ensure_host(provider, uri),
         :ok <- ensure_no_userinfo(provider, uri),
         :ok <- ensure_provider_destination(provider, uri, opts) do
      :ok
    end
  end

  defp validate_request(request, _opts) do
    {:error,
     Error.new(:policy_error, :policy_denied, "provider transport request is invalid",
       details: %{request: inspect(request)}
     )}
  end

  defp validate_timeout(_provider, timeout_ms) when is_integer(timeout_ms) and timeout_ms > 0,
    do: :ok

  defp validate_timeout(provider, timeout_ms) do
    provider_policy_error(provider, "provider timeout must be a positive integer",
      timeout_ms: inspect(timeout_ms)
    )
  end

  defp ensure_scheme("ollama", %URI{scheme: scheme}, _opts)
       when scheme in ["http", "https"] do
    :ok
  end

  defp ensure_scheme(_provider, %URI{scheme: "https"}, _opts), do: :ok

  defp ensure_scheme(provider, %URI{scheme: "http"}, opts) do
    if Keyword.get(opts, :allow_insecure_provider_url, false) do
      :ok
    else
      provider_policy_error(provider, "provider URL must use https", scheme: "http")
    end
  end

  defp ensure_scheme(provider, %URI{scheme: scheme}, _opts) do
    provider_policy_error(provider, "provider URL scheme is not allowed", scheme: inspect(scheme))
  end

  defp ensure_host(_provider, %URI{host: host}) when is_binary(host) and host != "", do: :ok

  defp ensure_host(provider, _uri) do
    provider_policy_error(provider, "provider URL must include a host")
  end

  defp ensure_no_userinfo(_provider, %URI{userinfo: nil}), do: :ok

  defp ensure_no_userinfo(provider, _uri) do
    provider_policy_error(provider, "provider URL must not include userinfo")
  end

  defp ensure_provider_destination("ollama" = provider, %URI{host: host}, opts) do
    if Keyword.get(opts, :allow_remote_provider_url, false) or loopback_host?(host) do
      :ok
    else
      provider_policy_error(provider, "ollama provider URL must be loopback by default",
        host: host
      )
    end
  end

  defp ensure_provider_destination(provider, %URI{host: host}, opts) do
    with :ok <- ensure_cloud_provider_host(provider, host, opts) do
      if Keyword.get(opts, :allow_private_provider_url, false) do
        :ok
      else
        cond do
          private_host?(host) ->
            provider_policy_error(
              provider,
              "cloud provider URL must not target private hosts by default",
              host: host
            )

          true ->
            ensure_resolved_public_addresses(provider, host, opts)
        end
      end
    end
  end

  defp ensure_cloud_provider_host(provider, host, opts) do
    official_hosts = Map.get(@official_hosts, provider, [])

    cond do
      host in official_hosts ->
        :ok

      Keyword.get(opts, :allow_remote_provider_url, false) ->
        :ok

      true ->
        provider_policy_error(
          provider,
          "cloud provider endpoint override requires allow_remote_provider_url",
          host: host,
          official_hosts: official_hosts
        )
    end
  end

  defp provider_policy_error(provider, message, details \\ []) do
    {:error,
     Error.new(:policy_error, :policy_denied, message,
       retryable: false,
       details: details |> Map.new() |> Map.put(:provider, provider)
     )}
  end

  defp bounded_timeout_ms(timeout_ms, opts) do
    max_timeout_ms = Keyword.get(opts, :max_timeout_ms, @max_timeout_ms)
    timeout_ms = if is_integer(timeout_ms), do: timeout_ms, else: default_timeout_ms("default")

    max_timeout_ms =
      if is_integer(max_timeout_ms) and max_timeout_ms > 0,
        do: max_timeout_ms,
        else: @max_timeout_ms

    timeout_ms
    |> max(1)
    |> min(max_timeout_ms)
  end

  defp default_timeout_ms("ollama"), do: 120_000
  defp default_timeout_ms(_provider), do: 30_000

  defp private_host?(host) do
    loopback_host?(host) or private_ip_host?(host) or
      String.ends_with?(String.downcase(host), ".local")
  end

  defp ensure_resolved_public_addresses(provider, host, opts) do
    cond do
      host in Map.get(@official_hosts, provider, []) ->
        :ok

      literal_ip?(host) ->
        :ok

      true ->
        with {:ok, addresses} <- resolve_host(provider, host, opts),
             :ok <- ensure_addresses_present(provider, host, addresses),
             :ok <- ensure_addresses_public(provider, host, addresses) do
          :ok
        end
    end
  end

  defp literal_ip?(host) do
    match?({:ok, _ip}, :inet.parse_address(String.to_charlist(host)))
  end

  defp resolve_host(provider, host, opts) do
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
        provider_policy_error(provider, "provider endpoint DNS resolution failed",
          host: host,
          reason: inspect(reason)
        )

      other ->
        provider_policy_error(
          provider,
          "provider endpoint DNS resolver returned invalid response",
          host: host,
          response: inspect(other)
        )
    end
  rescue
    error ->
      provider_policy_error(provider, "provider endpoint DNS resolver raised",
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

  defp ensure_addresses_present(provider, host, []) do
    provider_policy_error(provider, "provider endpoint DNS resolution returned no addresses",
      host: host
    )
  end

  defp ensure_addresses_present(_provider, _host, _addresses), do: :ok

  defp ensure_addresses_public(provider, host, addresses) do
    case Enum.find(addresses, &private_ip?/1) do
      nil ->
        :ok

      address ->
        provider_policy_error(provider, "provider endpoint resolved to a private IP range",
          host: host,
          address: format_ip(address)
        )
    end
  end

  defp loopback_host?(host) do
    host = String.downcase(host)
    host in ["localhost", "localhost.localdomain"] or host in ["127.0.0.1", "::1", "[::1]"]
  end

  defp private_ip_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} -> private_ip?(ip)
      {:error, _reason} -> false
    end
  end

  defp private_ip?({10, _, _, _}), do: true
  defp private_ip?({127, _, _, _}), do: true
  defp private_ip?({169, 254, _, _}), do: true
  defp private_ip?({172, second, _, _}) when second in 16..31, do: true
  defp private_ip?({192, 168, _, _}), do: true
  defp private_ip?({0, _, _, _}), do: true
  defp private_ip?({255, 255, 255, 255}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp private_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: true
  defp private_ip?({first, _, _, _, _, _, _, _}), do: (first &&& 0xFE00) == 0xFC00
  defp private_ip?(_ip), do: false

  defp format_ip(address) do
    address
    |> :inet.ntoa()
    |> to_string()
  rescue
    _error -> inspect(address)
  end

  defp tls_http_options(url) do
    uri = URI.parse(url)

    if uri.scheme == "https" and is_binary(uri.host) do
      [
        ssl: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          depth: 4,
          server_name_indication: String.to_charlist(uri.host),
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ],
          versions: [:"tlsv1.3", :"tlsv1.2"]
        ]
      ]
    else
      []
    end
  end
end
