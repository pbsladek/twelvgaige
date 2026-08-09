defmodule Twelvgaige.Authoring.ScaffoldTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Authoring.Scaffold
  alias Twelvgaige.Shell.Graph
  alias Twelvgaige.Shell.Lint
  alias Twelvgaige.Shell.Workflow

  test "expands the single-shot scaffold to a valid workflow" do
    assert {:ok, expansion} = Scaffold.expand("single-shot", "demo")
    assert expansion.scaffold == "single-shot"
    assert expansion.agents == []

    assert {:ok, workflow} = Workflow.from_map(expansion.workflow)
    assert workflow.id == "demo"
    assert workflow.metadata.lifecycle == :draft
    assert workflow.metadata.generated_by["source"]["id"] == "single-shot"
    assert workflow.metadata.generated_by["source"]["hash"] =~ "sha256:"
    assert Enum.map(workflow.shots, & &1.id) == ["analyze"]
    assert {:ok, _graph} = Graph.build(workflow)
    assert Lint.run(workflow, strict?: true).status == :ok
  end

  test "expands remediation scaffold with direct safety gate before write shot" do
    assert {:ok, expansion} =
             Scaffold.expand("inspect-analyze-gate-fix-verify", "incident_demo")

    assert {:ok, workflow} = Workflow.from_map(expansion.workflow)

    assert Enum.map(workflow.shots, & &1.id) == [
             "inspect",
             "analyze",
             "approval",
             "remediate",
             "verify"
           ]

    remediate = Enum.find(workflow.shots, &(&1.id == "remediate"))
    assert remediate.depends_on == ["approval"]
    assert remediate.tools == ["kubectl_apply"]
    assert Lint.run(workflow, strict?: true).status == :ok
  end

  test "rejects unknown scaffolds" do
    assert {:error, error} = Scaffold.expand("missing", "demo")
    assert error.reason == :invalid_shell
    assert error.details.known_scaffolds == Scaffold.names()
  end

  test "loads and expands local scaffolds from explicit paths" do
    root = tmp_dir!()
    scaffolds_dir = Path.join(root, "scaffolds")
    File.mkdir_p!(scaffolds_dir)
    File.write!(Path.join(scaffolds_dir, "team.review.yaml"), local_scaffold_yaml())

    assert {:ok, scaffolds} = Scaffold.list(scaffold_paths: [scaffolds_dir])
    assert Enum.any?(scaffolds, &(&1.namespace == "team" and &1.id == "team.review"))

    assert {:ok, expansion} =
             Scaffold.expand("team/team.review", "review_flow", scaffold_paths: [scaffolds_dir])

    assert expansion.scaffold == "team/team.review"
    assert [%{"id" => "reviewer"}] = expansion.agents

    assert {:ok, workflow} = Workflow.from_map(expansion.workflow)
    assert workflow.id == "review_flow"
    assert workflow.metadata.generated_by["source"]["namespace"] == "team"
    assert workflow.metadata.generated_by["source"]["digest"] =~ "sha256:"
  end

  test "writes verifies updates and scans scaffold lock entries" do
    root = tmp_dir!()
    scaffolds_dir = Path.join(root, "scaffolds")
    workflow_path = Path.join(root, "workflows/review.yaml")
    scaffold_path = Path.join(scaffolds_dir, "team.review.yaml")
    File.mkdir_p!(scaffolds_dir)
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(scaffold_path, local_scaffold_yaml())

    assert {:ok, missing_report} = Scaffold.verify(root: root, scaffold_paths: [scaffolds_dir])
    assert missing_report["status"] == "failed"
    assert [%{"status" => "missing_lockfile"}] = missing_report["findings"]

    assert {:ok, write_report} =
             Scaffold.verify(root: root, scaffold_paths: [scaffolds_dir], write_lock?: true)

    assert write_report["status"] == "ok"

    assert {:ok, expansion} =
             Scaffold.expand("team/team.review", "review_flow", scaffold_paths: [scaffolds_dir])

    {:ok, contents} = Twelvgaige.Shell.Document.encode(expansion.workflow, :yaml)
    File.write!(workflow_path, contents)

    assert {:ok, report} = Scaffold.outdated(root, root: root, scaffold_paths: [scaffolds_dir])
    assert report["status"] == "ok"
    assert report["checked_workflows"] == 1

    File.write!(
      scaffold_path,
      String.replace(local_scaffold_yaml(), "Review input.", "Review drift.")
    )

    assert {:ok, verify_report} = Scaffold.verify(root: root, scaffold_paths: [scaffolds_dir])

    assert [%{"status" => "digest_mismatch", "scaffold" => "team/team.review"}] =
             verify_report["findings"]

    assert {:ok, drift_report} =
             Scaffold.outdated(root, root: root, scaffold_paths: [scaffolds_dir])

    assert [%{"status" => "digest_mismatch", "scaffold" => "team/team.review"}] =
             drift_report["findings"]

    assert {:ok, update_report} = Scaffold.update(root: root, scaffold_paths: [scaffolds_dir])
    assert update_report["changed"]
    assert update_report["diff"] =~ ~s(+  - digest: "sha256:)
  end

  defp local_scaffold_yaml do
    """
    kind: scaffold
    namespace: team
    id: team.review
    version: 1.0.0
    description: Team review workflow
    workflow:
      shots:
        - id: review
          kind: slug
          agent: reviewer
          prompt: Review input.
          output_schema:
            type: object
            required: [summary]
            properties:
              summary:
                type: string
    agents:
      - kind: agent
        id: reviewer
        version: 1.0.0
        provider: ollama
        model: llama3.2
        system_prompt: Review agent
    """
  end

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-scaffold-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
