defmodule Twelvgaige.LLM.ProviderConfig do
  @moduledoc """
  Resolves trusted runtime configuration for LLM providers.

  Workflow and agent shells select provider IDs and models. They do not carry
  credential material or provider transport overrides. Secrets and endpoint
  overrides come from process options, application config, or environment
  variables owned by the operator.
  """

  @app :twelvgaige
  @config_key :llm_providers

  @api_key_envs %{
    "openai" => ["TWELVGAIGE_OPENAI_API_KEY", "OPENAI_API_KEY"],
    "ollama" => []
  }

  @base_url_envs %{
    "openai" => ["TWELVGAIGE_OPENAI_BASE_URL"],
    "ollama" => ["TWELVGAIGE_OLLAMA_BASE_URL", "OLLAMA_HOST"]
  }

  @api_envs %{
    "openai" => ["TWELVGAIGE_OPENAI_API"]
  }

  @spec resolve(String.t() | atom(), keyword()) :: keyword()
  def resolve(provider, opts) when is_list(opts) do
    provider = normalize_provider(provider)

    opts
    |> merge_runtime_config(provider)
    |> maybe_put_env(:api_key, Map.get(@api_key_envs, provider, []))
    |> maybe_put_env(:base_url, Map.get(@base_url_envs, provider, []))
    |> maybe_put_env(:api, Map.get(@api_envs, provider, []))
  end

  defp merge_runtime_config(opts, provider) do
    runtime_config =
      @app
      |> Application.get_env(@config_key, [])
      |> provider_config(provider)
      |> normalize_config()

    Keyword.merge(runtime_config, opts)
  end

  defp provider_config(config, provider) when is_map(config) do
    Enum.find_value(config, %{}, fn
      {key, value} when is_binary(key) -> if key == provider, do: value
      {key, value} when is_atom(key) -> if Atom.to_string(key) == provider, do: value
      _other -> nil
    end)
  end

  defp provider_config(config, provider) when is_list(config) do
    Enum.find_value(config, [], fn
      {key, value} when is_binary(key) -> if key == provider, do: value
      {key, value} when is_atom(key) -> if Atom.to_string(key) == provider, do: value
      _other -> nil
    end)
  end

  defp provider_config(_config, _provider), do: []

  defp normalize_config(config) when is_list(config), do: config

  defp normalize_config(config) when is_map(config) do
    Enum.map(config, fn
      {key, value} when is_binary(key) -> {normalize_key(key), value}
      {key, value} -> {key, value}
    end)
    |> Enum.reject(fn {key, _value} -> is_nil(key) end)
  end

  defp normalize_config(_config), do: []

  defp normalize_key("api_key"), do: :api_key
  defp normalize_key("base_url"), do: :base_url
  defp normalize_key("api"), do: :api
  defp normalize_key("store"), do: :store
  defp normalize_key("max_tokens"), do: :max_tokens
  defp normalize_key("max_completion_tokens"), do: :max_completion_tokens
  defp normalize_key("timeout_ms"), do: :timeout_ms
  defp normalize_key("max_timeout_ms"), do: :max_timeout_ms
  defp normalize_key("allow_insecure_provider_url"), do: :allow_insecure_provider_url
  defp normalize_key("allow_private_provider_url"), do: :allow_private_provider_url
  defp normalize_key("allow_remote_provider_url"), do: :allow_remote_provider_url
  defp normalize_key(_key), do: nil

  defp maybe_put_env(opts, key, env_names) do
    if present?(Keyword.get(opts, key)) do
      opts
    else
      case first_env(env_names) do
        nil -> opts
        value -> Keyword.put(opts, key, value)
      end
    end
  end

  defp first_env(env_names) do
    Enum.find_value(env_names, fn name ->
      case System.get_env(name) do
        value when is_binary(value) and value != "" -> value
        _missing -> nil
      end
    end)
  end

  defp present?(value) when is_binary(value), do: value != ""
  defp present?(nil), do: false
  defp present?(_value), do: true

  defp normalize_provider(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp normalize_provider(provider), do: to_string(provider)
end
