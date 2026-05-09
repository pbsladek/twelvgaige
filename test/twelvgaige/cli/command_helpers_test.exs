defmodule Twelvgaige.CLI.CommandHelpersTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.CommandHelpers

  test "parse_human_json_format accepts only supported command output formats" do
    assert CommandHelpers.parse_human_json_format("human") == {:ok, :human}
    assert CommandHelpers.parse_human_json_format("json") == {:ok, :json}

    assert {:error, error} = CommandHelpers.parse_human_json_format("yaml")
    assert error.message == "format must be human or json"
  end

  test "root_opts preserves explicit roots and omits unset roots" do
    assert CommandHelpers.root_opts(root: nil, format: :human) == []

    assert CommandHelpers.root_opts(root: "/tmp/traphouse", format: :human) == [
             root: "/tmp/traphouse"
           ]
  end
end
