defmodule Twelvgaige.Tool.Builtins.ShellReadTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.ShellRead

  test "reads a bounded file below the configured root" do
    root = tmp_dir!()
    File.write!(Path.join(root, "report.txt"), "abcdef")

    assert {:ok, result} =
             ShellRead.execute(%{"path" => "report.txt", "max_bytes" => 3}, root: root)

    assert result["path"] == "report.txt"
    assert result["content"] == "abc"
    assert result["bytes"] == 3
    assert result["truncated"]
  end

  test "rejects paths outside the configured root" do
    root = tmp_dir!()
    outside = Path.join(tmp_dir!(), "outside.txt")
    File.write!(outside, "secret")

    assert {:error, error} = ShellRead.execute(%{"path" => outside}, root: root)
    assert error.reason == :tool_denied
    assert error.safety_required
  end

  test "classifies missing files as non-retryable tool errors" do
    root = tmp_dir!()

    assert {:error, error} = ShellRead.execute(%{"path" => "missing.txt"}, root: root)
    assert error.reason == :tool_non_retryable
    refute error.retryable
  end

  test "rejects explicitly invalid max_bytes instead of falling back to defaults" do
    root = tmp_dir!()
    File.write!(Path.join(root, "report.txt"), "abcdef")

    for max_bytes <- [0, false] do
      assert {:error, error} =
               ShellRead.execute(%{"path" => "report.txt", "max_bytes" => max_bytes},
                 root: root
               )

      assert error.reason == :tool_input_invalid
    end
  end

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-shell-read-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
