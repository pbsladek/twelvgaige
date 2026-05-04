defmodule Twelvgaige.Shell.InventoryTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Inventory

  test "summarizes workflows agents tools lifecycle and invalid shells" do
    root = tmp_root()
    workflow_path = Path.join(root, "workflows/deploy.yaml")
    agent_path = Path.join(root, "workflows/agents/operator.yaml")
    invalid_path = Path.join(root, "workflows/broken.yaml")

    File.mkdir_p!(Path.dirname(agent_path))
    File.write!(workflow_path, workflow_yaml())
    File.write!(agent_path, agent_yaml())
    File.write!(invalid_path, "kind: workflow\nid: broken\n")

    assert {:ok, report} = Inventory.run(root)

    assert report.status == :degraded
    assert report.exit_code == 0
    assert report.summary["workflow_count"] == 1
    assert report.summary["agent_count"] == 1
    assert report.summary["error_count"] == 1
    assert report.summary["tools"] == ["kubectl_apply", "kubectl_get"]
    assert report.summary["lifecycles"] == %{"approved" => 1}
    assert report.summary["owners"] == %{"platform" => 1}

    assert [
             %{
               "path" => ^workflow_path,
               "id" => "deploy_check",
               "owner" => "platform",
               "lifecycle" => "approved",
               "write_capable" => true,
               "agents" => ["operator"],
               "providers" => ["mock"],
               "tools" => ["kubectl_apply", "kubectl_get"],
               "write_tools" => ["kubectl_apply"],
               "templates" => ["deploy.apply"],
               "safety_shots" => ["approval"],
               "graph" => %{"status" => "ok"}
             }
           ] = report.workflows

    assert [%{"path" => ^agent_path, "id" => "operator", "provider" => "mock"}] = report.agents
    assert [%{"path" => ^invalid_path, "error" => %{"reason" => "invalid_shell"}}] = report.errors

    assert %{
             path: ^root,
             status: "degraded",
             exit_code: 0,
             workflows: [_],
             agents: [_],
             errors: [_]
           } = Inventory.to_map(report)
  end

  test "reports missing agent references without failing inventory" do
    root = tmp_root()
    workflow_path = Path.join(root, "workflow.yaml")
    File.write!(workflow_path, String.replace(workflow_yaml(), "operator", "missing_agent"))

    assert {:ok, report} = Inventory.run(root)

    assert [%{"missing_agents" => ["missing_agent"], "providers" => ["unknown"]}] =
             report.workflows

    assert report.status == :ok
  end

  defp tmp_root do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-inventory-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
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
      lifecycle: approved
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
    tools:
      allowed: [kubectl_get, kubectl_apply]
    """
  end
end
