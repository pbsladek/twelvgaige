defmodule Twelvgaige.Authoring.AtomicFileTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Authoring.AtomicFile

  test "writes through a temporary sibling file" do
    path = tmp_path("workflow.yaml")

    assert :ok = AtomicFile.write(path, "new contents")
    assert File.read!(path) == "new contents"
  end

  test "removes temporary file when rename fails" do
    path = tmp_path("workflow.yaml")
    tmp_path = "#{path}.tmp-test"
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "original")

    rename_fun = fn ^tmp_path, ^path -> {:error, :eacces} end

    assert {:error, error} =
             AtomicFile.write(path, "replacement",
               tmp_path: tmp_path,
               rename_fun: rename_fun
             )

    assert error.reason == :invalid_shell
    assert File.read!(path) == "original"
    refute File.exists?(tmp_path)
  end

  defp tmp_path(name) do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige-atomic-file-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    Path.join(root, name)
  end
end
