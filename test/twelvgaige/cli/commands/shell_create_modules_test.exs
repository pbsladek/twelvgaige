defmodule Twelvgaige.CLI.Commands.ShellCreateModulesTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Commands.ShellDraft
  alias Twelvgaige.CLI.Commands.ShellNew

  test "shell new module prints scaffold output without writing" do
    assert {:ok, output, 0} = ShellNew.new("demo", ["--scaffold", "single-shot"])

    path = write_file!("demo.yaml", output)
    assert {:ok, workflow} = Twelvgaige.Shell.Loader.load(path)
    assert workflow.id == "demo"
    assert Enum.map(workflow.shots, & &1.id) == ["analyze"]
  end

  test "shell new module writes workflow and mock agents with force semantics" do
    root = tmp_dir!("twelvgaige_shell_new_modules")
    output_path = Path.join(root, "workflows/incident.yaml")

    assert {:ok, output, 0} =
             ShellNew.new("incident", [
               "--scaffold",
               "inspect-analyze-gate-fix-verify",
               "--output",
               output_path,
               "--with-mock-agents",
               "--write",
               "--root",
               root
             ])

    assert output =~ "created workflow shell: #{output_path}"
    assert output =~ "created agent shell:"
    assert {:ok, workflow} = Twelvgaige.Shell.Loader.load(output_path)
    assert workflow.id == "incident"

    assert {:ok, output, 4} =
             ShellNew.new("incident", ["--output", output_path, "--write", "--root", root])

    assert output =~ "output file already exists"
  end

  test "shell draft module prints a validated candidate without writing" do
    source = write_file!("request.txt", "review failed CI and summarize likely root cause")

    assert {:ok, output, 0} = ShellDraft.draft(["--from", source])

    path = write_file!("drafted.yaml", output)
    assert {:ok, workflow} = Twelvgaige.Shell.Loader.load(path)
    assert workflow.id == "drafted_workflow"
  end

  test "shell draft module requires write for output and can write a strict-linted draft" do
    root = tmp_dir!("twelvgaige_shell_draft_modules")
    source = Path.join(root, "request.txt")
    output_path = Path.join(root, "workflows/drafted.yaml")
    File.write!(source, "build a guarded review workflow")

    assert {:ok, output, 4} =
             ShellDraft.draft(["--from", source, "--output", output_path, "--root", root])

    assert output =~ "--write"
    refute File.exists?(output_path)

    assert {:ok, output, 0} =
             ShellDraft.draft([
               "--from",
               source,
               "--output",
               output_path,
               "--write",
               "--root",
               root
             ])

    assert output == "created draft workflow shell: #{output_path}\n"
    assert {:ok, workflow} = Twelvgaige.Shell.Loader.load(output_path)
    assert workflow.id == "drafted_workflow"
  end

  test "shell draft module rejects hosted providers without explicit remote consent" do
    source = write_file!("request.txt", "draft using OpenAI")

    assert {:ok, output, 7} = ShellDraft.draft(["--from", source, "--provider", "openai"])
    assert output =~ "hosted provider drafting requires --allow-remote"
  end

  defp write_file!(name, contents) do
    root = tmp_dir!("twelvgaige_shell_create_modules")
    path = Path.join(root, name)
    File.write!(path, contents)
    path
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
