defmodule Twelvgaige.Manager.ChildFactoryTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.{Budget, ChildFactory, ChildRecord}
  alias Twelvgaige.Manager.Plan.Task

  test "derives stable workspace and delegated-session identities before allocation" do
    child = child()

    binder = fn workspace, session_id ->
      {:ok, Map.put(workspace, :owner_session_id, session_id)}
    end

    assert {:ok, prepared} =
             ChildFactory.prepare(child,
               workspace_resolver: fn _id -> {:error, :not_found} end,
               workspace_allocator: fn allocating ->
                 assert String.starts_with?(allocating.workspace_id, "ws_")
                 {:ok, %{id: allocating.workspace_id, base_commit: "base"}}
               end,
               workspace_binder: binder
             )

    assert String.starts_with?(prepared.delegated_session_id, "sess_")

    assert {:ok, recovered} =
             ChildFactory.prepare(child,
               workspace_resolver: fn id ->
                 assert id == prepared.workspace_id
                 {:ok, %{id: id, base_commit: "base"}}
               end,
               workspace_allocator: fn _child -> flunk("must resolve the exact workspace") end,
               workspace_binder: binder
             )

    assert recovered.workspace_id == prepared.workspace_id
    assert recovered.delegated_session_id == prepared.delegated_session_id
  end

  defp child do
    budget = %Budget{tokens: 10, cost_micros: 10, time_ms: 10_000, tool_calls: 10}

    task = %Task{
      id: "task",
      agent: "codex",
      workflow: "coding.change.v1",
      objective: "change code",
      repository: "repo",
      base_ref: "main",
      auth_profile_id: "api",
      sandbox_profile: :coding_restricted,
      network_mode: :broker_only,
      budget: budget,
      deadline: DateTime.add(DateTime.utc_now(), 300)
    }

    %ChildRecord{
      id: "child-stable",
      plan_id: "plan",
      task_id: "task",
      attempt: 0,
      round_id: "round",
      shot_id: "shot",
      parent_session_id: "parent",
      task: task,
      budget: budget,
      deadline: task.deadline,
      created_at: DateTime.utc_now()
    }
  end
end
