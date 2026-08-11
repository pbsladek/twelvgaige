defmodule Twelvgaige.Workspace.GitTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.Canonical
  alias Twelvgaige.Workspace.Git

  test "parses a supported Git semantic version and rejects ambiguous output" do
    runner = fn _binary, ["--version"], _opts ->
      {"git version 2.55.0 (Apple Git-155)\n", 0}
    end

    assert {:ok, {2, 55, 0}} = Git.version(command_runner: runner)

    invalid = fn _binary, ["--version"], _opts ->
      {"git version unknown\n", 0}
    end

    assert {:error, :git_version_invalid} = Git.version(command_runner: invalid)
  end

  test "private snapshots preserve ancestry and materialize the complete committed source" do
    repository = repository_fixture()
    workspace = temp_path("snapshot")
    {:ok, base} = Git.resolve_commit(repository, "HEAD")

    assert :ok = Git.create_snapshot(repository, workspace, base, ["lib"])
    assert File.read!(Path.join(workspace, "lib/example.ex")) == "base\n"
    assert File.read!(Path.join(workspace, "mix.exs")) == "build input\n"
    assert {:ok, ^base} = Git.resolve_commit(workspace, "HEAD")

    File.rm_rf!(repository)
    assert {:ok, ^base} = Git.resolve_commit(workspace, "HEAD")
    assert {history, 0} = System.cmd("git", ["-C", workspace, "rev-list", "--count", "HEAD"])
    assert String.to_integer(String.trim(history)) >= 1
  end

  test "capture includes commits, dirty files, untracked files, deletes, modes, and policy evidence" do
    repository = repository_fixture()
    workspace = temp_path("result")
    {:ok, base} = Git.resolve_commit(repository, "HEAD")
    assert :ok = Git.create_snapshot(repository, workspace, base, [])

    File.write!(Path.join(workspace, "lib/example.ex"), "committed change\n")
    git!(workspace, ["add", "lib/example.ex"])
    git!(workspace, ["commit", "--quiet", "-m", "agent commit"])

    File.write!(Path.join(workspace, "lib/untracked.ex"), "untracked\n")
    File.write!(Path.join(workspace, "lib/comma,name.txt"), "comma\n")
    File.ln_s!("untracked.ex", Path.join(workspace, "lib/untracked-link"))
    File.rm!(Path.join(workspace, "mix.exs"))
    File.write!(Path.join(workspace, "outside.txt"), <<0, 1, 2, 255>>)
    File.chmod!(Path.join(workspace, "lib/untracked.ex"), 0o755)

    assert {:ok, result} = Git.capture_result(workspace, base, allowed_paths: ["lib"])
    assert result.integrity == :verified
    refute result.no_change
    assert result.patch =~ "lib/example.ex"
    assert result.patch =~ "lib/untracked.ex"
    assert result.patch =~ "outside.txt"

    changes = Map.new(result.changed_paths, &{display_path(&1), &1})
    assert changes["lib/example.ex"]["status"] == "modified"
    assert changes["lib/untracked.ex"]["status"] == "added"
    assert changes["lib/untracked.ex"]["new_mode"] == "100755"
    assert changes["lib/comma,name.txt"]["status"] == "added"
    assert changes["lib/untracked-link"]["status"] == "added"
    assert changes["lib/untracked-link"]["new_mode"] == "120000"
    assert changes["mix.exs"]["status"] == "deleted"
    assert changes["outside.txt"]["status"] == "added"

    assert Enum.map(result.out_of_policy, &display_path/1) |> Enum.sort() ==
             ["mix.exs", "outside.txt"]
  end

  test "capture reports an explicit no-change result" do
    repository = repository_fixture()
    workspace = temp_path("no-change")
    {:ok, base} = Git.resolve_commit(repository, "HEAD")
    assert :ok = Git.create_snapshot(repository, workspace, base, [])

    assert {:ok, %{no_change: true, patch: "", changed_paths: [], integrity: :verified}} =
             Git.capture_result(workspace, base)
  end

  test "commit bundle is absent at the baseline and preserves agent commits when present" do
    repository = repository_fixture()
    workspace = temp_path("bundle-workspace")
    destination = temp_path("bundle-import")
    bundle_path = temp_path("result.bundle")
    {:ok, base} = Git.resolve_commit(repository, "HEAD")
    assert :ok = Git.create_snapshot(repository, workspace, base, [])
    {:ok, baseline} = Git.resolve_commit(workspace, "HEAD")

    assert {:ok, nil} = Git.capture_commit_bundle(workspace, baseline)

    File.write!(Path.join(workspace, "agent.txt"), "agent commit\n")
    git!(workspace, ["add", "agent.txt"])
    git!(workspace, ["commit", "--quiet", "-m", "agent commit"])
    {:ok, head} = Git.resolve_commit(workspace, "HEAD")

    assert {:ok, bundle} = Git.capture_commit_bundle(workspace, baseline)
    assert is_binary(bundle)
    assert bundle =~ "# v2 git bundle"
    File.write!(bundle_path, bundle)

    File.mkdir_p!(destination)
    git!(destination, ["init", "--quiet"])
    git!(destination, ["fetch", "--quiet", bundle_path, "HEAD"])
    assert {:ok, ^head} = Git.resolve_commit(destination, "FETCH_HEAD")
  end

  defp display_path(%{"path" => encoded}), do: decode_path(encoded)
  defp display_path(%{"new_path" => encoded}), do: decode_path(encoded)

  defp decode_path(encoded) do
    {:ok, path} = Canonical.decode_path(encoded)
    path
  end

  defp repository_fixture do
    repository = temp_path("repository")
    File.mkdir_p!(Path.join(repository, "lib"))
    git!(repository, ["init", "--quiet"])
    git!(repository, ["config", "user.name", "Test"])
    git!(repository, ["config", "user.email", "test@localhost"])
    File.write!(Path.join(repository, "lib/example.ex"), "base\n")
    File.write!(Path.join(repository, "mix.exs"), "build input\n")
    git!(repository, ["add", "--all"])
    git!(repository, ["commit", "--quiet", "-m", "base"])
    repository
  end

  defp git!(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
  end

  defp temp_path(name) do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-git-#{name}-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
