defmodule Twelvgaige.LLM.Providers.ProviderAdaptersTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.LLM
  alias Twelvgaige.LLM.Providers.Common
  alias Twelvgaige.LLM.Response

  describe "anthropic adapter" do
    test "serializes normalized messages and normalizes text, tools, and usage" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})

        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "content" => [
               %{"type" => "text", "text" => "checking"},
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "shell_read",
                 "input" => %{"path" => "docs/design/plan.md"}
               }
             ],
             "usage" => %{"input_tokens" => 3, "output_tokens" => 5},
             "stop_reason" => "tool_use"
           }
         }}
      end

      assert {:ok, %Response{} = response} =
               LLM.complete(
                 :anthropic,
                 "claude-test",
                 [
                   %{role: "system", content: "keep control flow deterministic"},
                   %{role: "user", content: "inspect the plan"}
                 ],
                 api_key: "sk-secret",
                 max_tokens: 128,
                 transport: transport
               )

      assert_receive {:request, request}
      assert request.url == "https://api.anthropic.com/v1/messages"
      assert request.body["system"] == "keep control flow deterministic"
      assert request.body["max_tokens"] == 128
      assert [%{"role" => "user", "content" => "inspect the plan"}] = request.body["messages"]

      assert response.provider == "anthropic"
      assert response.content == "checking"
      assert response.finish_reason == "tool_use"
      assert response.usage.total_tokens == 8

      assert response.tool_calls == [
               %{
                 "id" => "toolu_1",
                 "name" => "shell_read",
                 "input" => %{"path" => "docs/design/plan.md"}
               }
             ]

      assert {"x-api-key", "[REDACTED]"} in response.raw_redacted.headers
    end
  end

  describe "openai adapter" do
    test "serializes chat messages and normalizes function tool calls" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})

        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "choices" => [
               %{
                 "message" => %{
                   "content" => "",
                   "tool_calls" => [
                     %{
                       "id" => "call_1",
                       "type" => "function",
                       "function" => %{
                         "name" => "http_get",
                         "arguments" => ~s({"url":"https://example.com/health"})
                       }
                     }
                   ]
                 },
                 "finish_reason" => "tool_calls"
               }
             ],
             "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 2}
           }
         }}
      end

      assert {:ok, response} =
               LLM.complete(
                 "openai",
                 "gpt-test",
                 [
                   %{role: "system", content: "be terse"},
                   %{role: "user", content: "check health"}
                 ],
                 api_key: "sk-secret",
                 transport: transport
               )

      assert_receive {:request, request}
      assert request.url == "https://api.openai.com/v1/chat/completions"
      assert Enum.at(request.body["messages"], 0)["role"] == "system"

      assert response.provider == "openai"
      assert response.finish_reason == "tool_calls"
      assert response.usage.total_tokens == 9

      assert response.tool_calls == [
               %{
                 "id" => "call_1",
                 "name" => "http_get",
                 "input" => %{"url" => "https://example.com/health"}
               }
             ]

      assert {"authorization", "[REDACTED]"} in response.raw_redacted.headers
    end

    test "maps retryable provider errors and redacts error details" do
      transport = fn _request ->
        {:ok,
         %{
           status: 429,
           headers: [{"retry-after", "2"}],
           body: %{
             "error" => %{"message" => "rate limit exceeded"},
             "api_key" => "sk-secret"
           }
         }}
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 api_key: "sk-secret",
                 transport: transport
               )

      assert error.class == :llm_error
      assert error.reason == :llm_rate_limited
      assert error.retryable
      assert error.details.retry_after == "2"
      assert error.details.body["api_key"] == "[REDACTED]"
    end
  end

  describe "provider error classifier" do
    test "maps common HTTP failures into stable reasons" do
      cases = [
        {:anthropic, 401, %{"error" => %{"message" => "bad key"}}, :llm_auth_failed, false},
        {:openai, 408, %{"error" => %{"message" => "timeout"}}, :llm_timeout, true},
        {:gemini, 400, %{"error" => %{"message" => "maximum context exceeded"}},
         :llm_context_too_large, false},
        {:ollama, 503, %{"error" => "service unavailable"}, :llm_provider_unavailable, true},
        {:anthropic, 599, %{"error" => "unexpected"}, :llm_unknown, true}
      ]

      for {provider, status, body, reason, retryable} <- cases do
        transport = fn _request -> {:ok, %{status: status, headers: [], body: body}} end

        assert {:error, error} =
                 LLM.complete(provider, "model", [%{role: "user", content: "hi"}],
                   transport: transport
                 )

        assert error.reason == reason
        assert error.retryable == retryable
      end
    end

    test "maps transport timeouts into retryable timeout errors" do
      transport = fn _request -> {:error, :timeout} end

      assert {:error, error} =
               LLM.complete(:anthropic, "claude-test", [%{role: "user", content: "hi"}],
                 transport: transport
               )

      assert error.reason == :llm_timeout
      assert error.retryable
    end

    test "redacts provider request metadata and transport details" do
      redacted =
        Common.raw_redacted(%{
          provider: "openai",
          method: :post,
          url: "https://api.example.test/v1/chat?api_key=sk-secret",
          headers: [
            {"Authorization", "Bearer sk-secret"},
            {"X-API-Key", "sk-secret"},
            {"cookie", "sid=secret"},
            {"x-safe", "ok"}
          ],
          timeout_ms: 30_000
        })

      assert redacted.url == "https://api.example.test/v1/chat?api_key=[REDACTED]"
      assert {"Authorization", "[REDACTED]"} in redacted.headers
      assert {"X-API-Key", "[REDACTED]"} in redacted.headers
      assert {"cookie", "[REDACTED]"} in redacted.headers
      assert {"x-safe", "ok"} in redacted.headers

      transport = fn _request ->
        {:error, {:failed, "api_key=sk-secret Authorization: Bearer sk-secret"}}
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 api_key: "sk-secret",
                 transport: transport
               )

      assert error.reason == :llm_provider_unavailable
      assert error.details.reason =~ "[REDACTED]"
      refute error.details.reason =~ "sk-secret"
    end

    test "rejects insecure cloud provider URLs before transport" do
      transport = fn _request ->
        flunk("transport should not be called for denied provider URL")
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 base_url: "http://api.openai.com/v1/chat/completions",
                 transport: transport
               )

      assert error.class == :policy_error
      assert error.reason == :policy_denied
      assert error.details.provider == "openai"
    end

    test "rejects cloud provider HTTP downgrades even with insecure override enabled" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})
        {:ok, %{status: 200, headers: [], body: %{}}}
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 api_key: "sk-secret",
                 base_url: "http://api.openai.com/v1/chat/completions",
                 allow_insecure_provider_url: true,
                 transport: transport
               )

      assert error.class == :policy_error
      assert error.reason == :policy_denied
      assert error.message =~ "https"
      refute_receive {:request, _request}
    end

    test "rejects provider URL userinfo before transport" do
      transport = fn _request ->
        flunk("transport should not be called for denied provider URL")
      end

      assert {:error, error} =
               LLM.complete(:anthropic, "claude-test", [%{role: "user", content: "hi"}],
                 base_url: "https://key@example.com/v1/messages",
                 transport: transport
               )

      assert error.class == :policy_error
      assert error.reason == :policy_denied
      assert error.message =~ "userinfo"
    end

    test "requires explicit opt-in for cloud provider endpoint overrides" do
      transport = fn _request ->
        flunk("transport should not be called for denied provider URL")
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 base_url: "https://api.example.com/v1/chat/completions",
                 transport: transport
               )

      assert error.class == :policy_error
      assert error.reason == :policy_denied
      assert error.message =~ "endpoint override"
    end

    test "rejects provider endpoint overrides that resolve to private addresses" do
      transport = fn _request ->
        flunk("transport should not be called for denied provider URL")
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 base_url: "https://api.example.com/v1/chat/completions",
                 allow_remote_provider_url: true,
                 dns_resolver: fn "api.example.com" -> {:ok, [{10, 0, 0, 5}]} end,
                 transport: transport
               )

      assert error.class == :policy_error
      assert error.reason == :policy_denied
      assert error.message =~ "private IP"
    end

    test "rejects provider endpoint overrides when DNS returns no addresses" do
      transport = fn _request ->
        flunk("transport should not be called when DNS resolution has no addresses")
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 base_url: "https://api.example.com/v1/chat/completions",
                 allow_remote_provider_url: true,
                 dns_resolver: fn "api.example.com" -> {:ok, []} end,
                 transport: transport
               )

      assert error.class == :policy_error
      assert error.reason == :policy_denied
      assert error.message =~ "no addresses"
      assert error.details.host == "api.example.com"
    end

    test "rejects provider endpoint overrides when DNS resolver returns invalid data" do
      transport = fn _request ->
        flunk("transport should not be called when DNS resolver returns invalid data")
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 base_url: "https://api.example.com/v1/chat/completions",
                 allow_remote_provider_url: true,
                 dns_resolver: fn "api.example.com" -> :wat end,
                 transport: transport
               )

      assert error.class == :policy_error
      assert error.reason == :policy_denied
      assert error.message =~ "invalid response"
      assert error.details.response == ":wat"
    end

    test "rejects provider endpoint overrides when DNS resolver raises" do
      transport = fn _request ->
        flunk("transport should not be called when DNS resolver raises")
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 base_url: "https://api.example.com/v1/chat/completions",
                 allow_remote_provider_url: true,
                 dns_resolver: fn "api.example.com" -> raise "resolver unavailable" end,
                 transport: transport
               )

      assert error.class == :policy_error
      assert error.reason == :policy_denied
      assert error.message =~ "resolver raised"
      assert error.details.reason == "resolver unavailable"
    end

    test "rejects provider endpoint overrides that resolve to IPv6 link-local addresses" do
      transport = fn _request ->
        flunk("transport should not be called for denied provider URL")
      end

      assert {:error, error} =
               LLM.complete(:gemini, "gemini-test", [%{role: "user", content: "hi"}],
                 base_url:
                   "https://generativelanguage.example.com/v1beta/models/gemini:generateContent",
                 allow_remote_provider_url: true,
                 dns_resolver: fn "generativelanguage.example.com" ->
                   {:ok, [{0xFE80, 0, 0, 0, 0, 0, 0, 1}]}
                 end,
                 transport: transport
               )

      assert error.class == :policy_error
      assert error.reason == :policy_denied
      assert error.message =~ "private IP"
      assert error.details.address == "fe80::1"
    end

    test "does not follow provider redirects through the adapter" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})

        {:ok,
         %{
           status: 302,
           headers: [{"location", "http://169.254.169.254/latest/meta-data"}],
           body: %{"error" => "redirect"}
         }}
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 api_key: "sk-secret",
                 transport: transport
               )

      assert_receive {:request, %{url: "https://api.openai.com/v1/chat/completions"}}
      refute_receive {:request, %{url: "http://169.254.169.254/latest/meta-data"}}
      assert error.reason == :llm_unknown
    end

    test "allows opted-in provider endpoint overrides only after public DNS validation" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})
        {:ok, %{status: 200, headers: [], body: %{"choices" => [%{"message" => %{}}]}}}
      end

      assert {:ok, _response} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 base_url: "https://api.example.com/v1/chat/completions",
                 allow_remote_provider_url: true,
                 dns_resolver: fn "api.example.com" -> {:ok, [{93, 184, 216, 34}]} end,
                 transport: transport
               )

      assert_receive {:request, %{url: "https://api.example.com/v1/chat/completions"}}
    end

    test "clamps provider timeouts before transport" do
      parent = self()

      transport = fn request ->
        send(parent, {:timeout_ms, request.timeout_ms})
        {:ok, %{status: 200, headers: [], body: %{"choices" => [%{"message" => %{}}]}}}
      end

      assert {:ok, _response} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 timeout_ms: 500_000,
                 max_timeout_ms: 60_000,
                 transport: transport
               )

      assert_receive {:timeout_ms, 60_000}
    end

    test "default hosted provider transport uses verified TLS and disables redirects" do
      request =
        Common.request(
          %{"messages" => []},
          "openai",
          "https://api.openai.com/v1/chat/completions",
          timeout_ms: 30_000
        )

      http_opts = Common.default_http_options(request)
      ssl_opts = Keyword.fetch!(http_opts, :ssl)

      assert Keyword.fetch!(http_opts, :timeout) == 30_000
      assert Keyword.fetch!(http_opts, :autoredirect) == false
      assert Keyword.fetch!(ssl_opts, :verify) == :verify_peer
      assert Keyword.fetch!(ssl_opts, :server_name_indication) == ~c"api.openai.com"
      assert Keyword.fetch!(ssl_opts, :versions) == [:"tlsv1.3", :"tlsv1.2"]
      assert Keyword.has_key?(ssl_opts, :cacerts)
      assert Keyword.has_key?(ssl_opts, :customize_hostname_check)
    end
  end

  describe "gemini adapter" do
    test "serializes contents and normalizes function calls" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})

        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "candidates" => [
               %{
                 "content" => %{
                   "parts" => [
                     %{"text" => "state gathered"},
                     %{
                       "functionCall" => %{
                         "name" => "kubectl_get",
                         "args" => %{"resource" => "pods", "namespace" => "default"}
                       }
                     }
                   ]
                 },
                 "finishReason" => "STOP"
               }
             ],
             "usageMetadata" => %{
               "promptTokenCount" => 4,
               "candidatesTokenCount" => 5,
               "totalTokenCount" => 9
             }
           }
         }}
      end

      assert {:ok, response} =
               LLM.complete(
                 :gemini,
                 "gemini-test",
                 [
                   %{role: "system", content: "inspect only"},
                   %{role: "assistant", content: "previous"},
                   %{role: "user", content: "list pods"}
                 ],
                 api_key: "google-secret",
                 transport: transport
               )

      assert_receive {:request, request}
      assert String.ends_with?(request.url, "/gemini-test:generateContent")
      assert request.body["system_instruction"]["parts"] == [%{"text" => "inspect only"}]
      assert Enum.at(request.body["contents"], 0)["role"] == "model"
      assert Enum.at(request.body["contents"], 1)["role"] == "user"

      assert response.provider == "gemini"
      assert response.content == "state gathered"
      assert response.finish_reason == "STOP"
      assert response.usage.total_tokens == 9

      assert response.tool_calls == [
               %{
                 "id" => "function_call_2",
                 "name" => "kubectl_get",
                 "input" => %{"resource" => "pods", "namespace" => "default"}
               }
             ]

      assert {"x-goog-api-key", "[REDACTED]"} in response.raw_redacted.headers
    end

    test "maps safety blocks to safety-required errors" do
      transport = fn _request ->
        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{"candidates" => [%{"finishReason" => "SAFETY"}]}
         }}
      end

      assert {:error, error} =
               LLM.complete(:gemini, "gemini-test", [%{role: "user", content: "hi"}],
                 transport: transport
               )

      assert error.reason == :llm_bad_request
      assert error.safety_required
      refute error.retryable
    end
  end

  describe "ollama adapter" do
    test "targets local chat endpoint and normalizes response usage" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})

        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "message" => %{"content" => "local answer"},
             "done_reason" => "stop",
             "prompt_eval_count" => 11,
             "eval_count" => 13
           }
         }}
      end

      assert {:ok, response} =
               LLM.complete(:ollama, "llama-test", [%{role: "user", content: "hello"}],
                 base_url: "http://127.0.0.1:11434",
                 transport: transport
               )

      assert_receive {:request, request}
      assert request.url == "http://127.0.0.1:11434/api/chat"
      assert request.body["stream"] == false
      assert [%{"role" => "user", "content" => "hello"}] = request.body["messages"]

      assert response.provider == "ollama"
      assert response.content == "local answer"
      assert response.usage.total_tokens == 24
      assert response.finish_reason == "stop"
    end

    test "model-not-found responses are non-retryable bad requests" do
      transport = fn _request ->
        {:ok, %{status: 404, headers: [], body: %{"error" => "model not found"}}}
      end

      assert {:error, error} =
               LLM.complete(:ollama, "missing-model", [%{role: "user", content: "hi"}],
                 transport: transport
               )

      assert error.reason == :llm_bad_request
      refute error.retryable
    end
  end
end
