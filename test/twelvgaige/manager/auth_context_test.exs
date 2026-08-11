defmodule Twelvgaige.Manager.AuthContextTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Credential.Broker
  alias Twelvgaige.Manager.{AuthContext, Budget, ChildRecord}
  alias Twelvgaige.Manager.Plan.Task

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-auth-context-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, broker: start_supervised!({Broker, name: nil})}
  end

  test "issues, materializes, mounts, revokes, and erases one child credential", context do
    parent = self()

    profiles = %{
      "service" => %{
        revision: "rev-3",
        provider_account: "openai-project",
        models: ["gpt-5.6-codex"],
        destinations: ["api.openai.com"],
        secret_resolver: fn resolved_child, _profile ->
          send(parent, {:secret_resolved_for, resolved_child.id})
          {:ok, "sk-manager-only"}
        end
      }
    }

    login_runner = fn _binary, ["login", "--with-api-key"], stdin, opts ->
      send(parent, {:login_stdin, stdin, opts[:environment]})
      File.write!(Path.join(opts[:environment]["CODEX_HOME"], "auth.json"), "ready")
      :ok
    end

    opts = [
      credential_broker: context.broker,
      credentials_root: context.root,
      codex_home_opts: [codex_binary: "/opt/codex/bin/codex", login_runner: login_runner]
    ]

    assert {:ok, auth_context} = AuthContext.resolve(child(), profiles, opts)
    assert_receive {:secret_resolved_for, "child"}
    assert_receive {:login_stdin, "sk-manager-only\n", environment}
    refute Map.has_key?(environment, "OPENAI_API_KEY")

    assert auth_context.profile.id == "service"
    assert auth_context.profile.type == :brokered_service
    assert auth_context.profile.credential_lease_id == auth_context.credential_lease_id
    assert auth_context.environment == %{}
    assert auth_context.credential_mount.source == auth_context.credential_home
    assert File.regular?(Path.join(auth_context.credential_home, "auth.json"))
    refute inspect(auth_context) =~ "sk-manager-only"
    refute inspect(Broker.audit(server: context.broker)) =~ "sk-manager-only"

    assert :ok = AuthContext.cleanup(auth_context, opts)
    refute File.exists?(auth_context.credential_home)
    assert {:ok, [lease]} = Broker.inventory(server: context.broker)
    assert lease.id == auth_context.credential_lease_id
    assert lease.status == :revoked
  end

  test "revokes the lease and removes partial state when login fails", context do
    profiles = %{
      "service" => %{
        secret_resolver: fn _child, _profile -> {:ok, "sk-never-persist"} end
      }
    }

    opts = [
      credential_broker: context.broker,
      credentials_root: context.root,
      codex_home_opts: [
        codex_binary: "/opt/codex/bin/codex",
        login_runner: fn _binary, _args, stdin, _opts -> {:error, {:raw, stdin}} end
      ]
    ]

    result = AuthContext.resolve(child(), profiles, opts)
    assert {:error, {:codex_login_failed, :redacted}} = result
    refute inspect(result) =~ "sk-never-persist"
    assert {:ok, [lease]} = Broker.inventory(server: context.broker)
    assert lease.status == :revoked
    assert File.ls!(context.root) == []
  end

  test "redacts exceptions from a secret resolver", context do
    profiles = %{
      "service" => %{
        secret_resolver: fn _child, _profile -> raise "provider returned sk-do-not-echo" end
      }
    }

    result =
      AuthContext.resolve(child(), profiles,
        credential_broker: context.broker,
        credentials_root: context.root
      )

    assert {:error, :manager_credential_secret_resolver_crashed} = result
    refute inspect(result) =~ "sk-do-not-echo"
    assert {:ok, []} = Broker.inventory(server: context.broker)
  end

  defp child do
    budget = %Budget{tokens: 1_000, cost_micros: 1_000, time_ms: 60_000, tool_calls: 100}

    task = %Task{
      id: "task",
      agent: "codex",
      workflow: "coding.change.v1",
      objective: "change code",
      auth_profile_id: "service",
      sandbox_profile: :coding_restricted,
      network_mode: :broker_only,
      budget: budget,
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
      workspace_id: "workspace",
      task: task,
      budget: budget,
      deadline: task.deadline,
      created_at: DateTime.utc_now()
    }
  end
end
