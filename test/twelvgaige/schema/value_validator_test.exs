defmodule Twelvgaige.Schema.ValueValidatorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Schema.ValueValidator

  test "uses caller-provided error taxonomy" do
    schema = %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string"}},
      "additionalProperties" => false
    }

    assert {:error, error} =
             ValueValidator.validate(%{"name" => 123}, schema,
               error_class: :output_error,
               error_reason: :output_schema_violation,
               retryable: true
             )

    assert error.class == :output_error
    assert error.reason == :output_schema_violation
    assert error.retryable
    assert error.details.expected == "string"
  end
end
