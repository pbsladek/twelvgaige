defmodule Twelvgaige.LLM.ProviderConfigTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.LLM
  alias Twelvgaige.LLM.ProviderConfig

  @env_names [
    "TWELVGAIGE_OPENAI_API_KEY",
    "OPENAI_API_KEY",
    "TWELVGAIGE_OPENAI_BASE_URL",
    "TWELVGAIGE_GEMINI_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "TWELVGAIGE_OLLAMA_BASE_URL",
    "OLLAMA_HOST"
  ]

  setup do
    previous_config = Application.get_env(:twelvgaige, :llm_providers)
    previous_env = Map.new(@env_names, &{&1, System.get_env(&1)})

    Enum.each(@env_names, &System.delete_env/1)
    Application.delete_env(:twelvgaige, :llm_providers)

    on_exit(fn ->
      restore_config(previous_config)
      Enum.each(previous_env, fn {name, value} -> restore_env(name, value) end)
    end)
  end

  test "uses OpenAI environment API key for provider requests" do
    System.put_env("OPENAI_API_KEY", "sk-env")
    parent = self()

    transport = fn request ->
      send(parent, {:request, request})
      openai_success()
    end

    assert {:ok, response} =
             LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
               transport: transport
             )

    assert response.provider == "openai"
    assert_receive {:request, request}
    assert {"authorization", "Bearer sk-env"} in request.headers
    assert {"authorization", "[REDACTED]"} in response.raw_redacted.headers
  end

  test "app-specific environment variables win over provider-standard names" do
    System.put_env("OPENAI_API_KEY", "sk-standard")
    System.put_env("TWELVGAIGE_OPENAI_API_KEY", "sk-specific")

    opts = ProviderConfig.resolve(:openai, [])

    assert Keyword.fetch!(opts, :api_key) == "sk-specific"
  end

  test "application runtime config wins over environment defaults" do
    System.put_env("OPENAI_API_KEY", "sk-env")

    Application.put_env(:twelvgaige, :llm_providers,
      openai: [
        api_key: "sk-app",
        base_url: "https://api.example.test/v1/chat/completions"
      ]
    )

    opts = ProviderConfig.resolve(:openai, [])

    assert Keyword.fetch!(opts, :api_key) == "sk-app"
    assert Keyword.fetch!(opts, :base_url) == "https://api.example.test/v1/chat/completions"
  end

  test "explicit provider options win over runtime config" do
    Application.put_env(:twelvgaige, :llm_providers, openai: [api_key: "sk-app"])

    opts = ProviderConfig.resolve(:openai, api_key: "sk-explicit")

    assert Keyword.fetch!(opts, :api_key) == "sk-explicit"
  end

  test "Gemini accepts Google API key fallback" do
    System.put_env("GOOGLE_API_KEY", "google-secret")

    opts = ProviderConfig.resolve(:gemini, [])

    assert Keyword.fetch!(opts, :api_key) == "google-secret"
  end

  test "Ollama host resolves as a base URL but no API key is required" do
    System.put_env("OLLAMA_HOST", "http://127.0.0.1:11434")

    opts = ProviderConfig.resolve(:ollama, [])

    assert Keyword.fetch!(opts, :base_url) == "http://127.0.0.1:11434"
    refute Keyword.has_key?(opts, :api_key)
  end

  defp openai_success do
    {:ok,
     %{
       status: 200,
       headers: [],
       body: %{
         "choices" => [
           %{
             "message" => %{"content" => ~s({"ok":true})},
             "finish_reason" => "stop"
           }
         ],
         "usage" => %{"prompt_tokens" => 1, "completion_tokens" => 1}
       }
     }}
  end

  defp restore_config(nil), do: Application.delete_env(:twelvgaige, :llm_providers)
  defp restore_config(config), do: Application.put_env(:twelvgaige, :llm_providers, config)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
