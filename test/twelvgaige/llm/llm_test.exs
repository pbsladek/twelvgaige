defmodule Twelvgaige.LLMTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.LLM
  alias Twelvgaige.LLM.Capabilities
  alias Twelvgaige.LLM.Response
  alias Twelvgaige.ResourceLimiter

  test "routes to mock provider by explicit provider id" do
    assert {:ok, %Response{} = response} =
             LLM.complete("mock", "mock-model", [%{role: "user", content: "hello"}])

    assert response.provider == "mock"
    assert response.model == "mock-model"
    assert response.content == "mock response: hello"
  end

  test "mock provider can return configured response content" do
    assert {:ok, response} =
             LLM.complete(:mock, "mock-model", [], response: %{content: "configured"})

    assert response.content == "configured"
  end

  test "mock provider can return configured errors" do
    assert {:error, error} = LLM.complete(:mock, "mock-model", [], error: :llm_timeout)

    assert error.class == :llm_error
    assert error.reason == :llm_timeout
    assert error.retryable
  end

  test "unknown provider returns normalized error" do
    assert {:error, error} = LLM.complete("not-a-provider", "model", [])

    assert error.class == :llm_error
    assert error.reason == :llm_bad_request
    refute error.retryable
  end

  test "first-class provider ids are routable" do
    for provider <- ["mock", "openai", "ollama"] do
      assert LLM.known_provider?(provider)
    end
  end

  test "capabilities are available for mock provider" do
    assert {:ok, %Capabilities{} = capabilities} = LLM.capabilities(:mock)

    assert capabilities.provider == "mock"
    assert capabilities.supports_tools
    assert capabilities.supports_token_usage
  end

  test "provider capability check rejects unsupported native tool mode before transport" do
    transport = fn _request ->
      flunk("transport should not be called when provider capabilities reject the request")
    end

    assert {:error, error} =
             LLM.complete(:ollama, "llama-test", [%{role: "user", content: "hi"}],
               tools: [%{"type" => "function"}],
               transport: transport
             )

    assert error.class == :policy_error
    assert error.reason == :policy_denied
    refute error.retryable
    assert error.details == %{provider: "ollama", capability: :tools}
  end

  test "provider capability check rejects unsupported native JSON schema mode before transport" do
    transport = fn _request ->
      flunk("transport should not be called when provider capabilities reject the request")
    end

    assert {:error, error} =
             LLM.complete(:ollama, "llama-test", [%{role: "user", content: "hi"}],
               response_format: %{"type" => "json_schema"},
               transport: transport
             )

    assert error.class == :policy_error
    assert error.reason == :policy_denied
    assert error.details == %{provider: "ollama", capability: :json_schema}
  end

  test "provider capability check allows supported native JSON schema mode" do
    transport = fn _request ->
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
           "usage" => %{}
         }
       }}
    end

    assert {:ok, response} =
             LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
               response_format: %{"type" => "json_schema"},
               transport: transport
             )

    assert response.provider == "openai"
    assert response.content == ~s({"ok":true})
  end

  test "optionally bounds provider calls with the resource limiter" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{llm_call: 1}})

    assert {:ok, response} =
             LLM.complete(:mock, "mock-model", [%{role: "user", content: "hi"}],
               limiter: limiter,
               limiter_context: %{round_id: "round_1", shot_id: "shot_1", attempt: 1}
             )

    assert response.content == "mock response: hi"
    assert ResourceLimiter.snapshot(limiter).used.llm_call == 0
  end

  test "returns a retryable queue timeout when provider call permits are saturated" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{llm_call: 1}})
    assert {:ok, permit} = ResourceLimiter.acquire(:llm_call, %{}, server: limiter)

    assert {:error, error} =
             LLM.complete(:mock, "mock-model", [%{role: "user", content: "hi"}], limiter: limiter)

    assert error.class == :timeout_error
    assert error.reason == :resource_queue_timeout
    assert error.retryable
    assert error.details.provider == "mock"
    assert :ok = ResourceLimiter.release(permit)
  end

  test "an in-flight provider result survives limiter restart during permit cleanup" do
    {:ok, limiter} = ResourceLimiter.start_link(name: nil, limits: %{llm_call: 1})
    owner = self()

    transport = fn _request ->
      send(owner, {:transport_waiting, self()})

      receive do
        :complete_transport ->
          {:ok,
           %{
             status: 200,
             headers: [],
             body: %{
               "choices" => [
                 %{
                   "message" => %{"content" => "completed"},
                   "finish_reason" => "stop"
                 }
               ],
               "usage" => %{}
             }
           }}
      end
    end

    task =
      Task.async(fn ->
        LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hi"}],
          limiter: limiter,
          transport: transport
        )
      end)

    assert_receive {:transport_waiting, transport_process}
    GenServer.stop(limiter)
    send(transport_process, :complete_transport)

    assert {:ok, %{content: "completed"}} = Task.await(task)
  end
end
