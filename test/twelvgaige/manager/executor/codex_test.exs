defmodule Twelvgaige.Manager.Executor.CodexTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession.Codex.AuthProfile
  alias Twelvgaige.Handoff
  alias Twelvgaige.Manager.{Budget, ChildRecord}
  alias Twelvgaige.Manager.Executor.Codex
  alias Twelvgaige.Manager.Plan.Task

  defmodule SessionRunner do
    def run(session, child, descriptor, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:default_session_runner, session, descriptor, Keyword.fetch!(opts, :adapter_config)}
      )

      {:ok,
       %{
         handoff:
           Handoff.new(%{
             objective_status: :complete,
             summary: "done",
             workspace_id: child.workspace_id,
             base_commit: session.base_commit
           }),
         usage: Budget.zero()
       }}
    end
  end

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

  test "uses the governed production session runner when no test runner is injected" do
    child = child()

    opts =
      valid_opts(child,
        session_runner: nil,
        session_runner_module: SessionRunner,
        test_pid: self()
      )

    assert {:ok, %{handoff: %Handoff{}, principal: principal}} = Codex.run(child, opts)
    assert principal == "codex:api:session-child"

    assert_receive {:default_session_runner, %{workspace_id: "ws-child"}, %{id: _descriptor_id},
                    %{auth_profile: %AuthProfile{id: "api", credential_lease_id: "lease"}}}
  end

  test "resolves one session-scoped auth context through sandboxing, the adapter, and cleanup" do
    child = child()
    parent = self()

    profile =
      AuthProfile.new(%{
        id: "dynamic-service",
        type: :brokered_service,
        revision: 9,
        credential_lease_id: "dynamic-lease",
        broker_endpoint: "https://gateway.invalid"
      })

    auth_context = %{
      profile: profile,
      environment: %{},
      credential_mount: %{source: "/private/runtime-credential-home"},
      cleanup_identity: "dynamic-lease"
    }

    runner = fn session, received_child, _descriptor ->
      send(parent, {:dynamic_auth_session, session, received_child})

      {:ok,
       %{
         handoff:
           Handoff.new(%{
             objective_status: :complete,
             summary: "done",
             workspace_id: child.workspace_id,
             base_commit: session.base_commit
           }),
         usage: Budget.zero()
       }}
    end

    assert {:ok, %{principal: "codex:dynamic-service:session-child"}} =
             Codex.run(child,
               workspace_resolver: fn _id ->
                 {:ok, %{id: child.workspace_id, base_commit: "base", path: "/managed/workspace"}}
               end,
               auth_profiles: %{},
               auth_context_resolver: fn ^child -> {:ok, auth_context} end,
               auth_cleanup_fun: fn received ->
                 send(parent, {:dynamic_auth_cleanup, received})
                 :ok
               end,
               sandbox_context_resolver: fn ^child, workspace, received ->
                 send(parent, {:dynamic_auth_sandbox, workspace, received})

                 {:ok,
                  %{
                    manifest_digest: String.duplicate("c", 64),
                    launch_spec: nil,
                    runner_opts: []
                  }}
               end,
               policy_revision: "policy-1",
               session_runner: runner
             )

    assert_receive {:dynamic_auth_sandbox, %{id: "ws-child"}, ^auth_context}
    assert_receive {:dynamic_auth_session, %{auth_profile_id: "dynamic-service"}, ^child}
    assert_receive {:dynamic_auth_cleanup, ^auth_context}
  end

  test "cleans dynamic authentication when delegated execution crashes" do
    child = child()
    parent = self()

    profile =
      AuthProfile.new(%{
        id: "dynamic-service",
        type: :brokered_service,
        revision: 9,
        credential_lease_id: "dynamic-lease",
        broker_endpoint: "https://gateway.invalid"
      })

    auth_context = %{profile: profile, environment: %{}, credential_mount: nil}

    assert {:error, :manager_codex_execution_crashed} =
             Codex.run(child,
               workspace_resolver: fn _id ->
                 {:ok, %{id: child.workspace_id, base_commit: "base"}}
               end,
               auth_profiles: %{},
               auth_context_resolver: fn ^child -> {:ok, auth_context} end,
               auth_cleanup_fun: fn received ->
                 send(parent, {:crash_auth_cleanup, received})
                 :ok
               end,
               sandbox_manifest_resolver: fn _child -> {:ok, String.duplicate("a", 64)} end,
               policy_revision: "policy-1",
               session_runner: fn _session, _child, _descriptor ->
                 raise "adapter included sk-do-not-echo"
               end
             )

    assert_receive {:crash_auth_cleanup, ^auth_context}
  end

  test "normalizes auth contexts and rejects malformed credential boundaries" do
    child = child()
    profile = valid_auth_profile()

    invalid_contexts = [
      {%{profile: profile, environment: [], credential_mount: nil},
       :manager_auth_context_environment_invalid},
      {%{profile: profile, environment: %{}, credential_mount: []},
       :manager_auth_context_mount_invalid},
      {%{profile: nil, environment: %{}, credential_mount: nil},
       :manager_auth_context_profile_invalid},
      {:invalid, :manager_auth_context_invalid}
    ]

    Enum.each(invalid_contexts, fn {context, expected} ->
      assert {:error, ^expected} =
               Codex.run(
                 child,
                 valid_opts(child, auth_context_resolver: fn ^child -> context end)
               )
    end)

    assert {:error, :credential_broker_unavailable} =
             Codex.run(
               child,
               valid_opts(child,
                 auth_context_resolver: fn ^child ->
                   {:error, :credential_broker_unavailable}
                 end
               )
             )

    string_context = %{
      "profile" => %{
        "id" => "api",
        "type" => "brokered_service",
        "revision" => 1,
        "credential_lease_id" => "lease",
        "broker_endpoint" => "broker://session"
      },
      "environment" => %{},
      "credential_mount" => nil
    }

    assert {:ok, %{handoff: %Handoff{}}} =
             Codex.run(
               child,
               valid_opts(child,
                 auth_context_resolver: fn ^child -> string_context end,
                 session_runner: successful_runner(child)
               )
             )
  end

  test "validates sandbox resolver variants before delegated execution" do
    child = child()

    invalid_contexts = [
      {{:error, :sandbox_resolver_failed}, :sandbox_resolver_failed},
      {:invalid, :manager_sandbox_context_invalid},
      {%{manifest_digest: "short", launch_spec: nil}, :manager_sandbox_manifest_digest_invalid},
      {%{manifest_digest: String.duplicate("a", 64), launch_spec: []},
       :manager_sandbox_launch_spec_invalid}
    ]

    Enum.each(invalid_contexts, fn {context, expected} ->
      assert {:error, ^expected} =
               Codex.run(
                 child,
                 valid_opts(child,
                   sandbox_context_resolver: fn ^child, _workspace -> context end
                 )
               )
    end)

    launch_spec = %{workspace: %{source: "/managed/workspace"}}

    assert {:ok, %{handoff: %Handoff{}}} =
             Codex.run(
               child,
               valid_opts(child,
                 workspace_resolver: fn _id ->
                   {:ok, %{id: child.workspace_id, base_commit: "base", path: "/result"}}
                 end,
                 sandbox_context_resolver: fn ^child, _workspace ->
                   {:ok,
                    %{
                      manifest_digest: "sha256:" <> String.duplicate("b", 64),
                      launch_spec: launch_spec,
                      runner_opts: []
                    }}
                 end,
                 session_runner: successful_runner(child)
               )
             )
  end

  test "reports auth cleanup failures without replacing the execution result" do
    child = child()

    for {cleanup, expected} <- [
          {fn _context -> {:error, :revoke_failed} end, :manager_auth_cleanup_failed},
          {fn _context -> :unexpected end, :manager_auth_cleanup_invalid}
        ] do
      assert {:error, {^expected, _detail, {:ok, %{handoff: %Handoff{}}}}} =
               Codex.run(
                 child,
                 valid_opts(child,
                   auth_cleanup_fun: cleanup,
                   session_runner: successful_runner(child)
                 )
               )
    end

    assert {:error, {:manager_auth_cleanup_crashed, "cleanup failed", {:ok, _result}}} =
             Codex.run(
               child,
               valid_opts(child,
                 auth_cleanup_fun: fn _context -> raise "cleanup failed" end,
                 session_runner: successful_runner(child)
               )
             )
  end

  test "contains exits and throws and rejects cross-workspace handoffs" do
    child = child()

    assert {:error, :manager_codex_execution_exited} =
             Codex.run(
               child,
               valid_opts(child,
                 session_runner: fn _session, _child, _descriptor -> exit(:adapter_exit) end
               )
             )

    assert {:error, :manager_codex_execution_threw} =
             Codex.run(
               child,
               valid_opts(child,
                 session_runner: fn _session, _child, _descriptor -> throw(:adapter_throw) end
               )
             )

    mismatched = fn session, _child, _descriptor ->
      {:ok,
       %{
         handoff:
           Handoff.new(%{
             objective_status: :complete,
             summary: "wrong workspace",
             workspace_id: "ws-other",
             base_commit: session.base_commit
           })
       }}
    end

    assert {:error, :manager_handoff_workspace_identity_mismatch} =
             Codex.run(child, valid_opts(child, session_runner: mismatched))
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

  defp valid_auth_profile do
    AuthProfile.new(%{
      id: "api",
      type: :brokered_service,
      revision: 1,
      credential_lease_id: "lease",
      broker_endpoint: "https://broker.invalid"
    })
  end

  defp successful_runner(child) do
    fn session, _child, _descriptor ->
      {:ok,
       %{
         handoff:
           Handoff.new(%{
             objective_status: :complete,
             summary: "done",
             workspace_id: child.workspace_id,
             base_commit: session.base_commit
           }),
         usage: Budget.zero()
       }}
    end
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
