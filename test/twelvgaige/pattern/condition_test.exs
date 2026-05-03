defmodule Twelvgaige.Pattern.ConditionTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Pattern.Condition

  @context %{
    input: %{
      "cluster" => "prod",
      "replicas" => 3,
      "enabled" => true,
      "tier" => "payments"
    },
    shots: %{
      "inspect" => %{
        "ok" => true,
        "confidence" => 0.91,
        "action" => "restart"
      }
    }
  }

  test "evaluates boolean, comparison, and logical operators" do
    assert Condition.evaluate(true, @context) == {:ok, true}
    assert Condition.evaluate("input.cluster == \"prod\"", @context) == {:ok, true}

    assert Condition.evaluate("input.replicas >= 3 and shots.inspect.ok == true", @context) ==
             {:ok, true}

    assert Condition.evaluate("not input.enabled == false", @context) == {:ok, true}
    assert Condition.evaluate("input.tier in [\"payments\", \"orders\"]", @context) == {:ok, true}
    assert Condition.evaluate("shots.inspect.confidence > 0.5", @context) == {:ok, true}
  end

  test "exists returns false for missing paths without failing the round" do
    assert Condition.evaluate("input.missing exists", @context) == {:ok, false}
    assert Condition.evaluate("shots.inspect.action exists", @context) == {:ok, true}
  end

  test "missing non-exists paths return a condition error" do
    assert {:error, error} = Condition.evaluate("input.missing == true", @context)
    assert error.class == :condition_error
    assert error.reason == :condition_missing_path
    assert error.details.path == "input.missing"
  end

  test "rejects unsupported roots and invalid syntax" do
    assert {:error, root_error} = Condition.validate("steps.inspect.ok == true")
    assert root_error.reason == :unsupported_condition

    assert {:error, syntax_error} = Condition.validate("input.cluster ==")
    assert syntax_error.reason == :unsupported_condition
  end
end
