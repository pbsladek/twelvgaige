defmodule Twelvgaige.Tool.IdempotencyTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Idempotency

  test "builds read-only metadata" do
    idempotency = Idempotency.read_only()

    assert idempotency.class == :read_only
    assert idempotency.reconciliation_strategy == :none
    assert idempotency.side_effect_phase == :none
    assert Idempotency.retryable_without_key?(idempotency)
  end

  test "requires keys block unkeyed automatic retry" do
    idempotency = Idempotency.idempotent(requires_key?: true)

    assert idempotency.class == :idempotent
    refute Idempotency.retryable_without_key?(idempotency)
  end

  test "non-idempotent tools are not retryable without policy" do
    refute Idempotency.retryable_without_key?(Idempotency.non_idempotent())
  end
end
