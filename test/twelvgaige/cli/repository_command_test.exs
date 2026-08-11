defmodule Twelvgaige.CLI.RepositoryCommandTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Commands.Repository

  test "repo inspect reports source modes and does not change source state" do
    repository = repository_fixture()
    File.write!(Path.join(repository, "untracked.txt"), "local")
    before_status = git_output!(repository, ["status", "--porcelain=v2", "-z"])
    index = repository |> git_output!(["rev-parse", "--git-path", "index"]) |> String.trim()
    before_index = File.read!(Path.expand(index, repository))

    assert {:ok, human, 0} = Repository.inspect(["--repo", repository])

    canonical_repository =
      repository |> git_output!(["rev-parse", "--show-toplevel"]) |> String.trim()

    assert human =~ "Repository: #{canonical_repository}"
    assert human =~ "Source modes: staged, working-tree"
    assert human =~ "untracked=1"
    assert human =~ "Source token: sha256:"

    assert {:ok, json, 0} =
             Repository.inspect(["--repo", repository, "--format", "json"])

    decoded = Jason.decode!(json)
    assert decoded["root"] == canonical_repository
    assert decoded["dirtiness"]["untracked"] == 1
    assert decoded["source_state_token"] =~ "sha256:"

    assert git_output!(repository, ["status", "--porcelain=v2", "-z"]) == before_status
    assert File.read!(Path.expand(index, repository)) == before_index
  end

  defp repository_fixture do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-repo-cli-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    git!(path, ["init", "--quiet"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["config", "user.email", "test@localhost"])
    File.write!(Path.join(path, "tracked.txt"), "base")
    git!(path, ["add", "tracked.txt"])
    git!(path, ["commit", "--quiet", "-m", "base"])
    path
  end

  defp git!(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
  end

  defp git_output!(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
  end
end
