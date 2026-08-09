defmodule Twelvgaige.TestSupport.ProviderContract do
  @moduledoc false

  import ExUnit.Assertions

  alias Twelvgaige.LLM
  alias Twelvgaige.LLM.Response

  @secret "provider-contract-secret"

  def cases do
    [
      %{
        provider: :mock,
        provider_id: "mock",
        model: "mock-contract",
        opts: [
          response: %{
            content: "mock contract answer",
            tool_calls: [
              %{
                "id" => "mock_tool",
                "name" => "shell_read",
                "input" => %{"path" => "docs/design/plan.md"}
              }
            ],
            usage: %{input_tokens: 1, output_tokens: 2, total_tokens: 3},
            finish_reason: "stop"
          }
        ],
        expected_content: "mock contract answer",
        expected_tool_name: "shell_read",
        expected_tokens: 3
      },
      %{
        provider: :openai,
        provider_id: "openai",
        model: "gpt-contract",
        opts: [api_key: @secret],
        success_body: %{
          "choices" => [
            %{
              "message" => %{
                "content" => "openai contract answer",
                "tool_calls" => [
                  %{
                    "id" => "call_contract",
                    "type" => "function",
                    "function" => %{
                      "name" => "http_get",
                      "arguments" => ~s({"url":"https://example.test"})
                    }
                  }
                ]
              },
              "finish_reason" => "tool_calls"
            }
          ],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 6}
        },
        expected_content: "openai contract answer",
        expected_tool_name: "http_get",
        expected_tokens: 11
      },
      %{
        provider: :ollama,
        provider_id: "ollama",
        model: "llama-contract",
        opts: [base_url: "http://127.0.0.1:11434"],
        success_body: %{
          "message" => %{"content" => "ollama contract answer"},
          "done_reason" => "stop",
          "prompt_eval_count" => 9,
          "eval_count" => 10
        },
        expected_content: "ollama contract answer",
        expected_tool_name: nil,
        expected_tokens: 19
      }
    ]
  end

  def assert_capabilities_contract(case_spec) do
    assert {:ok, capabilities} = LLM.capabilities(case_spec.provider)
    assert capabilities.provider == case_spec.provider_id
    assert is_boolean(capabilities.supports_tools)
    assert is_boolean(capabilities.supports_json_schema)
    assert is_boolean(capabilities.supports_system_messages)
    assert is_boolean(capabilities.supports_token_usage)
    assert is_boolean(capabilities.local_runtime)
    assert capabilities.default_timeout_ms > 0
    assert capabilities.default_max_concurrent_calls > 0
  end

  def assert_success_contract(case_spec) do
    parent = self()

    opts =
      case_spec
      |> Map.get(:opts, [])
      |> Keyword.merge(success_transport_opts(case_spec, parent))

    assert {:ok, %Response{} = response} =
             LLM.complete(case_spec.provider, case_spec.model, messages(), opts)

    assert response.provider == case_spec.provider_id
    assert response.model == case_spec.model
    assert response.content == case_spec.expected_content
    assert response.usage.total_tokens == case_spec.expected_tokens
    assert is_map(response.raw_redacted)
    refute inspect(response.raw_redacted) =~ @secret

    if case_spec.expected_tool_name do
      assert [%{"name" => name, "input" => input}] = response.tool_calls
      assert name == case_spec.expected_tool_name
      assert is_map(input)
    else
      assert response.tool_calls == []
    end

    if case_spec.provider != :mock do
      provider = case_spec.provider
      assert_receive {:provider_request, ^provider, request}, 200
      assert request.method == :post
      assert is_binary(request.url)
      assert is_map(request.body)
    end
  end

  def assert_error_contract(case_spec) do
    opts =
      case_spec
      |> Map.get(:opts, [])
      |> Keyword.merge(error_transport_opts(case_spec))

    assert {:error, error} = LLM.complete(case_spec.provider, case_spec.model, messages(), opts)
    assert error.class == :llm_error
    assert error.reason == :llm_rate_limited
    assert error.retryable
    refute inspect(error.details) =~ @secret
  end

  defp success_transport_opts(%{provider: :mock}, _parent), do: []

  defp success_transport_opts(case_spec, parent) do
    [
      transport: fn request ->
        send(parent, {:provider_request, case_spec.provider, request})
        {:ok, %{status: 200, headers: [], body: case_spec.success_body}}
      end
    ]
  end

  defp error_transport_opts(%{provider: :mock}) do
    [error: :llm_rate_limited]
  end

  defp error_transport_opts(_case_spec) do
    [
      transport: fn _request ->
        {:ok,
         %{
           status: 429,
           headers: [{"retry-after", "1"}],
           body: %{"error" => %{"message" => "rate limit"}, "api_key" => @secret}
         }}
      end
    ]
  end

  defp messages do
    [
      %{role: "system", content: "system contract"},
      %{role: "user", content: "user contract"}
    ]
  end
end
