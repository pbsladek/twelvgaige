defmodule Twelvgaige.LLM.ProviderLiveTest do
  use ExUnit.Case, async: false

  @moduletag :provider_live

  alias Twelvgaige.LLM
  alias Twelvgaige.LLM.Conversation
  alias Twelvgaige.LLM.Response

  @providers ["openai", "ollama"]
  @openai_apis [:responses, :chat_completions]

  test "selected live providers satisfy their supported contracts" do
    assert System.get_env("TWELVGAIGE_PROVIDER_LIVE") == "1",
           "set TWELVGAIGE_PROVIDER_LIVE=1 to run live provider tests"

    providers = selected_providers()

    assert providers != [],
           "set TWELVGAIGE_PROVIDER_LIVE_PROVIDERS or configure at least one provider key/base URL and model"

    for provider <- providers do
      model = fetch_model!(provider)
      ensure_credentials!(provider)

      case provider do
        "openai" -> Enum.each(selected_openai_apis(), &assert_openai_contracts!(model, &1))
        "ollama" -> assert_plain_text!(provider, model, live_opts(provider))
      end
    end
  end

  defp assert_openai_contracts!(model, api) do
    opts = live_opts("openai") ++ [api: api]
    assert_plain_text!("openai", model, opts)
    assert_structured_output!(model, opts)
    assert_tool_continuation!(model, api, opts)
  end

  defp assert_plain_text!(provider, model, opts) do
    assert {:ok, %Response{} = response} =
             LLM.complete(
               provider,
               model,
               [
                 %{role: "system", content: "Answer with the exact requested token."},
                 %{role: "user", content: "Reply with only: twelvgaige-live-ok"}
               ],
               opts
             )

    assert response.provider == provider
    assert response.model == model
    assert String.trim(response.content) == "twelvgaige-live-ok"
  end

  defp assert_structured_output!(model, opts) do
    response_format = %{
      "type" => "json_schema",
      "json_schema" => %{
        "name" => "twelvgaige_live_contract",
        "strict" => true,
        "schema" => %{
          "type" => "object",
          "properties" => %{"status" => %{"type" => "string", "const" => "ok"}},
          "required" => ["status"],
          "additionalProperties" => false
        }
      }
    }

    assert {:ok, %Response{} = response} =
             LLM.complete(
               :openai,
               model,
               [%{role: "user", content: "Return the requested status object."}],
               opts ++ [response_format: response_format]
             )

    assert {:ok, %{"status" => "ok"}} = Jason.decode(response.content)
  end

  defp assert_tool_continuation!(model, api, opts) do
    tool = %{
      name: "lookup_test_value",
      description: "Look up one deterministic test value",
      strict: true,
      input_schema: %{
        "type" => "object",
        "properties" => %{"key" => %{"type" => "string", "const" => "alpha"}},
        "required" => ["key"],
        "additionalProperties" => false
      }
    }

    messages = [
      %{
        role: "system",
        content:
          "Call lookup_test_value once with key alpha. After its result, reply with only the returned value."
      },
      %{role: "user", content: "Look up alpha."}
    ]

    assert {:ok, %Response{} = first} =
             LLM.complete(
               :openai,
               model,
               messages,
               opts ++ [tools: [tool], tool_choice: forced_tool_choice(api)]
             )

    assert [%{"id" => call_id, "name" => "lookup_test_value", "input" => %{"key" => "alpha"}}] =
             first.tool_calls

    continuation =
      messages ++
        [
          Conversation.assistant(first),
          Conversation.tool_result(
            call_id,
            "lookup_test_value",
            "twelvgaige-tool-ok"
          )
        ]

    assert {:ok, %Response{} = final} =
             LLM.complete(
               :openai,
               model,
               continuation,
               opts ++ [tools: [tool]]
             )

    assert String.trim(final.content) == "twelvgaige-tool-ok"
    assert final.tool_calls == []
  end

  defp forced_tool_choice(:responses),
    do: %{"type" => "function", "name" => "lookup_test_value"}

  defp forced_tool_choice(:chat_completions),
    do: %{"type" => "function", "function" => %{"name" => "lookup_test_value"}}

  defp selected_openai_apis do
    case split_env("TWELVGAIGE_OPENAI_LIVE_APIS") do
      [] ->
        @openai_apis

      values ->
        Enum.map(values, fn
          "responses" -> :responses
          "chat_completions" -> :chat_completions
          value -> flunk("unknown OpenAI live API #{inspect(value)}")
        end)
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
    [timeout_ms: timeout_ms(), options: %{"num_predict" => 32}]
  end

  # OpenAI reasoning models count reasoning tokens against the output limit, so
  # a tiny limit can produce an incomplete response with no visible text.
  defp live_opts("openai"), do: [timeout_ms: timeout_ms(), max_tokens: 512]

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
