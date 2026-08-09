defmodule Twelvgaige.Operations.ProviderRuntimeIntegrationTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.LLM
  alias Twelvgaige.Operations.{ProviderLimiter, Store}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-provider-runtime-#{System.unique_integer([:positive])}"
      )

    store = start_supervised!({Store, name: nil, path: Path.join(root, "operations.sqlite3")})
    now = ~U[2026-08-02 12:00:00Z]

    limiter =
      start_supervised!(
        {ProviderLimiter,
         name: nil,
         store: store,
         now_fun: fn -> now end,
         limits: %{
           {"openai", "primary"} => %{
             rpm: 10,
             tpm: 100,
             daily_cost_micros: 1_000,
             cooldown_ms: 30_000
           }
         }}
      )

    %{limiter: limiter}
  end

  test "actual provider calls reconcile token and cost reservations", %{limiter: limiter} do
    transport = fn _request ->
      {:ok,
       %{
         status: 200,
         headers: [],
         body: %{
           "choices" => [%{"message" => %{"content" => "done"}}],
           "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 2}
         }
       }}
    end

    assert {:ok, _response} =
             LLM.complete(:openai, "gpt-test", [%{role: "user", content: "hello"}],
               transport: transport,
               provider_limiter: limiter,
               provider_account: "primary",
               estimated_tokens: 40,
               estimated_cost_micros: 100,
               actual_cost_micros: 25
             )

    assert %{providers: [status]} = ProviderLimiter.status(server: limiter)
    assert status.requests == 1
    assert status.tokens == 9
    assert status.day_cost_micros == 25
    assert status.pending_permits == 0
  end

  test "Retry-After enters durable cooldown before another transport call", %{limiter: limiter} do
    parent = self()

    transport = fn _request ->
      send(parent, :transport_called)
      {:ok, %{status: 429, headers: [{"retry-after", "2"}], body: %{"error" => "busy"}}}
    end

    opts = [
      transport: transport,
      provider_limiter: limiter,
      provider_account: "primary",
      estimated_tokens: 10
    ]

    assert {:error, %{reason: :llm_rate_limited}} =
             LLM.complete(:openai, "gpt-test", [%{role: "user", content: "one"}], opts)

    assert_receive :transport_called

    assert {:error, %{reason: :llm_rate_limited, details: details}} =
             LLM.complete(:openai, "gpt-test", [%{role: "user", content: "two"}], opts)

    assert details.control_reason == :provider_cooldown
    assert details.retry_after_ms == 2_000
    refute_receive :transport_called

    assert %{providers: [status]} = ProviderLimiter.status(server: limiter)
    assert status.last_response_status == 429
    assert status.retry_after_ms == 2_000
  end
end
