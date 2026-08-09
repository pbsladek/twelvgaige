defmodule Twelvgaige.Operations.CrossSessionIsolationTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Credential.Broker
  alias Twelvgaige.Operations.{ProviderLimiter, SessionControl, Store}
  alias Twelvgaige.Workspace.Manager, as: WorkspaceManager

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-cross-session-#{System.unique_integer([:positive])}"
      )

    store = start_supervised!({Store, name: nil, path: Path.join(root, "operations.sqlite3")})
    broker = start_supervised!({Broker, name: nil, store: store})

    control =
      start_supervised!(
        {SessionControl,
         name: nil,
         store: store,
         owner_uid: 42,
         username: "operator",
         credential_broker: broker,
         signing_key: :crypto.strong_rand_bytes(32)}
      )

    limiter =
      start_supervised!(
        {ProviderLimiter,
         name: nil,
         store: store,
         limits: %{
           {"openai", "account-a"} => %{rpm: 1, tpm: 10},
           {"openai", "account-b"} => %{rpm: 1, tpm: 10}
         }}
      )

    workspace =
      start_supervised!({WorkspaceManager, name: nil, root: Path.join(root, "workspaces")})

    %{
      root: root,
      store: store,
      broker: broker,
      control: control,
      limiter: limiter,
      workspace: workspace
    }
  end

  test "workspace, credential, capability, quota, and audit authority never crosses sessions",
       ctx do
    now = DateTime.utc_now()

    assert {:ok, credential_a} =
             Broker.issue(
               %{
                 session_id: "session_a",
                 round_id: "round_a",
                 shot_id: "delegate",
                 attempt: 1,
                 runtime: :codex,
                 principal: "session-a",
                 provider_account: "account-a",
                 models: ["gpt-5"],
                 destinations: ["api.openai.com"],
                 budget: 10,
                 expires_at: DateTime.add(now, 300),
                 upstream_secret: "upstream-a"
               },
               server: ctx.broker,
               now: now
             )

    assert {:ok, _} =
             SessionControl.register(session("session_a", credential_a.id),
               server: ctx.control,
               uid: 42
             )

    assert {:ok, _} =
             SessionControl.register(session("session_b", nil), server: ctx.control, uid: 42)

    assert {:ok, lease_a, _} =
             SessionControl.takeover("session_a", 1, server: ctx.control, uid: 42)

    assert {:error, :session_control_denied} =
             SessionControl.authorize(lease_a, "session_b", :cancel,
               server: ctx.control,
               uid: 42
             )

    assert {:error, :credential_session_mismatch} =
             Broker.authorize(
               credential_a.access_token,
               %{
                 session_id: "session_b",
                 model: "gpt-5",
                 destination: "api.openai.com",
                 amount: 1
               },
               server: ctx.broker,
               now: now
             )

    assert {:ok, _permit_a} =
             ProviderLimiter.acquire("openai", "account-a", 10, 0, server: ctx.limiter)

    assert {:wait, %{reason: :provider_rpm_exhausted}} =
             ProviderLimiter.acquire("openai", "account-a", 0, 0, server: ctx.limiter)

    assert {:ok, _permit_b} =
             ProviderLimiter.acquire("openai", "account-b", 10, 0, server: ctx.limiter)

    repository = create_repository(ctx.root)

    assert {:ok, workspace} =
             WorkspaceManager.create(repository,
               server: ctx.workspace,
               workspace_id: "ws_isolated",
               transport: :copy_snapshot
             )

    assert {:ok, _workspace} =
             WorkspaceManager.bind_owner(workspace.id, "session_a", server: ctx.workspace)

    assert {:error, :workspace_writer_already_leased} =
             WorkspaceManager.bind_owner(workspace.id, "session_b", server: ctx.workspace)

    assert {:ok, audit} = Store.list_audit(server: ctx.store)

    assert Enum.any?(
             audit,
             &(&1.event_type == "session_registered" and &1.session_id == "session_a")
           )

    assert Enum.any?(
             audit,
             &(&1.event_type == "session_registered" and &1.session_id == "session_b")
           )

    refute inspect(audit) =~ "upstream-a"
    refute File.read!(Path.join(ctx.root, "operations.sqlite3")) =~ "upstream-a"
  end

  defp session(id, credential_lease_id) do
    %{
      id: id,
      status: :running,
      runtime: :codex,
      driver: :codex_app_server,
      workspace_id: "ws_#{id}",
      sandbox_backend: :podman,
      sandbox_resource_id: "sandbox_#{id}",
      credential_lease_id: credential_lease_id,
      capabilities: [:read, :write],
      created_at: DateTime.utc_now()
    }
  end

  defp create_repository(root) do
    path = Path.join(root, "repository")
    File.mkdir_p!(path)
    git!(path, ["init", "-q"])
    git!(path, ["config", "user.email", "test@example.com"])
    git!(path, ["config", "user.name", "Test"])
    File.write!(Path.join(path, "README.md"), "isolated\n")
    git!(path, ["add", "README.md"])
    git!(path, ["commit", "-q", "-m", "initial"])
    path
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
  end
end
