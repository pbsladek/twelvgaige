defmodule Twelvgaige.Workspace.RepositoryInspectionTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.RepositoryInspection

  test "inspects a clean ordinary repository without mutating its index" do
    repository = repository_fixture()
    File.write!(Path.join(repository, ".gitignore"), "ignored/\n")
    File.mkdir_p!(Path.join(repository, "ignored"))
    File.write!(Path.join(repository, "ignored/cache"), "ignored")
    git!(repository, ["add", ".gitignore"])
    git!(repository, ["commit", "--quiet", "-m", "ignore"])

    index_path = git_output!(repository, ["rev-parse", "--git-path", "index"]) |> String.trim()
    index_path = Path.expand(index_path, repository)
    index_before = File.read!(index_path)
    status_before = git_output!(repository, ["status", "--porcelain=v2", "-z"])

    assert {:ok, inspection} = RepositoryInspection.inspect(repository)
    assert inspection.root
    assert inspection.git_version =~ ~r/^\d+\.\d+\.\d+$/
    assert inspection.common_dir
    assert inspection.object_format == "sha1"
    assert inspection.dirtiness.clean
    assert inspection.dirtiness.ignored == 1
    assert inspection.source_modes == [:committed, :staged, :working_tree]
    assert inspection.unsupported_features == []
    assert inspection.features.linked_worktrees == 1
    assert inspection.source_state_token =~ ~r/^sha256:[0-9a-f]{64}$/

    assert File.read!(index_path) == index_before
    assert git_output!(repository, ["status", "--porcelain=v2", "-z"]) == status_before
  end

  test "rejects Git older than the pinned minimum before repository reads" do
    repository = repository_fixture()

    runner = fn
      _binary, ["--version"], _opts -> {"git version 2.38.5\n", 0}
      _binary, args, opts -> System.cmd("git", args, opts)
    end

    assert {:error, {:git_version_unsupported, {2, 38, 5}, {2, 39, 0}}} =
             RepositoryInspection.inspect(repository, command_runner: runner)
  end

  test "counts dirty states and changes the token when dirty content changes" do
    repository = repository_fixture()
    File.write!(Path.join(repository, "staged.txt"), "staged")
    git!(repository, ["add", "staged.txt"])
    File.write!(Path.join(repository, "tracked.txt"), "first dirty value")
    File.write!(Path.join(repository, "untracked.txt"), "untracked")

    assert {:ok, first} = RepositoryInspection.inspect(repository)
    assert first.dirtiness.staged == 1
    assert first.dirtiness.unstaged == 1
    assert first.dirtiness.untracked == 1
    refute first.dirtiness.clean
    assert :repository_dirty in first.warnings

    File.write!(Path.join(repository, "tracked.txt"), "second dirty value")
    assert {:ok, second} = RepositoryInspection.inspect(repository)
    refute second.source_state_token == first.source_state_token
  end

  test "rejects custom content filters and nested repositories during preflight" do
    repository = repository_fixture()
    File.write!(Path.join(repository, ".gitattributes"), "*.bin filter=lfs diff=lfs\n")
    File.write!(Path.join(repository, "asset.bin"), "pointer")
    git!(repository, ["add", ".gitattributes", "asset.bin"])
    git!(repository, ["commit", "--quiet", "-m", "attributes"])

    nested = Path.join(repository, "vendor/project")
    File.mkdir_p!(nested)
    git!(nested, ["init", "--quiet"])

    assert {:ok, inspection} = RepositoryInspection.inspect(repository)
    assert inspection.features.git_lfs
    assert inspection.features.custom_filters
    assert inspection.features.custom_diff_or_merge
    assert inspection.features.nested_repositories
    assert :git_lfs in inspection.unsupported_features
    assert :custom_filters in inspection.unsupported_features
    assert :nested_repositories in inspection.unsupported_features
    assert inspection.source_modes == []
  end

  test "qualifies tracked symlinks and linked worktree discovery without broadening execution authority" do
    repository = repository_fixture()
    link = Path.join(repository, "tracked-link")

    case File.ln_s("tracked.txt", link) do
      :ok ->
        git!(repository, ["add", "tracked-link"])
        git!(repository, ["commit", "--quiet", "-m", "symlink"])

        linked = temp_dir("inspection-linked-worktree")
        File.rmdir!(linked)
        git!(repository, ["worktree", "add", "--quiet", "--detach", linked, "HEAD"])

        assert {:ok, inspection} = RepositoryInspection.inspect(repository)
        assert inspection.features.symlinks
        assert inspection.features.linked_worktrees == 2
        refute :symlinks in inspection.unsupported_features
        refute :linked_worktrees in inspection.unsupported_features
        assert inspection.source_modes == [:committed, :staged, :working_tree]

      {:error, reason} ->
        IO.puts("symlink compatibility fixture skipped: #{inspect(reason)}")
    end
  end

  test "SHA-256 repositories remain explicitly fail-closed until release-qualified" do
    repository = temp_dir("inspection-sha256")

    case System.cmd("git", ["-C", repository, "init", "--quiet", "--object-format=sha256"],
           stderr_to_stdout: true
         ) do
      {_output, 0} ->
        git!(repository, ["config", "user.name", "Test"])
        git!(repository, ["config", "user.email", "test@localhost"])
        File.write!(Path.join(repository, "tracked.txt"), "base")
        git!(repository, ["add", "--all"])
        git!(repository, ["commit", "--quiet", "-m", "base"])

        assert {:ok, inspection} = RepositoryInspection.inspect(repository)
        assert inspection.object_format == "sha256"
        assert :sha256_object_format in inspection.unsupported_features
        assert inspection.source_modes == []

      {output, _status} ->
        IO.puts("SHA-256 compatibility fixture skipped: #{String.trim(output)}")
    end
  end

  test "detects submodules, sparse checkout, and partial-clone configuration before admission" do
    submodule_source = repository_fixture()
    repository = repository_fixture()

    git!(repository, [
      "-c",
      "protocol.file.allow=always",
      "submodule",
      "add",
      "--quiet",
      submodule_source,
      "vendor/submodule"
    ])

    git!(repository, ["commit", "--quiet", "-m", "submodule"])
    git!(repository, ["sparse-checkout", "init", "--cone"])
    git!(repository, ["config", "remote.origin.promisor", "true"])

    assert {:ok, inspection} = RepositoryInspection.inspect(repository)
    assert inspection.features.submodules
    assert inspection.features.sparse_checkout
    assert inspection.features.partial_clone
    assert :submodules in inspection.unsupported_features
    assert :sparse_checkout in inspection.unsupported_features
    assert :partial_clone in inspection.unsupported_features
    assert inspection.source_modes == []
  end

  test "detects shallow history and case-colliding index paths before admission" do
    source = repository_fixture()
    File.write!(Path.join(source, "second.txt"), "second")
    git!(source, ["add", "second.txt"])
    git!(source, ["commit", "--quiet", "-m", "second"])

    shallow = temp_dir("inspection-shallow")
    File.rmdir!(shallow)
    git!(System.tmp_dir!(), ["clone", "--quiet", "--depth", "1", "file://#{source}", shallow])

    assert {:ok, shallow_inspection} = RepositoryInspection.inspect(shallow)
    assert shallow_inspection.features.shallow
    assert :shallow in shallow_inspection.unsupported_features
    assert shallow_inspection.source_modes == []

    collision = repository_fixture()
    object = git_output!(collision, ["hash-object", "tracked.txt"]) |> String.trim()
    git!(collision, ["update-index", "--add", "--cacheinfo", "100644,#{object},Case.txt"])
    git!(collision, ["update-index", "--add", "--cacheinfo", "100644,#{object},case.txt"])

    assert {:ok, collision_inspection} = RepositoryInspection.inspect(collision)
    assert collision_inspection.features.case_collisions
    assert :case_collisions in collision_inspection.unsupported_features
    assert collision_inspection.source_modes == []
  end

  test "inspects bare repositories but exposes no admissible source mode" do
    source = repository_fixture()
    bare = temp_dir("inspection-bare")
    File.rmdir!(bare)
    git!(System.tmp_dir!(), ["clone", "--quiet", "--bare", source, bare])

    assert {:ok, inspection} = RepositoryInspection.inspect(bare)
    assert inspection.root == bare
    assert inspection.features.bare
    assert :bare in inspection.unsupported_features
    assert inspection.source_modes == []
  end

  defp repository_fixture do
    repository = temp_dir("inspection")
    git!(repository, ["init", "--quiet"])
    git!(repository, ["config", "user.name", "Test"])
    git!(repository, ["config", "user.email", "test@localhost"])
    File.write!(Path.join(repository, "tracked.txt"), "base")
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

  defp git_output!(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
  end

  defp temp_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
