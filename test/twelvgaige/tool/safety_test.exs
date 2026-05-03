defmodule Twelvgaige.Tool.SafetyTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Safety

  test "orders safety levels as a maximum allowed threshold" do
    assert Safety.allows?(:read_only, :read_only)
    refute Safety.allows?(:read_only, :idempotent_write)

    assert Safety.allows?(:destructive, :read_only)
    assert Safety.allows?(:destructive, :idempotent_write)
    assert Safety.allows?(:destructive, :destructive)
    refute Safety.allows?(:destructive, :irreversible)
  end

  test "rejects unknown safety levels" do
    refute Safety.valid?(:admin)
    refute Safety.allows?(:admin, :read_only)
  end
end
