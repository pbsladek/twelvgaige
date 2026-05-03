defmodule Twelvgaige.API.Webhook do
  @moduledoc """
  Webhook trigger verification and config normalization.
  """

  alias Twelvgaige.API.WebhookReplayCache
  alias Twelvgaige.Error
  alias Twelvgaige.Security

  @default_signature_header "x-twelvgaige-signature"
  @default_timestamp_header "x-twelvgaige-timestamp"
  @default_nonce_header "x-twelvgaige-nonce"
  @default_tolerance_seconds 300

  @type config :: map()

  @spec fetch_config(String.t(), keyword()) :: {:ok, config()} | {:error, :not_found}
  def fetch_config(webhook_id, opts) do
    opts
    |> Keyword.get(:webhooks, %{})
    |> normalize_config_collection()
    |> Map.fetch(webhook_id)
    |> case do
      {:ok, config} -> {:ok, config}
      :error -> {:error, :not_found}
    end
  end

  @spec verify(String.t(), config(), String.t(), keyword()) :: :ok | {:error, term()}
  def verify(webhook_id, config, body, opts) do
    config = normalize_config(config)

    with {:ok, secret} <- webhook_secret(config),
         headers <- normalize_headers(Keyword.get(opts, :headers, [])),
         {:ok, timestamp} <- timestamp(headers, config),
         {:ok, nonce} <- nonce(headers, config),
         :ok <- ensure_fresh(timestamp, config, opts),
         :ok <- verify_signature(headers, config, secret, timestamp, nonce, body),
         :ok <- reserve_nonce(webhook_id, nonce, config, opts) do
      :ok
    end
  end

  @spec workflow(config()) :: String.t() | map() | nil
  def workflow(config) do
    config = normalize_config(config)
    Map.get(config, :workflow, Map.get(config, :workflow_path))
  end

  @spec round_input(map(), config()) :: map()
  def round_input(payload, config) when is_map(payload) do
    case Map.get(normalize_config(config), :input) do
      :input_field ->
        Map.get(payload, "input", Map.get(payload, :input, %{}))

      _default ->
        payload
    end
  end

  @spec round_opts(config(), keyword()) :: keyword()
  def round_opts(config, opts) do
    config = normalize_config(config)

    [server: Keyword.get(opts, :server)]
    |> maybe_put(:round_id, Map.get(config, :round_id))
    |> Keyword.merge(Map.get(config, :opts, []))
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp normalize_config_collection(configs) when is_map(configs) do
    Map.new(configs, fn {id, config} -> {to_string(id), normalize_config(config)} end)
  end

  defp normalize_config_collection(configs) when is_list(configs) do
    Map.new(configs, fn config ->
      config = normalize_config(config)
      {to_string(Map.fetch!(config, :id)), config}
    end)
  end

  defp normalize_config_collection(_configs), do: %{}

  defp normalize_config(config) when is_list(config),
    do: config |> Map.new() |> normalize_config()

  defp normalize_config(%{} = config) do
    Map.new(config, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_config(_config), do: %{}

  defp webhook_secret(config) do
    case Map.get(config, :secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _missing -> {:error, webhook_error("webhook secret is required")}
    end
  end

  defp timestamp(headers, config) do
    header = Map.get(config, :timestamp_header, @default_timestamp_header)

    with {:ok, raw} <- required_header(headers, header),
         {timestamp, ""} <- Integer.parse(raw) do
      {:ok, timestamp}
    else
      {:error, _error} = error -> error
      _invalid -> {:error, webhook_error("webhook timestamp is invalid")}
    end
  end

  defp nonce(headers, config) do
    header = Map.get(config, :nonce_header, @default_nonce_header)
    required_header(headers, header)
  end

  defp required_header(headers, name) do
    case Map.get(headers, String.downcase(name)) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, webhook_error("required webhook header is missing", header: name)}
    end
  end

  defp ensure_fresh(timestamp, config, opts) do
    now = Keyword.get(opts, :now_unix, System.system_time(:second))
    tolerance = Map.get(config, :tolerance_seconds, @default_tolerance_seconds)

    if abs(now - timestamp) <= tolerance do
      :ok
    else
      {:error, webhook_error("webhook timestamp is outside the replay window")}
    end
  end

  defp verify_signature(headers, config, secret, timestamp, nonce, body) do
    signature_header = Map.get(config, :signature_header, @default_signature_header)

    with {:ok, signature} <- required_header(headers, signature_header),
         {:ok, expected} <- signature(secret, timestamp, nonce, body),
         :ok <- compare_signature(signature, expected) do
      :ok
    end
  end

  defp signature(secret, timestamp, nonce, body) do
    payload = "#{timestamp}.#{nonce}.#{body}"
    digest = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
    {:ok, "sha256=#{digest}"}
  end

  defp compare_signature(left, right) do
    if secure_equal?(left, right) do
      :ok
    else
      {:error, webhook_error("webhook signature verification failed")}
    end
  end

  defp reserve_nonce(webhook_id, nonce, config, opts) do
    ttl_ms = Map.get(config, :replay_ttl_ms, @default_tolerance_seconds * 1_000)
    server = Keyword.get(opts, :webhook_replay_cache, WebhookReplayCache)

    case WebhookReplayCache.reserve(server, "#{webhook_id}:#{nonce}", ttl_ms) do
      :ok -> :ok
      {:error, :replay_detected} -> {:error, webhook_error("webhook replay detected")}
    end
  rescue
    _error -> {:error, webhook_error("webhook replay cache unavailable")}
  end

  defp webhook_error(message, details \\ []) do
    Error.new(:policy_error, :policy_denied, message,
      retryable: false,
      details: Map.new(details)
    )
  end

  defp normalize_headers(headers) when is_map(headers) do
    Map.new(headers, fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  defp normalize_headers(headers) when is_list(headers) do
    headers
    |> Enum.filter(&match?({_key, _value}, &1))
    |> Map.new(fn {key, value} -> {String.downcase(to_string(key)), to_string(value)} end)
  end

  defp normalize_headers(_headers), do: %{}

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    Security.secure_equal?(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key("id"), do: :id
  defp normalize_key("workflow"), do: :workflow
  defp normalize_key("workflow_path"), do: :workflow_path
  defp normalize_key("secret"), do: :secret
  defp normalize_key("signature_header"), do: :signature_header
  defp normalize_key("timestamp_header"), do: :timestamp_header
  defp normalize_key("nonce_header"), do: :nonce_header
  defp normalize_key("tolerance_seconds"), do: :tolerance_seconds
  defp normalize_key("replay_ttl_ms"), do: :replay_ttl_ms
  defp normalize_key("input"), do: :input
  defp normalize_key("round_id"), do: :round_id
  defp normalize_key("opts"), do: :opts
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: key

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
