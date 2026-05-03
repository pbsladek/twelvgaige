defmodule Twelvgaige.Output.ParserTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Output.Parser
  alias Twelvgaige.Shell.Schema

  @schema %{
    "type" => "object",
    "required" => ["summary", "ok"],
    "properties" => %{
      "summary" => %{"type" => "string"},
      "ok" => %{"type" => "boolean"}
    },
    "additionalProperties" => false
  }

  test "keeps schemaless output as opaque content" do
    assert Parser.parse("plain text", nil) == {:ok, %{"content" => "plain text"}}
  end

  test "parses and validates JSON output" do
    assert {:ok, schema} = Schema.from_map(@schema)

    assert {:ok, %{"summary" => "healthy", "ok" => true}} =
             Parser.parse(~s({"summary":"healthy","ok":true}), schema)
  end

  test "extracts fenced JSON output" do
    assert {:ok, %{"summary" => "healthy", "ok" => true}} =
             Parser.parse(
               """
               Here is the result:

               ```json
               {"summary":"healthy","ok":true}
               ```
               """,
               @schema
             )
  end

  test "classifies malformed JSON" do
    assert {:error, error} = Parser.parse("not json", @schema)

    assert error.class == :output_error
    assert error.reason == :output_parse_error
    assert error.retryable
  end

  test "classifies schema violations" do
    assert {:error, error} = Parser.parse(~s({"summary":42,"ok":true}), @schema)

    assert error.class == :output_error
    assert error.reason == :output_schema_violation
    assert error.details.path == ["summary"]
    assert error.retryable
  end
end
