defmodule Twelvgaige.LLM.ProviderLiveTest do
  use ExUnit.Case, async: false

  @moduletag :provider_live

  alias Twelvgaige.LLM
  alias Twelvgaige.LLM.Response

  @providers ["openai", "ollama"]

  test "selected live providers complete a minimal prompt" do
    assert System.get_env("TWELVGAIGE_PROVIDER_LIVE") == "1",
           "set TWELVGAIGE_PROVIDER_LIVE=1 to run live provider tests"

    providers = selected_providers()

    assert providers != [],
           "set TWELVGAIGE_PROVIDER_LIVE_PROVIDERS or configure at least one provider key/base URL and model"

    for provider <- providers do
      model = fetch_model!(provider)
      ensure_credentials!(provider)

      assert {:ok, %Response{} = response} =
               LLM.complete(
                 provider,
                 model,
                 [
                   %{role: "system", content: "Answer with the exact requested token."},
                   %{role: "user", content: "Reply with only: twelvgaige-live-ok"}
                 ],
                 live_opts(provider)
               )

      assert response.provider == provider
      assert response.model == model
      assert String.contains?(String.downcase(response.content), "twelvgaige-live-ok")
    end
  end

  defp selected_providers do
    case split_env("TWELVGAIGE_PROVIDER_LIVE_PROVIDERS") do
      [] ->
        Enum.filter(@providers, &provider_configured?/1)

      providers ->
        Enum.each(providers, fn provider ->
          unless provider in @providers do
            flunk("unknown live provider #{inspect(provider)}")
          end
        end)

        providers
    end
  end

  defp provider_configured?(provider) do
    model_env(provider) |> env_present?() and
      (provider == "ollama" or hosted_key_present?(provider))
  end

  defp fetch_model!(provider) do
    env_name = model_env(provider)

    case System.get_env(env_name) do
      value when is_binary(value) and value != "" ->
        value

      _missing ->
        flunk("set #{env_name} to run live #{provider} provider tests")
    end
  end

  defp ensure_credentials!("ollama") do
    unless env_present?("TWELVGAIGE_OLLAMA_BASE_URL") or env_present?("OLLAMA_HOST") do
      flunk("set TWELVGAIGE_OLLAMA_BASE_URL or OLLAMA_HOST to run live ollama provider tests")
    end
  end

  defp ensure_credentials!(provider) do
    unless hosted_key_present?(provider) do
      flunk("set a live API key env for #{provider}: #{Enum.join(key_envs(provider), ", ")}")
    end
  end

  defp live_opts("ollama") do
    [
      timeout_ms: timeout_ms(),
      options: %{"num_predict" => 16}
    ]
  end

  defp live_opts(_provider), do: [timeout_ms: timeout_ms(), max_tokens: 16]

  defp timeout_ms do
    case System.get_env("TWELVGAIGE_PROVIDER_LIVE_TIMEOUT_MS") do
      nil ->
        60_000

      value ->
        case Integer.parse(value) do
          {timeout_ms, ""} when timeout_ms > 0 -> timeout_ms
          _invalid -> 60_000
        end
    end
  end

  defp hosted_key_present?(provider), do: Enum.any?(key_envs(provider), &env_present?/1)

  defp key_envs("openai"), do: ["TWELVGAIGE_OPENAI_API_KEY", "OPENAI_API_KEY"]

  defp model_env(provider) do
    provider
    |> String.upcase()
    |> then(&"TWELVGAIGE_#{&1}_LIVE_MODEL")
  end

  defp split_env(name) do
    name
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp env_present?(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> true
      _missing -> false
    end
  end
end
