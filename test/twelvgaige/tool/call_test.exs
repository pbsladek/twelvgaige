defmodule Twelvgaige.Tool.CallTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Call

  test "normalizes common provider tool-call shapes" do
    assert {:ok, call} =
             Call.normalize(
               %{"tool_name" => "shell_read", "arguments" => ~s({"path":"a.txt"})},
               0
             )

    assert call.id == "tool_call_1"
    assert call.name == "shell_read"
    assert call.input == %{"path" => "a.txt"}

    assert {:ok, call} = Call.normalize(%{id: "call_2", name: "http_get", input: %{}}, 1)
    assert call.id == "call_2"
  end

  test "rejects malformed tool calls" do
    assert {:error, missing_name} = Call.normalize(%{"input" => %{}}, 0)
    assert missing_name.reason == :tool_input_invalid

    assert {:error, bad_arguments} =
             Call.normalize(%{"name" => "shell_read", "arguments" => ~s(["not-object"])}, 0)

    assert bad_arguments.reason == :tool_input_invalid
  end
end
