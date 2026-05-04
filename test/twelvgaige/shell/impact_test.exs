defmodule Twelvgaige.Shell.ImpactTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Impact

  test "reports workflows and shots impacted by an agent" do
    root = write_collection!()

    assert {:ok, report} = Impact.run(root, :agent, "operator")

    assert report.status == :ok
    assert report.selector == %{"kind" => "agent", "value" => "operator"}
    assert report.summary == %{"workflow_count" => 1, "shot_count" => 2, "error_count" => 0}

    assert [
             %{
               "id" => "deploy_check",
               "matching_shots" => [
                 %{"id" => "inspect", "agent" => "operator"},
                 %{"id" => "apply", "agent" => "operator", "write_capable" => true}
               ]
             }
           ] = report.matches
  end

  test "reports workflows and shots impacted by a tool" do
    root = write_collection!()

    assert {:ok, report} = Impact.run(root, :tool, "kubectl_apply")

    assert report.summary["workflow_count"] == 1
    assert report.summary["shot_count"] == 1

    assert [%{"matching_shots" => [%{"id" => "apply", "tools" => ["kubectl_apply"]}]}] =
             report.matches
  end

  test "reports workflows and shots impacted by a template" do
    root = write_collection!()

    assert {:ok, report} = Impact.run(root, :template, "deploy.apply")

    assert report.summary["workflow_count"] == 1
    assert report.summary["shot_count"] == 1

    assert [%{"matching_shots" => [%{"id" => "apply", "templates" => ["deploy.apply"]}]}] =
             report.matches
  end

  test "keeps invalid shell errors from inventory" do
    root = write_collection!()
    invalid_path = Path.join(root, "broken.yaml")
    File.write!(invalid_path, "kind: workflow\nid: broken\n")

    assert {:ok, report} = Impact.run(root, :tool, "kubectl_apply")

    assert report.status == :degraded
    assert report.summary["error_count"] == 1
    assert [%{"path" => ^invalid_path, "error" => %{"reason" => "invalid_shell"}}] = report.errors
  end

  defp write_collection! do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-impact-#{System.unique_integer([:positive, :monotonic])}"
      )

    workflow_path = Path.join(root, "workflows/deploy.yaml")
    agent_path = Path.join(root, "workflows/agents/operator.yaml")
    File.mkdir_p!(Path.dirname(agent_path))
    File.write!(workflow_path, workflow_yaml())
    File.write!(agent_path, agent_yaml())
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp workflow_yaml do
    """
    kind: workflow
    id: deploy_check
    version: 1.0.0
    metadata:
      owner: platform
      lifecycle: reviewed
    shots:
      - id: inspect
        kind: slug
        agent: operator
        tools: [kubectl_get]
      - id: approval
        kind: safety
        depends_on: [inspect]
      - id: apply
        kind: slug
        agent: operator
        depends_on: [approval]
        tools: [kubectl_apply]
        metadata:
          generated_by:
            tool: twelvgaige
            command: shot add
            version: 0.0.1
            source:
              kind: template
              id: deploy.apply
              version: 1.0.0
    """
  end

  defp agent_yaml do
    """
    kind: agent
    id: operator
    version: 1.0.0
    provider: mock
    model: mock-model
    system_prompt: Operate carefully.
    """
  end
end
