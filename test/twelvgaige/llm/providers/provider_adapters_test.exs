defmodule Twelvgaige.LLM.Providers.ProviderAdaptersTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.LLM
  alias Twelvgaige.LLM.Conversation
  alias Twelvgaige.LLM.Providers.Common

  defmodule RecordingLimiter do
    use GenServer

    def start_link(owner), do: GenServer.start_link(__MODULE__, owner)
    def init(owner), do: {:ok, owner}

    def handle_call({:acquire, provider, account, tokens, cost}, _from, owner) do
      permit = %{
        id: "permit-test",
        provider: provider,
        account: account,
        reserved_tokens: tokens,
        reserved_cost_micros: cost
      }

      {:reply, {:ok, permit}, owner}
    end

    def handle_call({:complete, _permit, _usage}, _from, owner), do: {:reply, :ok, owner}

    def handle_call({:observe_response, _provider, _account, _response} = message, _from, owner) do
      send(owner, {:provider_limiter, message})
      {:reply, :ok, owner}
    end
  end

  test "preserves assistant tool calls and tool result identity for OpenAI" do
    messages = [
      %{role: "user", content: "inspect"},
      %{
        role: "assistant",
        content: "checking",
        tool_calls: [%{id: "call_original", name: "shell_read", input: %{path: "README.md"}}]
      },
      %{
        role: "tool",
        name: "shell_read",
        tool_call_id: "call_original",
        content: ~s({"content":"ok"})
      }
    ]

    parent = self()

    transport = fn request ->
      send(parent, {:request, request.provider, request.body})

      {:ok,
       %{status: 200, headers: [], body: %{"choices" => [%{"message" => %{"content" => "done"}}]}}}
    end

    assert {:ok, _response} =
             LLM.complete(:openai, "test-model", messages,
               transport: transport,
               api_key: "secret"
             )

    assert_receive {:request, "openai", openai}
    openai_assistant = Enum.at(openai["messages"], 1)
    openai_result = Enum.at(openai["messages"], 2)
    assert get_in(openai_assistant, ["tool_calls", Access.at(0), "id"]) == "call_original"
    assert openai_result["tool_call_id"] == "call_original"
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
                 max_tokens: 32,
                 transport: transport
               )

      assert_receive {:request, request}
      assert request.url == "https://api.openai.com/v1/chat/completions"
      assert Enum.at(request.body["messages"], 0)["role"] == "system"
      assert request.body["max_completion_tokens"] == 32
      refute Map.has_key?(request.body, "max_tokens")

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

    test "prefers an explicit Chat Completions token limit" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})

        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{"choices" => [%{"message" => %{"content" => "done"}}]}
         }}
      end

      assert {:ok, _response} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 max_tokens: 32,
                 max_completion_tokens: 64,
                 transport: transport
               )

      assert_receive {:request, request}
      assert request.body["max_completion_tokens"] == 64
      refute Map.has_key?(request.body, "max_tokens")
    end

    test "serializes and normalizes Responses API items" do
      parent = self()

      transport = fn request ->
        send(parent, {:request, request})

        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "id" => "resp_1",
             "status" => "completed",
             "output" => [
               %{"id" => "reasoning_1", "type" => "reasoning", "summary" => []},
               %{
                 "id" => "message_1",
                 "type" => "message",
                 "content" => [
                   %{"type" => "output_text", "text" => ~s({"healthy":true})}
                 ]
               },
               %{
                 "id" => "function_item_1",
                 "type" => "function_call",
                 "call_id" => "call_response_1",
                 "name" => "http_get",
                 "arguments" => ~s({"url":"https://example.com/health"})
               }
             ],
             "usage" => %{"input_tokens" => 11, "output_tokens" => 4}
           }
         }}
      end

      messages = [
        %{role: "system", content: "Return health as JSON."},
        %{role: "user", content: "Check the service."},
        %{
          role: "assistant",
          content: "Checking.",
          tool_calls: [
            %{id: "call_original", name: "http_get", input: %{url: "https://example.com"}}
          ]
        },
        %{
          role: "tool",
          name: "http_get",
          tool_call_id: "call_original",
          content: ~s({"status":200})
        }
      ]

      response_format = %{
        "type" => "json_schema",
        "json_schema" => %{
          "name" => "health",
          "strict" => true,
          "schema" => %{
            "type" => "object",
            "properties" => %{"healthy" => %{"type" => "boolean"}},
            "required" => ["healthy"],
            "additionalProperties" => false
          }
        }
      }

      assert {:ok, response} =
               LLM.complete(:openai, "gpt-test", messages,
                 api: :responses,
                 api_key: "sk-secret",
                 max_tokens: 32,
                 response_format: response_format,
                 tools: [
                   %{
                     name: "http_get",
                     description: "Fetch a URL",
                     input_schema: %{
                       "type" => "object",
                       "properties" => %{"url" => %{"type" => "string"}}
                     }
                   },
                   %{"type" => "web_search"}
                 ],
                 transport: transport
               )

      assert_receive {:request, request}
      assert request.url == "https://api.openai.com/v1/responses"
      assert request.body["model"] == "gpt-test"
      assert request.body["instructions"] == "Return health as JSON."
      assert request.body["max_output_tokens"] == 32
      assert request.body["store"] == false

      assert request.body["input"] == [
               %{"role" => "user", "content" => "Check the service."},
               %{"role" => "assistant", "content" => "Checking."},
               %{
                 "type" => "function_call",
                 "call_id" => "call_original",
                 "name" => "http_get",
                 "arguments" => ~s({"url":"https://example.com"})
               },
               %{
                 "type" => "function_call_output",
                 "call_id" => "call_original",
                 "output" => ~s({"status":200})
               }
             ]

      assert request.body["tools"] ==
               [
                 %{
                   "type" => "function",
                   "name" => "http_get",
                   "description" => "Fetch a URL",
                   "parameters" => %{
                     "type" => "object",
                     "properties" => %{"url" => %{"type" => "string"}}
                   },
                   "strict" => false
                 },
                 %{"type" => "web_search"}
               ]

      assert get_in(request.body, ["text", "format", "type"]) == "json_schema"
      assert get_in(request.body, ["text", "format", "name"]) == "health"
      assert get_in(request.body, ["text", "format", "strict"]) == true
      assert get_in(request.body, ["text", "format", "schema", "type"]) == "object"

      assert response.content == ~s({"healthy":true})
      assert response.finish_reason == "completed"
      assert response.usage.total_tokens == 15
      assert response.provider_response_id == "resp_1"
      assert length(response.provider_items) == 3

      assert response.tool_calls == [
               %{
                 "id" => "call_response_1",
                 "name" => "http_get",
                 "input" => %{"url" => "https://example.com/health"}
               }
             ]

      replay_transport = fn replay_request ->
        send(parent, {:replay_request, replay_request})

        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{"id" => "resp_2", "status" => "completed", "output" => [], "usage" => %{}}
         }}
      end

      assert {:ok, replay_response} =
               LLM.complete(
                 :openai,
                 "gpt-test",
                 [
                   %{role: "user", content: "Check the service."},
                   Conversation.assistant(response),
                   Conversation.tool_result(
                     "call_response_1",
                     "http_get",
                     ~s({"status":200})
                   )
                 ],
                 api: :responses,
                 transport: replay_transport
               )

      assert replay_response.provider_response_id == "resp_2"
      assert_receive {:replay_request, replay_request}

      assert replay_request.body["input"] ==
               [%{"role" => "user", "content" => "Check the service."}] ++
                 response.provider_items ++
                 [
                   %{
                     "type" => "function_call_output",
                     "call_id" => "call_response_1",
                     "output" => ~s({"status":200})
                   }
                 ]
    end

    test "rejects unknown OpenAI API selections before transport" do
      transport = fn _request -> flunk("transport must not run for an invalid API selection") end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 api: :unknown,
                 transport: transport
               )

      assert error.reason == :llm_bad_request
      assert error.message =~ "responses or chat_completions"
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

    test "fails closed when a provider reports incomplete output" do
      cases = [
        {:responses,
         %{
           "id" => "resp_incomplete",
           "status" => "incomplete",
           "incomplete_details" => %{"reason" => "max_output_tokens"},
           "output" => []
         }},
        {:chat_completions,
         %{
           "choices" => [
             %{"message" => %{"content" => "partial"}, "finish_reason" => "length"}
           ]
         }}
      ]

      for {api, body} <- cases do
        transport = fn _request -> {:ok, %{status: 200, headers: [], body: body}} end

        assert {:error, error} =
                 LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                   api: api,
                   transport: transport
                 )

        assert error.reason == :llm_incomplete
        refute error.retryable
      end
    end

    test "preserves a refusal as an explicit safety error" do
      transport = fn _request ->
        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "id" => "resp_refusal",
             "status" => "completed",
             "output" => [
               %{
                 "type" => "message",
                 "content" => [%{"type" => "refusal", "refusal" => "cannot comply"}]
               }
             ]
           }
         }}
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 api: :responses,
                 transport: transport
               )

      assert error.reason == :llm_bad_request
      assert error.safety_required
    end

    test "rejects malformed function arguments instead of converting them to an empty map" do
      transport = fn _request ->
        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "choices" => [
               %{
                 "finish_reason" => "tool_calls",
                 "message" => %{
                   "tool_calls" => [
                     %{
                       "id" => "call_bad",
                       "function" => %{"name" => "lookup", "arguments" => "{broken"}
                     }
                   ]
                 }
               }
             ]
           }
         }}
      end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 transport: transport
               )

      assert error.class == :output_error
      assert error.reason == :output_parse_error
      assert error.details.tool_call_id == "call_bad"
      refute Map.has_key?(error.details, :arguments)
    end
  end

  describe "provider error classifier" do
    test "maps common HTTP failures into stable reasons" do
      cases = [
        {:openai, 401, %{"error" => %{"message" => "bad key"}}, :llm_auth_failed, false},
        {:openai, 408, %{"error" => %{"message" => "timeout"}}, :llm_timeout, true},
        {:openai, 400, %{"error" => %{"message" => "maximum context exceeded"}},
         :llm_context_too_large, false},
        {:ollama, 503, %{"error" => "service unavailable"}, :llm_provider_unavailable, true},
        {:openai, 599, %{"error" => "unexpected"}, :llm_unknown, true}
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

    test "distinguishes exhausted quota from retryable request rate limits" do
      limiter = start_supervised!({RecordingLimiter, self()})

      for code <- [
            "credit_balance_exhausted",
            "insufficient_quota",
            "organization_spend_limit_exceeded",
            "project_spend_limit_exceeded",
            "organization_usage_limit_exceeded"
          ] do
        transport = fn _request ->
          {:ok,
           %{
             status: 429,
             headers: [{"retry-after", "1"}],
             body: %{"error" => %{"code" => code, "message" => "quota exhausted"}}
           }}
        end

        assert {:error, error} =
                 LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                   provider_limiter: limiter,
                   transport: transport
                 )

        assert error.reason == :llm_quota_exhausted
        refute error.retryable
        assert error.details.provider_code == code
        refute_receive {:provider_limiter, _message}
      end

      rate_limit_transport = fn _request ->
        {:ok,
         %{
           status: 429,
           headers: [{"retry-after", "1"}],
           body: %{"error" => %{"code" => "rate_limit_exceeded", "message" => "slow down"}}
         }}
      end

      assert {:error, %{reason: :llm_rate_limited, retryable: true}} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 provider_limiter: limiter,
                 transport: rate_limit_transport
               )

      assert_receive {:provider_limiter, {:observe_response, "openai", "default", %{status: 429}}}
    end

    test "maps transport timeouts into retryable timeout errors" do
      transport = fn _request -> {:error, :timeout} end

      assert {:error, error} =
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
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
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 base_url: "https://key@example.com/v1/chat/completions",
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
               LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
                 base_url: "https://api.example.com/v1/chat/completions",
                 allow_remote_provider_url: true,
                 dns_resolver: fn "api.example.com" ->
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

    test "rejects malformed native tool arguments" do
      transport = fn _request ->
        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "message" => %{
               "tool_calls" => [
                 %{"id" => "call_bad", "function" => %{"name" => "lookup", "arguments" => []}}
               ]
             }
           }
         }}
      end

      assert {:error, error} =
               LLM.complete(:ollama, "llama-test", [%{role: "user", content: "hello"}],
                 transport: transport
               )

      assert error.class == :output_error
      assert error.reason == :output_parse_error
      assert error.details.tool_call_id == "call_bad"
    end
  end
end
