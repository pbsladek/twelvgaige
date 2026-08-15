defmodule Twelvgaige.GitTestEnvironmentTest do
  use ExUnit.Case, async: true

  test "test Git commands ignore developer signing and credential configuration" do
    assert System.get_env("GIT_CONFIG_NOSYSTEM") == "1"
    assert System.get_env("GIT_TERMINAL_PROMPT") == "0"
    assert File.read!(System.fetch_env!("GIT_CONFIG_GLOBAL")) == ""

    repository =
      Path.join(System.tmp_dir!(), "hermetic-git-#{System.unique_integer([:positive])}")

    File.mkdir_p!(repository)
    on_exit(fn -> File.rm_rf!(repository) end)

    git!(repository, ["init", "--quiet"])
    git!(repository, ["config", "user.name", "Twelvgaige Test"])
    git!(repository, ["config", "user.email", "test@twelvgaige.invalid"])
    File.write!(Path.join(repository, "proof.txt"), "hermetic\n")
    git!(repository, ["add", "proof.txt"])
    git!(repository, ["commit", "--quiet", "-m", "prove hermetic Git"])

    assert git!(repository, ["log", "-1", "--format=%s"]) == "prove hermetic Git"

    assert {"", 1} =
             System.cmd("git", ["config", "--global", "--get", "commit.gpgsign"],
               cd: repository,
               stderr_to_stdout: true
             )
  end

  defp git!(repository, args) do
    case System.cmd("git", args, cd: repository, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> flunk("git #{Enum.join(args, " ")} failed (#{status}): #{output}")
    end
  end
end
