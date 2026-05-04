defmodule Twelvgaige.Shell.AdmissionTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Admission
  alias Twelvgaige.Shell.Digest
  alias Twelvgaige.Shell.Workflow

  test "manual policy permits draft workflows without approval metadata" do
    {:ok, workflow} = Workflow.from_map(workflow_map(:draft))

    assert {:ok, report} = Admission.report(workflow, policy: :manual)
    assert report.status == :ok
    assert report.findings == []
    assert :ok = Admission.check(workflow, policy: :manual)
  end

  test "approved policy requires approved or scheduled lifecycle and current approval digest" do
    {:ok, workflow} = Workflow.from_map(workflow_map(:draft))

    assert {:ok, report} = Admission.report(workflow, policy: :approved)
    assert report.status == :failed
    assert Enum.any?(report.findings, &(&1.id == "lifecycle.approval_required"))
    assert Enum.any?(report.findings, &(&1.id == "approval.digest.missing"))
    assert {:error, error} = Admission.check(workflow, policy: :approved)
    assert error.reason == :policy_denied
  end

  test "approved policy accepts approved workflows with current approval digest" do
    workflow = approved_workflow!(:approved)

    assert {:ok, report} = Admission.report(workflow, policy: :approved)
    assert report.status == :ok
    assert report.findings == []
  end

  test "scheduled policy requires scheduled lifecycle" do
    workflow = approved_workflow!(:approved)

    assert {:ok, report} = Admission.report(workflow, policy: :scheduled)
    assert report.status == :failed
    assert Enum.any?(report.findings, &(&1.id == "lifecycle.scheduled_required"))
  end

  test "scheduled policy rejects expired approval metadata" do
    workflow = approved_workflow!(:scheduled, expires_at: "2026-05-03T00:00:00Z")

    assert {:ok, report} =
             Admission.report(workflow,
               policy: :scheduled,
               now: DateTime.from_iso8601("2026-05-04T00:00:00Z") |> elem(1)
             )

    assert report.status == :failed
    assert Enum.any?(report.findings, &(&1.id == "approval.expired"))
  end

  test "retired workflow warns for manual policy and fails stricter policies" do
    {:ok, workflow} = Workflow.from_map(workflow_map(:retired))

    assert {:ok, manual} = Admission.report(workflow, policy: :manual)
    assert manual.status == :ok
    assert Enum.any?(manual.findings, &(&1.id == "lifecycle.retired"))

    assert {:ok, approved} = Admission.report(workflow, policy: :approved)
    assert approved.status == :failed
    assert Enum.any?(approved.findings, &(&1.id == "lifecycle.retired"))
  end

  defp approved_workflow!(lifecycle, opts \\ []) do
    base_map = workflow_map(lifecycle)
    {:ok, base} = Workflow.from_map(base_map)
    digest = Digest.workflow_subject_digest(base)

    approval =
      %{
        workflow_digest: digest,
        approver: "human:approver",
        approved_at: "2026-05-03T00:00:00Z",
        scope: "prod"
      }
      |> maybe_put(:expires_at, Keyword.get(opts, :expires_at))

    {:ok, workflow} =
      base_map
      |> put_in([:metadata, :approval], approval)
      |> Workflow.from_map()

    workflow
  end

  defp workflow_map(lifecycle) do
    %{
      kind: :workflow,
      id: "admission_test",
      version: "1.0.0",
      metadata: %{owner: "platform", lifecycle: lifecycle},
      shots: [
        %{
          id: "inspect",
          kind: :slug,
          agent: "agent",
          timeout: "1m",
          output_schema: %{
            type: :object,
            required: ["summary"],
            properties: %{summary: %{type: :string}}
          }
        }
      ]
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
