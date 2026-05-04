defmodule Twelvgaige.Shell.WorkflowTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Workflow

  @digest "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

  test "builds a workflow shell from a map" do
    assert {:ok, workflow} =
             Workflow.from_map(%{
               "kind" => "workflow",
               "id" => "k8s_incident_response",
               "name" => "K8s Incident Response",
               "version" => "1.0.0",
               "timeout" => "30m",
               "policy" => %{"resource_profile" => "laptop"},
               "metadata" => %{
                 "owner" => "platform",
                 "tags" => ["kubernetes", "incident"],
                 "lifecycle" => "reviewed",
                 "review" => %{
                   "workflow_digest" => @digest,
                   "reviewer" => "human:sre",
                   "reviewed_at" => "2026-05-03T00:00:00Z"
                 }
               },
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
                   "metadata" => %{
                     "purpose" => "Collect cluster evidence",
                     "owner" => "sre",
                     "last_reviewed" => "2026-05-03"
                   },
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
    assert workflow.metadata.owner == "platform"
    assert workflow.metadata.lifecycle == :reviewed
    assert workflow.metadata.review["workflow_digest"] == @digest
    assert Enum.map(workflow.shots, & &1.id) == ["gather", "approval"]
    assert hd(workflow.shots).tools == ["kubectl_get"]
    assert hd(workflow.shots).metadata.purpose == "Collect cluster evidence"
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

  test "rejects unknown metadata fields" do
    assert {:error, error} =
             Workflow.from_map(%{
               kind: :workflow,
               id: "metadata_unknown",
               version: "1.0.0",
               metadata: %{owner: "platform", arbitrary: "nope"},
               shots: [%{id: "only", kind: :slug, agent: "agent"}]
             })

    assert error.reason == :invalid_shell
    assert error.details.path == ["metadata", "arbitrary"]
  end

  test "requires digest-bound approval metadata" do
    assert {:error, error} =
             Workflow.from_map(%{
               kind: :workflow,
               id: "bad_approval",
               version: "1.0.0",
               metadata: %{
                 approval: %{
                   workflow_digest: "not-a-digest",
                   approver: "human:sre",
                   approved_at: "2026-05-03T00:00:00Z",
                   scope: "prod"
                 }
               },
               shots: [%{id: "only", kind: :slug, agent: "agent"}]
             })

    assert error.reason == :invalid_shell
    assert error.details.path == ["metadata", "approval", "workflow_digest"]
  end
end
