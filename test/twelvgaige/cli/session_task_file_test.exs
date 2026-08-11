defmodule Twelvgaige.CLI.SessionTaskFileTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.SessionTaskFile

  test "loads a Markdown document as the complete objective" do
    path = write_file("task.md", "\n# Repair persistence\n\nRun the restart checks.\n")

    assert {:ok, %{task: objective}} = SessionTaskFile.load(path)
    assert objective == "# Repair persistence\n\nRun the restart checks."
  end

  test "loads closed structured YAML and resolves its repository from the file" do
    path =
      write_file(
        "plans/task.yaml",
        """
        version: 1
        objective: Repair persistence and verify restart behavior.
        runtime: codex
        repo: ../repository
        base_ref: main
        auth_profile: codex-service
        sandbox: apple-container
        network: unrestricted
        allow_unrestricted_network: true
        allowed_paths:
          - lib
          - test
        source: working-tree
        include_untracked: true
        include_ignored: false
        write: false
        timeout: 20m
        budget:
          tokens: 30000
          cost_micros: 4000000
          time_ms: 900000
          tool_calls: 250
        """
      )

    assert {:ok, values} = SessionTaskFile.load(path)
    assert values.task == "Repair persistence and verify restart behavior."
    assert values.repository == Path.expand("../repository", Path.dirname(path))
    assert values.sandbox == "apple-container"
    assert values.network == "unrestricted"
    assert values.allow_unrestricted_network?
    assert values.allowed_paths == ["lib", "test"]
    assert values.source_mode == "working-tree"
    assert values.include_untracked?
    refute values.include_ignored?
    refute values.write?
    assert values.timeout_ms == 1_200_000
    assert values.budget_tokens == 30_000
    assert values.budget_time_ms == 900_000
  end

  test "inherits timeout as the budget time when YAML omits budget time_ms" do
    path = write_file("task.yml", "task: Verify the patch.\ntimeout_ms: 60000\n")

    assert {:ok, %{timeout_ms: 60_000, budget_time_ms: 60_000}} =
             SessionTaskFile.load(path)
  end

  test "rejects unknown, conflicting, and malformed YAML authority" do
    cases = [
      {"unknown.yaml", "task: Fix it.\nprivileged: true\n", :session_task_file_unknown_fields},
      {"budget.yaml", "task: Fix it.\nbudget:\n  dollars: 5\n",
       :session_task_file_budget_unknown_fields},
      {"aliases.yaml", "task: One.\nobjective: Two.\n", :session_task_file_conflicting_fields},
      {"timeout.yaml", "task: Fix it.\ntimeout: soon\n", :session_task_file_timeout_invalid},
      {"paths.yaml", "task: Fix it.\nallowed_paths: lib\n", :session_task_file_field_invalid},
      {"version.yaml", "version: 2\ntask: Fix it.\n", :session_task_file_version_unsupported}
    ]

    for {name, contents, expected} <- cases do
      path = write_file(name, contents)
      assert {:error, reason} = SessionTaskFile.load(path)
      assert inspect(reason) =~ Atom.to_string(expected)
    end
  end

  test "rejects empty, unsupported, missing, and oversized files" do
    assert {:error, :session_task_file_empty} = SessionTaskFile.load(write_file("empty.md", "  "))

    assert {:error, {:session_task_file_extension_unsupported, ".txt"}} =
             SessionTaskFile.load(write_file("task.txt", "Fix it."))

    missing = Path.join(temp_root(), "missing.md")
    assert {:error, {:session_task_file_not_found, ^missing}} = SessionTaskFile.load(missing)

    large = write_file("large.md", String.duplicate("x", 20))
    assert {:error, :session_task_file_too_large} = SessionTaskFile.load(large, max_bytes: 10)
  end

  defp write_file(relative, contents) do
    path = Path.join(temp_root(), relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp temp_root do
    case Process.get(:session_task_file_root) do
      nil ->
        root =
          Path.join(
            System.tmp_dir!(),
            "twelvgaige-session-task-file-#{System.unique_integer([:positive])}"
          )

        File.mkdir_p!(root)
        Process.put(:session_task_file_root, root)
        on_exit(fn -> File.rm_rf!(root) end)
        root

      root ->
        root
    end
  end
end
