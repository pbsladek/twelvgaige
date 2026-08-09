defmodule Twelvgaige.Manager.Executor.CodexTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession.Codex.AuthProfile
  alias Twelvgaige.Handoff
  alias Twelvgaige.Manager.{Budget, ChildRecord}
  alias Twelvgaige.Manager.Executor.Codex
  alias Twelvgaige.Manager.Plan.Task

  test "builds an unattended, identity-bound delegated Codex session" do
    parent = self()
    child = child()

    auth =
      AuthProfile.new(%{
        id: "api",
        type: :brokered_service,
        revision: 7,
        credential_lease_id: "lease",
        broker_endpoint: "https://broker.invalid"
      })

    runner = fn session, received_child, descriptor ->
      send(parent, {:session, session, received_child, descriptor})

      {:ok,
       %{
         handoff:
           Handoff.new(%{
             objective_status: :complete,
             summary: "done",
             workspace_id: child.workspace_id,
             base_commit: "base",
             diff_artifact: "artifact:patch"
           }),
         usage: %{tokens: 10, cost_micros: 20, time_ms: 30, tool_calls: 1}
       }}
    end

    assert {:ok, %{principal: "codex:api:session-child", handoff: %Handoff{}}} =
             Codex.run(child,
               workspace_resolver: fn "ws-child" ->
                 {:ok, %{id: "ws-child", base_commit: "base"}}
               end,
               auth_profiles: %{"api" => auth},
               sandbox_manifest_resolver: fn _child -> {:ok, String.duplicate("a", 64)} end,
               policy_revision: "policy-1",
               session_runner: runner
             )

    assert_receive {:session, session, ^child, descriptor}
    assert session.id == child.delegated_session_id
    assert session.workspace_id == child.workspace_id
    assert session.auth_revision == 7
    assert session.runtime == :codex
    assert session.effective_capabilities == child.task.capabilities
    assert descriptor.capabilities.native_subagents
  end

  test "rejects ambient local login for unattended manager children" do
    child = child()

    auth =
      AuthProfile.new(%{
        id: "api",
        type: :local_user,
        revision: 1,
        codex_home: "/tmp/codex"
      })

    assert {:error, :local_login_unattended_denied} =
             Codex.run(child,
               workspace_resolver: fn _id ->
                 {:ok, %{id: child.workspace_id, base_commit: "base"}}
               end,
               auth_profiles: %{"api" => auth},
               sandbox_manifest_resolver: fn _child -> {:ok, String.duplicate("a", 64)} end,
               policy_revision: "policy-1",
               session_runner: fn _session, _child, _descriptor -> flunk("must not run") end
             )
  end

  test "fails closed across manager identity and resolver boundaries" do
    child = child()
    wrong_agent = %{child | task: %{child.task | agent: "other"}}

    assert {:error, {:manager_executor_agent_mismatch, "codex", "other"}} =
             Codex.run(wrong_agent, [])

    assert {:error, :manager_workspace_identity_mismatch} =
             Codex.run(
               child,
               valid_opts(child,
                 workspace_resolver: fn _id -> {:ok, %{id: "other", base_commit: "base"}} end
               )
             )

    assert {:error, :workspace_unavailable} =
             Codex.run(
               child,
               valid_opts(child,
                 workspace_resolver: fn _id -> {:error, :workspace_unavailable} end
               )
             )

    assert {:error, :manager_auth_profile_not_found} =
             Codex.run(child, valid_opts(child, auth_profiles: %{}))

    assert {:error, :manager_sandbox_manifest_digest_invalid} =
             Codex.run(
               child,
               valid_opts(child, sandbox_manifest_resolver: fn _child -> {:ok, "short"} end)
             )

    assert {:error, :sandbox_unavailable} =
             Codex.run(
               child,
               valid_opts(child,
                 sandbox_manifest_resolver: fn _child -> {:error, :sandbox_unavailable} end
               )
             )
  end

  test "accepts map auth profiles and rejects invalid session results" do
    child = child()

    auth = %{
      id: "api",
      type: :brokered_service,
      revision: 1,
      credential_lease_id: "lease",
      broker_endpoint: "https://broker.invalid"
    }

    assert {:error, :manager_codex_result_invalid} =
             Codex.run(
               child,
               valid_opts(child,
                 auth_profiles: %{"api" => auth},
                 sandbox_manifest_resolver: fn _child ->
                   {:ok, "sha256:" <> String.duplicate("a", 64)}
                 end,
                 session_runner: fn _session, _child, _descriptor -> {:ok, %{invalid: true}} end
               )
             )
  end

  defp valid_opts(child, overrides) do
    Keyword.merge(
      [
        workspace_resolver: fn _id -> {:ok, %{id: child.workspace_id, base_commit: "base"}} end,
        auth_profiles: %{
          "api" =>
            AuthProfile.new(%{
              id: "api",
              type: :brokered_service,
              revision: 1,
              credential_lease_id: "lease",
              broker_endpoint: "https://broker.invalid"
            })
        },
        sandbox_manifest_resolver: fn _child -> {:ok, String.duplicate("a", 64)} end,
        policy_revision: "policy-1",
        session_runner: fn _session, _child, _descriptor -> {:ok, %{invalid: true}} end
      ],
      overrides
    )
  end

  defp child do
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
      capabilities: ["filesystem.write", "mcp.write"],
      budget: %Budget{tokens: 100, cost_micros: 100, time_ms: 100, tool_calls: 100},
      deadline: DateTime.add(DateTime.utc_now(), 300)
    }

    %ChildRecord{
      id: "child",
      plan_id: "plan",
      task_id: "task",
      attempt: 0,
      round_id: "round",
      shot_id: "shot",
      parent_session_id: "parent",
      delegated_session_id: "session-child",
      workspace_id: "ws-child",
      task: task,
      budget: task.budget,
      deadline: task.deadline,
      created_at: DateTime.utc_now()
    }
  end
end
