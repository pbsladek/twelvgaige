defmodule Twelvgaige.Manager.RuntimeTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession.Codex.AuthProfile
  alias Twelvgaige.Manager.{Budget, ChildRecord, Runtime}
  alias Twelvgaige.Manager.Plan.Task
  alias Twelvgaige.Sandbox.Backend.Podman
  alias Twelvgaige.Workspace

  test "builds a deterministic, digest-bound Podman context for a copied workspace" do
    root = temp_dir()
    workspace = workspace(root)
    child = child(:none)
    opts = runtime_opts(root)

    assert {:ok, first} = Runtime.sandbox_context(child, workspace, opts)
    assert {:ok, second} = Runtime.sandbox_context(child, workspace, opts)
    assert first == second

    assert byte_size(first.manifest_digest) == 64
    assert first.launch_spec.resource_id =~ "sandbox-"
    assert first.launch_spec.workspace_transport == :copy_snapshot
    assert first.launch_spec.network_mode == :none
    assert first.launch_spec.credential_lease_id == "credential-lease"
    assert first.launch_spec.environment_names == ["RUST_LOG"]
    assert first.launch_spec.result_destination == workspace.path

    assert [mount] = first.launch_spec.mounts
    assert mount == %{source: workspace.path, destination: "/workspace", mode: :read_write}

    sandbox_opts = first.runner_opts[:sandbox_opts]
    assert sandbox_opts[:environment] == %{"RUST_LOG" => "warn"}
    assert sandbox_opts[:allowed_export_roots] == [root]
    refute Keyword.has_key?(sandbox_opts, :egress_access_token)
  end

  test "attests a copied credential home and exposes only its guest path" do
    root = temp_dir()
    credential_home = Path.join(root, "credentials/session")
    File.mkdir_p!(credential_home)

    opts =
      runtime_opts(root,
        credential_mount_resolver: fn received_child, profile ->
          assert received_child.id == "child-runtime"
          assert profile.id == "service"
          {:ok, %{source: credential_home}}
        end
      )

    assert {:ok, context} = Runtime.sandbox_context(child(:none), workspace(root), opts)

    assert Enum.any?(context.launch_spec.mounts, fn mount ->
             mount.source == credential_home and mount.destination == "/run/codex-home" and
               mount.mode == :read_write
           end)

    assert context.launch_spec.environment_names == ["CODEX_HOME", "RUST_LOG"]

    assert context.runner_opts[:sandbox_opts][:environment] == %{
             "CODEX_HOME" => "/run/codex-home",
             "RUST_LOG" => "warn"
           }
  end

  test "rejects direct secret-bearing environment variables from an auth context" do
    root = temp_dir()
    child = child(:none)
    workspace = workspace(root)
    profile = runtime_opts(root)[:auth_profiles]["service"]

    assert {:error, :secret_environment_name_denied} =
             Runtime.sandbox_context(
               child,
               workspace,
               %{
                 profile: profile,
                 environment: %{"OPENAI_API_KEY" => "credential-value"},
                 credential_mount: nil
               },
               runtime_opts(root)
             )
  end

  test "requires an explicit broker boundary context and keeps its token out of identity" do
    root = temp_dir()
    child = child(:broker_only)

    assert {:error, :manager_egress_context_required} =
             Runtime.sandbox_context(child, workspace(root), runtime_opts(root))

    context = fn token ->
      Runtime.sandbox_context(
        child,
        workspace(root),
        runtime_opts(root,
          egress_context_resolver: fn received_child ->
            assert received_child.id == child.id

            {:ok,
             %{
               egress_lease_id: "egress-lease",
               egress_access_token: token,
               runner_opts: [
                 broker_network: "private-egress",
                 proxy_environment: %{
                   "HTTP_PROXY" => "http://proxy.invalid",
                   "HTTPS_PROXY" => "http://proxy.invalid",
                   "NO_PROXY" => "localhost"
                 }
               ]
             }}
          end
        )
      )
    end

    assert {:ok, first} = context.("secret-token-one")
    assert {:ok, second} = context.("secret-token-two")
    assert first.manifest_digest == second.manifest_digest
    assert first.launch_spec.egress_access_token == "secret-token-one"
    assert first.launch_spec.egress_lease_id == "egress-lease"

    assert first.launch_spec.environment_names == [
             "HTTPS_PROXY",
             "HTTP_PROXY",
             "NO_PROXY",
             "RUST_LOG"
           ]

    sandbox_opts = first.runner_opts[:sandbox_opts]
    assert sandbox_opts[:broker_network] == "private-egress"
    assert sandbox_opts[:proxy_environment]["HTTPS_PROXY"] == "http://proxy.invalid"
    refute inspect(first.manifest_digest) =~ "secret-token"
  end

  test "unrestricted networking is an explicit runtime authority" do
    root = temp_dir()
    child = child(:unrestricted)

    assert {:error, :manager_unrestricted_network_not_enabled} =
             Runtime.sandbox_context(child, workspace(root), runtime_opts(root))

    assert {:ok, context} =
             Runtime.sandbox_context(
               child,
               workspace(root),
               runtime_opts(root, allow_unrestricted?: true)
             )

    assert context.launch_spec.network_mode == :unrestricted
    assert context.runner_opts[:sandbox_opts][:allow_unrestricted?]
  end

  defp runtime_opts(root, overrides \\ []) do
    Keyword.merge(
      [
        backend: Podman,
        backend_opts: [allowed_roots: [root], backend_version: "5.8.5"],
        allowed_export_roots: [root],
        auth_profiles: %{
          "service" =>
            AuthProfile.new(%{
              id: "service",
              type: :brokered_service,
              revision: 3,
              credential_lease_id: "credential-lease",
              broker_endpoint: "https://credential-broker.invalid"
            })
        },
        image_reference: "localhost/twelvgaige/worker",
        image_digest: "sha256:" <> String.duplicate("a", 64),
        policy_revision: "runtime-policy-v1",
        environment: %{"RUST_LOG" => "warn"}
      ],
      overrides
    )
  end

  defp child(network_mode) do
    budget = %Budget{tokens: 1_000, cost_micros: 10_000, time_ms: 60_000, tool_calls: 50}
    deadline = ~U[2026-08-11 20:00:00Z]

    task = %Task{
      id: "task-runtime",
      agent: "codex",
      workflow: "coding.change.v1",
      objective: "Change the code",
      repository: "/source/repository",
      base_ref: "main",
      auth_profile_id: "service",
      sandbox_profile: "coding_restricted:podman",
      network_mode: network_mode,
      budget: budget,
      deadline: deadline,
      write: true
    }

    %ChildRecord{
      id: "child-runtime",
      plan_id: "plan-runtime",
      task_id: task.id,
      attempt: 0,
      round_id: "round-runtime",
      shot_id: "shot-runtime",
      parent_session_id: "parent-runtime",
      delegated_session_id: "session-runtime",
      workspace_id: "workspace-runtime",
      task: task,
      budget: budget,
      deadline: deadline,
      created_at: ~U[2026-08-11 19:00:00Z]
    }
  end

  defp workspace(root) do
    path = Path.join(root, "workspaces/workspace-runtime")
    File.mkdir_p!(path)

    Workspace.new(
      id: "workspace-runtime",
      repository: Path.join(root, "source"),
      base_ref: "main",
      base_commit: String.duplicate("b", 40),
      transport: :copy_snapshot,
      path: path,
      writable: true,
      created_at: ~U[2026-08-11 19:00:00Z],
      storage_reservation: %{workspace_bytes: 1_048_576}
    )
  end

  defp temp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-manager-runtime-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
