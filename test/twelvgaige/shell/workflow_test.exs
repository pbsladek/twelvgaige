defmodule Twelvgaige.Shell.WorkflowTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Workflow

  test "builds a workflow shell from a map" do
    assert {:ok, workflow} =
             Workflow.from_map(%{
               "kind" => "workflow",
               "id" => "k8s_incident_response",
               "name" => "K8s Incident Response",
               "version" => "1.0.0",
               "timeout" => "30m",
               "policy" => %{"resource_profile" => "laptop"},
               "input_schema" => %{
                 "type" => "object",
                 "required" => ["cluster"],
                 "properties" => %{"cluster" => %{"type" => "string"}}
               },
               "shots" => [
                 %{
                   "id" => "gather",
                   "kind" => "slug",
                   "agent" => "k8s_inspector",
                   "timeout" => "2m",
                   "tools" => ["kubectl_get"],
                   "output_schema" => %{
                     "type" => "object",
                     "properties" => %{"ok" => %{"type" => "boolean"}}
                   }
                 },
                 %{
                   "id" => "approval",
                   "kind" => "safety",
                   "depends_on" => ["gather"],
                   "condition" => true
                 }
               ]
             })

    assert workflow.id == "k8s_incident_response"
    assert workflow.timeout_ms == 1_800_000
    assert workflow.policy.resource_profile == :laptop
    assert Enum.map(workflow.shots, & &1.id) == ["gather", "approval"]
    assert hd(workflow.shots).tools == ["kubectl_get"]
  end

  test "rejects missing required fields" do
    base = %{
      kind: :workflow,
      id: "missing_required",
      version: "1.0.0",
      shots: [
        %{id: "gather", kind: :slug, agent: "agent"}
      ]
    }

    for field <- [:kind, :id, :version, :shots] do
      assert {:error, error} = base |> Map.delete(field) |> Workflow.from_map()

      assert error.reason == :invalid_shell
      assert error.details.field == Atom.to_string(field)
    end
  end

  test "rejects duplicate shot IDs" do
    assert {:error, error} =
             Workflow.from_map(%{
               kind: :workflow,
               id: "dupe",
               version: "1.0.0",
               shots: [
                 %{id: "same", kind: :slug, agent: "agent"},
                 %{id: "same", kind: :slug, agent: "agent"}
               ]
             })

    assert error.reason == :invalid_shell
    assert error.details.duplicate == "same"
  end

  test "rejects tools on safety shots" do
    assert {:error, error} =
             Workflow.from_map(%{
               kind: :workflow,
               id: "unsafe",
               version: "1.0.0",
               shots: [
                 %{id: "approval", kind: :safety, tools: ["kubectl_get"]}
               ]
             })

    assert error.reason == :invalid_shell
    assert error.details.path == ["shots", 0, "tools"]
  end
end
