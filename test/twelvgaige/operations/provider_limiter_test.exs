defmodule Twelvgaige.Operations.ProviderLimiterTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Operations.{ProviderLimiter, Store}

  setup do
    root = Path.join(System.tmp_dir!(), "twelvgaige-rate-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    store = start_supervised!({Store, name: nil, path: Path.join(root, "ops.sqlite3")})
    clock = start_supervised!({Agent, fn -> ~U[2026-08-02 12:00:00Z] end})

    opts = [
      name: nil,
      store: store,
      now_fun: fn -> Agent.get(clock, & &1) end,
      limits: %{
        {:openai, :primary} => %{rpm: 2, tpm: 100, daily_cost_micros: 1_000, cooldown_ms: 500}
      }
    ]

    limiter = start_supervised!({ProviderLimiter, opts})
    %{clock: clock, limiter: limiter, opts: opts, store: store}
  end

  test "enforces RPM, TPM, daily cost, durable reservations, and Retry-After", context do
    assert {:ok, first} =
             ProviderLimiter.acquire(:openai, :primary, 40, 300, server: context.limiter)

    assert :ok =
             ProviderLimiter.complete(first, %{tokens: 50, cost_micros: 350},
               server: context.limiter
             )

    assert {:ok, _second} =
             ProviderLimiter.acquire(:openai, :primary, 40, 300, server: context.limiter)

    assert {:wait, %{reason: :provider_rpm_exhausted, retry_after_ms: 60_000}} =
             ProviderLimiter.acquire(:openai, :primary, 1, 1, server: context.limiter)

    assert {:ok, %{cooldown_ms: 2_000, source: :retry_after}} =
             ProviderLimiter.observe_response(
               :openai,
               :primary,
               %{status: 429, headers: %{"Retry-After" => "2"}},
               server: context.limiter
             )

    status = ProviderLimiter.status(server: context.limiter)
    assert [%{requests: 2, tokens: 90, retry_after_ms: 2_000, denials: 1}] = status.providers

    GenServer.stop(context.limiter)
    restarted = start_supervised!({ProviderLimiter, context.opts}, id: :restarted_limiter)

    assert {:wait, %{reason: :provider_cooldown}} =
             ProviderLimiter.acquire(:openai, :primary, 1, 1, server: restarted)

    Agent.update(context.clock, fn now -> DateTime.add(now, 61, :second) end)
    assert {:ok, _permit} = ProviderLimiter.acquire(:openai, :primary, 10, 10, server: restarted)
  end
end
