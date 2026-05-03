defmodule Twelvgaige.Tool.InputValidatorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.InputValidator

  @schema %{
    "type" => "object",
    "required" => ["path"],
    "properties" => %{
      "path" => %{"type" => "string"},
      "flags" => %{
        "type" => "array",
        "items" => %{"type" => "string"}
      },
      "mode" => %{"enum" => ["brief", "full"]}
    },
    "additionalProperties" => false
  }

  test "validates the supported JSON schema subset" do
    assert :ok = InputValidator.validate(%{"path" => "README.md", "flags" => ["a"]}, @schema)
    assert :ok = InputValidator.validate(%{path: "README.md", mode: "brief"}, @schema)
  end

  test "rejects missing, unknown, and mistyped fields" do
    assert {:error, missing} = InputValidator.validate(%{}, @schema)
    assert missing.reason == :tool_input_invalid
    assert missing.details.path == ["path"]

    assert {:error, unknown} = InputValidator.validate(%{"path" => "x", "extra" => true}, @schema)
    assert unknown.details.field == "extra"

    assert {:error, mistyped} = InputValidator.validate(%{"path" => 123}, @schema)
    assert mistyped.details.expected == "string"
  end
end
