defmodule Twelvgaige.Tool.Builtins.GitCommitTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.GitCommit
  alias Twelvgaige.Tool.Executor

  test "stages and commits explicit files below the trusted root" do
    root = tmp_dir!()
    File.write!(Path.join(root, "note.txt"), "updated\n")

    runner = fn binary, args, opts ->
      send(self(), {:runner, binary, args, opts})

      case args do
        ["-C", ^root, "status", "--porcelain", "--", "note.txt"] ->
          {:ok, %{status: 0, stdout: " M note.txt\n", stderr: "", duration_ms: 2}}

        ["-C", ^root, "add", "--", "note.txt"] ->
          {:ok, %{status: 0, stdout: "", stderr: "", duration_ms: 3}}

        ["-C", ^root, "commit", "-m", "Update note", "--", "note.txt"] ->
          {:ok, %{status: 0, stdout: "[main abc123] Update note\n", stderr: "", duration_ms: 4}}
      end
    end

    assert {:ok, output} =
             GitCommit.execute(
               %{"paths" => ["note.txt"], "message" => "Update note", "confirm" => true},
               root: root,
               command_runner: runner
             )

    assert_receive {:runner, "git", ["-C", ^root, "status", "--porcelain", "--", "note.txt"],
                    [cwd: ^root, timeout_ms: 30_000]}

    assert_receive {:runner, "git", ["-C", ^root, "add", "--", "note.txt"],
                    [cwd: ^root, timeout_ms: 30_000]}

    assert_receive {:runner, "git",
                    ["-C", ^root, "commit", "-m", "Update note", "--", "note.txt"],
                    [cwd: ^root, timeout_ms: 30_000]}

    assert output["paths"] == ["note.txt"]
    assert output["commit_excerpt"] =~ "Update note"
    assert output["exit_status"] == 0
  end

  test "requires explicit confirmation and destructive executor safety" do
    root = tmp_dir!()
    File.write!(Path.join(root, "note.txt"), "updated\n")

    input = %{"paths" => ["note.txt"], "message" => "Update note", "confirm" => true}

    runner = fn _binary, _args, _opts ->
      {:ok, %{status: 0, stdout: "", stderr: "", duration_ms: 1}}
    end

    assert {:error, confirmation} =
             GitCommit.execute(%{"paths" => ["note.txt"], "message" => "Update note"},
               root: root,
               command_runner: runner
             )

    assert confirmation.class == :policy_error
    assert confirmation.reason == :policy_denied

    assert {:error, policy} =
             Executor.execute("git_commit", input,
               allowed_tools: ["git_commit"],
               max_safety: :idempotent_write,
               limiter: nil,
               tool_opts: [root: root, command_runner: runner]
             )

    assert policy.class == :policy_error
    assert policy.reason == :policy_denied

    assert {:ok, %{"paths" => ["note.txt"]}} =
             Executor.execute("git_commit", input,
               allowed_tools: ["git_commit"],
               max_safety: :destructive,
               limiter: nil,
               tool_opts: [root: root, command_runner: runner]
             )
  end

  test "denies root escapes, directories, and symlink paths before git runs" do
    root = tmp_dir!()
    File.mkdir_p!(Path.join(root, "dir"))
    File.write!(Path.join(root, "note.txt"), "updated\n")

    outside = Path.join(tmp_dir!(), "outside.txt")
    File.write!(outside, "outside\n")

    symlink = Path.join(root, "linked.txt")
    File.ln_s!(Path.join(root, "note.txt"), symlink)

    assert {:error, escape} =
             GitCommit.execute(
               %{"paths" => [outside], "message" => "bad", "confirm" => true},
               root: root,
               command_runner: unused_runner()
             )

    assert escape.reason == :tool_denied
    assert escape.safety_required

    assert {:error, directory} =
             GitCommit.execute(
               %{"paths" => ["dir"], "message" => "bad", "confirm" => true},
               root: root,
               command_runner: unused_runner()
             )

    assert directory.reason == :tool_non_retryable

    assert {:error, symlink_error} =
             GitCommit.execute(
               %{"paths" => ["linked.txt"], "message" => "bad", "confirm" => true},
               root: root,
               command_runner: unused_runner()
             )

    assert symlink_error.reason == :tool_denied
  end

  test "redacts git output and classifies non-zero git exits as non-retryable" do
    root = tmp_dir!()
    File.write!(Path.join(root, "note.txt"), "updated\n")

    runner = fn
      "git", ["-C", ^root, "status" | _rest], _opts ->
        {:ok, %{status: 0, stdout: " M note.txt token=secret\n", stderr: "", duration_ms: 1}}

      "git", ["-C", ^root, "add" | _rest], _opts ->
        {:ok, %{status: 0, stdout: "", stderr: "", duration_ms: 1}}

      "git", ["-C", ^root, "commit" | _rest], _opts ->
        {:ok, %{status: 1, stdout: "password=secret\n", stderr: "", duration_ms: 1}}
    end

    assert {:error, error} =
             GitCommit.execute(
               %{"paths" => ["note.txt"], "message" => "Update note", "confirm" => true},
               root: root,
               command_runner: runner
             )

    assert error.reason == :tool_non_retryable
    assert error.details.stdout =~ "password=[REDACTED]"
  end

  defp unused_runner do
    fn _binary, _args, _opts -> flunk("git should not run") end
  end

  defp tmp_dir! do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige_git_commit_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
