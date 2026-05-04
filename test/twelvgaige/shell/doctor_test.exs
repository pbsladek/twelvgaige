defmodule Twelvgaige.Shell.DoctorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Doctor
  alias Twelvgaige.Shell.Workflow

  test "turns lint findings into repair recommendations" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "doctor_demo",
        version: "1.0.0",
        shots: [
          %{id: "step1", kind: :slug, agent: "agent"},
          %{id: "apply", kind: :slug, agent: "agent", tools: ["kubectl_apply"]}
        ]
      })

    report = Doctor.run(workflow, path: "workflow.yaml", strict?: true)

    assert report.path == "workflow.yaml"
    assert report.workflow_id == "doctor_demo"
    assert report.status == :failed
    assert report.exit_code == 1

    ids = Enum.map(report.recommendations, & &1.id)
    assert "shot.safety.write_without_gate" in ids
    assert "shot.output_schema.missing" in ids
    assert "shot.timeout.missing" in ids

    assert Enum.any?(report.recommendations, fn recommendation ->
             recommendation.id == "shot.safety.write_without_gate" and
               recommendation.action =~ "Add a safety shot"
           end)
  end

  test "adds graph recommendations for intentionally parallel review" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "parallel_demo",
        version: "1.0.0",
        shots: [
          %{id: "inspect_a", kind: :slug, agent: "agent", timeout: "1m", output_schema: schema()},
          %{id: "inspect_b", kind: :slug, agent: "agent", timeout: "1m", output_schema: schema()}
        ]
      })

    report = Doctor.run(workflow)

    assert report.status == :attention
    assert Enum.any?(report.recommendations, &(&1.id == "graph.dependencies.none"))
  end

  test "reports ok when no recommendations are produced" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "doctor_ok",
        version: "1.0.0",
        metadata: %{owner: "platform", lifecycle: "reviewed"},
        shots: [
          %{
            id: "inspect_state",
            kind: :slug,
            agent: "agent",
            timeout: "1m",
            output_schema: schema()
          }
        ]
      })

    report = Doctor.run(workflow, strict?: true)

    assert report.status == :ok
    assert report.exit_code == 0
    assert report.recommendations == []
  end

  test "serializes stable map output" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "doctor_map",
        version: "1.0.0",
        shots: [%{id: "inspect", kind: :slug, agent: "agent"}]
      })

    report = workflow |> Doctor.run() |> Doctor.to_map()

    assert %{
             path: "<memory>",
             workflow_id: "doctor_map",
             status: "attention",
             recommendations: [_ | _],
             lint: %{status: "ok"},
             graph: %{workflow_id: "doctor_map"},
             errors: []
           } = report
  end

  defp schema do
    %{
      type: :object,
      required: ["summary"],
      properties: %{summary: %{type: :string}}
    }
  end
end
