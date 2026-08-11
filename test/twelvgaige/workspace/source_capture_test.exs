defmodule Twelvgaige.Workspace.SourceCaptureTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.{Git, RepositoryInspection, SourceCapture}

  defp capture(repository, destination, opts \\ []) do
    registration = [
      workspace_id: "ws_source_capture_test",
      creation_operation_id: "op_source_capture_test",
      git_audit_fun: fn _event -> :ok end
    ]

    SourceCapture.capture(repository, destination, Keyword.merge(registration, opts))
  end

  test "unsupported repository features fail before allocating a destination" do
    repository = repository_fixture()
    git!(repository, ["sparse-checkout", "init", "--cone"])
    destination = temp_path("unsupported-destination")

    assert {:error, {:repository_features_unsupported, features}} =
             capture(repository, destination)

    assert :sparse_checkout in features
    refute File.exists?(destination)
  end

  test "committed mode fails explicitly instead of ignoring dirty source" do
    repository = repository_fixture()
    File.write!(Path.join(repository, "tracked.txt"), "dirty")
    destination = temp_path("committed-dirty")

    assert {:error, :committed_source_requires_clean_repository} =
             capture(repository, destination, source_mode: :committed)

    refute File.exists?(destination)
  end

  test "staged mode captures the index but not unstaged or untracked content" do
    repository = repository_fixture()
    File.write!(Path.join(repository, "staged.txt"), "from index")
    git!(repository, ["add", "staged.txt"])
    File.write!(Path.join(repository, "tracked.txt"), "unstaged")
    File.write!(Path.join(repository, "untracked.txt"), "untracked")
    destination = temp_path("staged")
    source_status = git_output!(repository, ["status", "--porcelain=v2", "-z"])
    index_path = git_output!(repository, ["rev-parse", "--git-path", "index"]) |> String.trim()
    index_bytes = File.read!(Path.expand(index_path, repository))

    assert {:ok, capture} = capture(repository, destination, source_mode: :staged)
    assert capture.manifest.source_mode == :staged
    assert File.read!(Path.join(destination, "staged.txt")) == "from index"
    assert File.read!(Path.join(destination, "tracked.txt")) == "base"
    refute File.exists?(Path.join(destination, "untracked.txt"))
    refute capture.workspace_baseline_commit == capture.manifest.base_commit
    assert capture.manifest.input_tree
    workspace_baseline = capture.workspace_baseline_commit
    assert {:ok, ^workspace_baseline} = Git.resolve_commit(destination, "HEAD")

    assert git_output!(repository, ["status", "--porcelain=v2", "-z"]) == source_status
    assert File.read!(Path.expand(index_path, repository)) == index_bytes
  end

  test "working-tree mode captures admitted untracked content and leaves ignored files out" do
    repository = repository_fixture()
    File.write!(Path.join(repository, ".gitignore"), "ignored.txt\n")
    git!(repository, ["add", ".gitignore"])
    git!(repository, ["commit", "--quiet", "-m", "ignore"])

    File.write!(Path.join(repository, "staged.txt"), "staged")
    git!(repository, ["add", "staged.txt"])
    File.write!(Path.join(repository, "tracked.txt"), "working")
    File.write!(Path.join(repository, "untracked.txt"), "untracked")
    File.write!(Path.join(repository, "ignored.txt"), "ignored")
    destination = temp_path("working")

    assert {:ok, capture} =
             capture(repository, destination,
               source_mode: :working_tree,
               include_untracked: true
             )

    assert capture.manifest.source_mode == :working_tree
    assert File.read!(Path.join(destination, "staged.txt")) == "staged"
    assert File.read!(Path.join(destination, "tracked.txt")) == "working"
    assert File.read!(Path.join(destination, "untracked.txt")) == "untracked"
    refute File.exists?(Path.join(destination, "ignored.txt"))
  end

  test "ignored capture requires both explicit authorities" do
    repository = repository_fixture()
    destination = temp_path("ignored-policy")

    assert {:error, :include_ignored_requires_include_untracked} =
             capture(repository, destination,
               source_mode: :working_tree,
               include_ignored: true
             )
  end

  test "refuses a pre-existing destination without changing it" do
    repository = repository_fixture()
    destination = temp_path("existing-destination")
    File.mkdir_p!(destination)
    sentinel = Path.join(destination, "keep.txt")
    File.write!(sentinel, "owned by caller")

    assert {:error, :source_capture_destination_exists} =
             capture(repository, destination, source_mode: :committed)

    assert File.read!(sentinel) == "owned by caller"
  end

  test "detects plan and capture races and retries from one stable state" do
    repository = repository_fixture()
    destination = temp_path("race")
    counter = start_supervised!({Agent, fn -> 0 end})

    hook = fn _inspection, _workspace ->
      if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0 do
        File.write!(Path.join(repository, "race.txt"), "arrived during capture")
        git!(repository, ["add", "race.txt"])
        git!(repository, ["commit", "--quiet", "-m", "race"])
      end

      :ok
    end

    assert {:ok, capture} =
             capture(repository, destination,
               source_mode: :committed,
               source_capture_hook: hook,
               source_capture_attempts: 2
             )

    assert File.read!(Path.join(destination, "race.txt")) == "arrived during capture"

    assert capture.manifest.base_commit ==
             git_output!(repository, ["rev-parse", "HEAD"]) |> String.trim()

    assert Agent.get(counter, & &1) == 2
  end

  test "rejects a stale planned source token instead of capturing a newer state" do
    repository = repository_fixture()
    destination = temp_path("stale-planned-source")
    assert {:ok, inspection} = RepositoryInspection.inspect(repository)

    File.write!(Path.join(repository, "later.txt"), "not in the plan")
    git!(repository, ["add", "later.txt"])
    git!(repository, ["commit", "--quiet", "-m", "later"])

    assert {:error, :source_changed} =
             capture(repository, destination,
               source_mode: :committed,
               expected_source_state_token: inspection.source_state_token
             )

    refute File.exists?(destination)
  end

  defp repository_fixture do
    repository = temp_path("source-repository")
    File.mkdir_p!(repository)
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

  defp temp_path(name) do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-#{name}-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
