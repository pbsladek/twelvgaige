defmodule Twelvgaige.Manager.IntegrationTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Handoff
  alias Twelvgaige.Manager.{Budget, ChildRecord, Integration, Verifier}
  alias Twelvgaige.Manager.Plan.Task

  test "captures typed worker changes in a separate integration workspace for independent review" do
    workers = [child("one", "worker-a"), child("two", "worker-b")]

    allocator = fn first ->
      {:ok, %{id: "integration-ws", base_commit: "base", task: first.task}}
    end

    applier = fn workspace, children ->
      assert workspace.id == "integration-ws"
      assert Enum.map(children, & &1.handoff.diff_artifact) == ["patch:one", "patch:two"]
      {:ok, %{head_commit: "candidate", commit: "candidate", patch_artifact: "patch:combined"}}
    end

    assert {:ok, candidate} =
             Integration.build("plan", workers,
               workspace_allocator: allocator,
               artifact_applier: applier
             )

    assert candidate.status == :awaiting_verification
    assert candidate.workspace_id == "integration-ws"
    assert candidate.commit == "candidate"
    refute function_exported?(Integration, :merge, 2)

    assert {:error, :manager_verifier_not_independent} =
             Verifier.verify(candidate, ["worker-a", "worker-b"], "worker-a", fn _ ->
               {:ok, %{}}
             end)

    assert {:ok, verified} =
             Verifier.verify(candidate, ["worker-a", "worker-b"], "reviewer", fn candidate ->
               {:ok, %{patch: candidate.patch_artifact, tests: "artifact:tests"}}
             end)

    assert verified.status == :verified
    assert verified.verification.principal == "reviewer"

    assert {:error, :manager_artifact_applier_required} =
             Integration.build("plan", workers, workspace_allocator: allocator)

    assert {:error, :manager_integration_workspace_not_isolated} =
             Integration.build("plan", workers,
               workspace_allocator: fn _first ->
                 {:ok, %{id: "ws-one", base_commit: "base"}}
               end,
               artifact_applier: applier
             )
  end

  defp child(id, principal) do
    budget = %Budget{tokens: 10, cost_micros: 10, time_ms: 10, tool_calls: 10}

    task = %Task{
      id: id,
      agent: "codex",
      workflow: "coding.change.v1",
      objective: id,
      repository: "repo",
      base_ref: "main",
      auth_profile_id: "api",
      sandbox_profile: :coding_restricted,
      network_mode: :broker_only,
      budget: budget
    }

    %ChildRecord{
      id: "child-#{id}",
      plan_id: "plan",
      task_id: id,
      attempt: 0,
      round_id: "round",
      shot_id: "shot",
      parent_session_id: "parent",
      delegated_session_id: "session-#{id}",
      workspace_id: "ws-#{id}",
      task: task,
      budget: budget,
      principal: principal,
      status: :completed,
      created_at: DateTime.utc_now(),
      handoff:
        Handoff.new(%{
          objective_status: :complete,
          summary: id,
          workspace_id: "ws-#{id}",
          base_commit: "base",
          diff_artifact: "patch:#{id}",
          claims: [%{claim: "#{id} changed", evidence: "patch:#{id}"}],
          artifacts: ["artifact:#{id}"]
        })
    }
  end
end
