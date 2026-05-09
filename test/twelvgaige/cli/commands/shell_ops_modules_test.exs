defmodule Twelvgaige.CLI.Commands.ShellOpsModulesTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Commands.ShellAnalysisOps
  alias Twelvgaige.CLI.Commands.ShellDocumentOps

  @workflow_path "test/fixtures/shells/simple_workflow.yaml"

  test "document ops normalize shells without going through CLI main" do
    assert {:ok, output, 0} = ShellDocumentOps.normalize(@workflow_path, ["--format", "json"])

    assert %{"kind" => "workflow", "id" => "simple", "shots" => shots} = Jason.decode!(output)
    assert Enum.map(shots, & &1["id"]) == ["first", "second"]
  end

  test "document ops convert can write an output file" do
    root = tmp_dir!("twelvgaige_shell_document_ops")
    output_path = Path.join(root, "converted.yaml")

    assert {:ok, output, 0} =
             ShellDocumentOps.convert("test/fixtures/shells/simple_workflow.toml", [
               "--to",
               "yaml",
               "--output",
               output_path
             ])

    assert output == "converted shell: #{output_path}\n"
    assert {:ok, workflow} = Twelvgaige.validate_shell(output_path)
    assert workflow.id == "simple"
  end

  test "document ops fmt supports dry-run, check, and write behavior" do
    path = write_file!("messy.yaml", messy_workflow_yaml())

    assert {:ok, output, 0} = ShellDocumentOps.fmt(path, [])
    assert output =~ "dry run: shell fmt #{path}"
    assert File.read!(path) =~ "version: 1.0.0"

    assert {:ok, output, 1} = ShellDocumentOps.fmt(path, ["--check"])
    assert output == "shell fmt check failed: #{path} is not canonical\n"

    assert {:ok, output, 0} = ShellDocumentOps.fmt(path, ["--write"])
    assert output =~ "formatted shell: #{path}"

    assert {:ok, output, 0} = ShellDocumentOps.fmt(path, ["--check"])
    assert output == "shell fmt check passed: #{path}\n"
  end

  test "analysis ops graph, lint, admit, and doctor expose stable direct command boundaries" do
    assert {:ok, graph_output, 0} = ShellAnalysisOps.graph(@workflow_path, ["--format", "json"])

    assert %{"workflow_id" => "simple", "groups" => [["first"], ["second"]]} =
             Jason.decode!(graph_output)

    assert {:ok, lint_output, 0} =
             ShellAnalysisOps.lint(@workflow_path, ["--format", "json", "--strict"])

    assert %{"status" => "ok", "findings" => findings} = Jason.decode!(lint_output)
    assert Enum.any?(findings, &(&1["id"] == "shot.output_schema.missing"))

    assert {:ok, admit_output, 1} =
             ShellAnalysisOps.admit(@workflow_path, ["--policy", "approved", "--format", "json"])

    assert %{"policy" => "approved", "status" => "failed"} = Jason.decode!(admit_output)

    assert {:ok, doctor_output, 0} = ShellAnalysisOps.doctor(@workflow_path, ["--format", "json"])
    assert %{"workflow_id" => "simple", "status" => "attention"} = Jason.decode!(doctor_output)
  end

  test "analysis ops keep JSON error shape for non-workflow inputs" do
    path = write_file!("agent.yaml", agent_yaml())

    assert {:ok, output, 4} = ShellAnalysisOps.graph(path, ["--format", "json"])

    assert %{"error" => %{"message" => message, "reason" => "invalid_shell"}} =
             Jason.decode!(output)

    assert message =~ "requires a workflow shell"
  end

  defp write_file!(name, contents) do
    root = tmp_dir!("twelvgaige_shell_ops_modules")
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

  defp messy_workflow_yaml do
    """
    version: 1.0.0
    shots:
      - timeout: 1m
        agent: agent
        kind: slug
        id: inspect
    kind: workflow
    id: fmt_demo
    """
  end

  defp agent_yaml do
    """
    kind: agent
    id: agent
    name: Agent
    version: 1.0.0
    provider: mock
    model: mock-model
    system_prompt: Run.
    """
  end
end
