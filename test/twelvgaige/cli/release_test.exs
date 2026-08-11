defmodule Twelvgaige.CLI.ReleaseTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Release

  test "release application declares OTP HTTP runtime dependencies" do
    applications = Application.spec(:twelvgaige, :applications)

    assert :inets in applications
    assert :ssl in applications
  end

  test "reads NUL-delimited release wrapper arguments" do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-release-args-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)

    File.write!(path, "round\0run\0workflow.yaml\0--input\0{}\0")

    assert Release.args_from_file(path) == ["round", "run", "workflow.yaml", "--input", "{}"]
  end

  test "preserves empty release wrapper arguments" do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-release-args-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)

    File.write!(path, "round\0run\0\0")

    assert Release.args_from_file(path) == ["round", "run", ""]
  end

  test "missing release args file environment behaves like no args" do
    assert Release.args_from_file(nil) == []
  end
end
