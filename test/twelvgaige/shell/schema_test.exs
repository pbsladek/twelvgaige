defmodule Twelvgaige.Shell.SchemaTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Schema

  test "accepts the phase 1 JSON Schema subset" do
    assert {:ok, schema} =
             Schema.from_map(%{
               type: :object,
               required: ["cluster"],
               properties: %{
                 cluster: %{type: :string},
                 namespaces: %{type: :array, items: %{type: :string}}
               },
               additionalProperties: false
             })

    assert schema.root["type"] == "object"
    assert schema.root["properties"]["cluster"]["type"] == "string"
  end

  test "rejects unsupported schema keywords" do
    assert {:error, error} = Schema.validate(%{oneOf: [%{type: :string}]})

    assert error.reason == :unsupported_schema_keyword
    assert error.details.keyword == "oneOf"
  end

  test "rejects unsupported nested schema keywords" do
    assert {:error, error} =
             Schema.validate(%{
               type: :object,
               properties: %{
                 name: %{type: :string, pattern: "^[a-z]+$"}
               }
             })

    assert error.reason == :unsupported_schema_keyword
    assert error.details.keyword == "pattern"
    assert error.details.path == ["properties", "name", "pattern"]
  end
end
