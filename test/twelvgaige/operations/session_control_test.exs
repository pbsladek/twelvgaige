defmodule Twelvgaige.Operations.SessionControlTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Operations.{SessionControl, Store}

  defmodule Backend do
    def probe(_opts), do: {:ok, %{available: true}}
    def managed_resources(_opts), do: {:ok, [%{id: "sbx_orphan"}]}
    def stop(_id, _opts), do: :ok
    def destroy(_id, _opts), do: :ok
  end

  setup do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-session-control-#{suffix}"
      )

    workspace_root = Path.join(root, "workspaces")
    File.mkdir_p!(workspace_root)
    store = start_supervised!({Store, name: nil, path: Path.join(root, "ops.sqlite3")})
    parent = self()

    control =
      start_supervised!(
        {SessionControl,
         name: nil,
         store: store,
         owner_uid: 42,
         username: "operator",
         signing_key: :crypto.strong_rand_bytes(32),
         workspace_root: workspace_root,
         backends: %{test: Backend},
         cancel_fun: fn session ->
           send(parent, {:cancelled, session.id})
           :ok
         end,
         credential_revoke_fun: fn lease ->
           send(parent, {:revoked, lease})
           :ok
         end}
      )

    %{control: control, store: store, workspace_root: workspace_root}
  end

  test "inventory, attach, takeover, and revoke stay bound to one OS user", %{control: control} do
    session = session("session_one", "sbx_known")
    assert {:ok, registered} = SessionControl.register(session, server: control, uid: 42)
    assert registered.owner_uid == 42

    assert {:error, :local_user_mismatch} = SessionControl.list(server: control, uid: 7)
    assert {:ok, [listed]} = SessionControl.list(server: control, uid: 42)
    refute Map.has_key?(listed, :credential_lease_id)

    assert {:ok, observer, _session} = SessionControl.attach(session.id, server: control, uid: 42)
    assert :ok = SessionControl.authorize(observer, session.id, :read, server: control, uid: 42)

    assert {:error, :session_control_denied} =
             SessionControl.authorize(observer, session.id, :cancel, server: control, uid: 42)

    assert {:error, :session_control_epoch_conflict} =
             SessionControl.takeover(session.id, 9, server: control, uid: 42)

    assert {:ok, controller, %{control_epoch: 2}} =
             SessionControl.takeover(session.id, 1, server: control, uid: 42)

    assert_receive {:cancelled, "session_one"}

    assert :ok =
             SessionControl.authorize(controller, session.id, :cancel, server: control, uid: 42)

    assert {:error, :session_control_denied} =
             SessionControl.authorize(observer, session.id, :read, server: control, uid: 42)

    assert {:ok, %{status: :revoked}} =
             SessionControl.revoke(session.id, server: control, uid: 42)

    assert_receive {:revoked, "lease_one"}

    assert {:error, :session_revoked} =
             SessionControl.attach(session.id, server: control, uid: 42)
  end

  test "reconciliation reports resources, workspaces, and missing session ownership", %{
    control: control,
    workspace_root: workspace_root
  } do
    File.mkdir_p!(Path.join(workspace_root, "ws_orphan"))

    assert {:ok, _} =
             SessionControl.register(session("session_missing", "sbx_missing"),
               server: control,
               uid: 42
             )

    assert {:ok, report} = SessionControl.reconcile(server: control, uid: 42)
    assert report.orphan_resources == ["sbx_orphan"]
    assert report.orphan_workspaces == ["ws_orphan"]
    assert report.workspace_actions == %{"ws_orphan" => :quarantine}
    assert report.missing_session_resources == ["session_missing"]
    assert report.mode == :dry_run
    assert File.dir?(Path.join(workspace_root, "ws_orphan"))

    assert {:ok, stored} = SessionControl.get("session_missing", server: control, uid: 42)
    assert stored.status == :awaiting_reconciliation

    assert {:ok, applied} =
             SessionControl.reconcile(server: control, uid: 42, apply?: true)

    assert %{status: :ok, action: :quarantined, path: quarantine_path} =
             applied.workspace_actions["ws_orphan"]

    refute File.exists?(Path.join(workspace_root, "ws_orphan"))
    assert File.dir?(quarantine_path)

    assert {:ok, repeated} = SessionControl.reconcile(server: control, uid: 42)
    assert repeated.orphan_workspaces == []
  end

  test "reconciliation revokes unbound credential and egress leases when applied", %{
    control: control,
    store: store
  } do
    credential_broker =
      start_supervised!(
        {Twelvgaige.Credential.Broker, name: __MODULE__.CredentialBroker, store: store}
      )

    egress_broker =
      start_supervised!({Twelvgaige.Egress.Broker, name: nil, store: store})

    assert {:ok, credential} =
             Twelvgaige.Credential.Broker.issue(
               %{
                 session_id: "unbound",
                 round_id: "round_1",
                 shot_id: "shot_1",
                 attempt: 1,
                 runtime: :codex,
                 principal: "operator",
                 provider_account: "test",
                 models: ["model"],
                 destinations: ["provider.example"],
                 budget: 1_000,
                 expires_at: ~U[2027-01-01 00:00:00Z],
                 upstream_secret: "not-returned"
               },
               server: credential_broker
             )

    assert {:ok, egress} =
             Twelvgaige.Egress.Broker.issue(
               %{
                 session_id: "unbound",
                 allowed_hosts: ["provider.example"],
                 expires_at: ~U[2027-01-01 00:00:00Z]
               },
               server: egress_broker
             )

    assert {:ok, %{hold_until: ~U[9999-12-31 23:59:59Z]}} =
             Store.get(:credential_lease, credential.id, server: store)

    assert {:ok, %{hold_until: ~U[9999-12-31 23:59:59Z]}} =
             Store.get(:egress_lease, egress.id, server: store)

    assert {:ok, dry_run} =
             SessionControl.reconcile(
               server: control,
               uid: 42,
               credential_broker: credential_broker,
               egress_broker: egress_broker
             )

    assert dry_run.credential_leases.unbound == [credential.id]
    assert dry_run.credential_leases.unbound_actions[credential.id] == :quarantine
    assert dry_run.egress_leases.unbound == [egress.id]
    assert dry_run.egress_leases.unbound_actions[egress.id] == :quarantine

    assert {:ok, applied} =
             SessionControl.reconcile(
               server: control,
               uid: 42,
               credential_broker: credential_broker,
               egress_broker: egress_broker,
               apply?: true
             )

    assert applied.credential_leases.unbound_actions[credential.id] == :ok
    assert applied.egress_leases.unbound_actions[egress.id] == :ok

    assert {:ok, credential_inventory} =
             Twelvgaige.Credential.Broker.inventory(server: credential_broker)

    assert Enum.find(credential_inventory, &(&1.id == credential.id)).status == :revoked

    assert {:ok, egress_inventory} =
             Twelvgaige.Egress.Broker.inventory(server: egress_broker)

    assert Enum.find(egress_inventory, &(&1.id == egress.id)).status == :revoked

    assert {:ok, %{hold_until: nil}} =
             Store.get(:credential_lease, credential.id, server: store)

    assert {:ok, %{hold_until: nil}} =
             Store.get(:egress_lease, egress.id, server: store)
  end

  test "orphaned leases quarantine an otherwise running session after broker restart", %{
    control: control,
    store: store
  } do
    {:ok, credential_broker} =
      Twelvgaige.Credential.Broker.start_link(
        name: __MODULE__.RestartCredentialBroker,
        store: store
      )

    {:ok, egress_broker} =
      Twelvgaige.Egress.Broker.start_link(name: __MODULE__.RestartEgressBroker, store: store)

    on_exit(fn ->
      Enum.each(
        [__MODULE__.RestartCredentialBroker, __MODULE__.RestartEgressBroker],
        &stop_if_alive/1
      )
    end)

    assert {:ok, credential} =
             Twelvgaige.Credential.Broker.issue(credential_attrs("session_leased"),
               server: credential_broker
             )

    assert {:ok, egress} =
             Twelvgaige.Egress.Broker.issue(
               %{
                 session_id: "session_leased",
                 allowed_hosts: ["provider.example"],
                 expires_at: ~U[2027-01-01 00:00:00Z]
               },
               server: egress_broker
             )

    leased_session =
      session("session_leased", nil)
      |> Map.put(:credential_lease_id, credential.id)
      |> Map.put(:egress_lease_id, egress.id)

    assert {:ok, _session} = SessionControl.register(leased_session, server: control, uid: 42)
    GenServer.stop(credential_broker)
    GenServer.stop(egress_broker)

    {:ok, credential_broker} =
      Twelvgaige.Credential.Broker.start_link(
        name: __MODULE__.RestartCredentialBroker,
        store: store
      )

    {:ok, egress_broker} =
      Twelvgaige.Egress.Broker.start_link(name: __MODULE__.RestartEgressBroker, store: store)

    assert {:ok, report} =
             SessionControl.reconcile(
               server: control,
               uid: 42,
               credential_broker: credential_broker,
               egress_broker: egress_broker
             )

    assert report.orphaned_session_leases == ["session_leased"]
    assert report.sessions_awaiting_reconciliation == ["session_leased"]
    assert credential.id in report.credential_leases.orphaned
    assert egress.id in report.egress_leases.orphaned

    assert {:ok, %{status: :awaiting_reconciliation}} =
             SessionControl.get("session_leased", server: control, uid: 42)
  end

  defp stop_if_alive(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        GenServer.stop(pid)
    end
  catch
    :exit, _reason -> :ok
  end

  defp session(id, resource_id) do
    %{
      id: id,
      status: :running,
      runtime: :codex,
      driver: :codex_app_server,
      workspace_id: "ws_#{id}",
      workspace_path: "/tmp/#{id}",
      sandbox_backend: :test,
      sandbox_resource_id: resource_id,
      credential_lease_id: "lease_one",
      capabilities: [:read, :write],
      budgets: %{tokens: 1_000},
      usage: %{tokens: 10},
      created_at: ~U[2026-08-02 00:00:00Z]
    }
  end

  defp credential_attrs(session_id) do
    %{
      session_id: session_id,
      round_id: "round_1",
      shot_id: "shot_1",
      attempt: 1,
      runtime: :codex,
      principal: "operator",
      provider_account: "test",
      models: ["model"],
      destinations: ["provider.example"],
      budget: 1_000,
      expires_at: ~U[2027-01-01 00:00:00Z],
      upstream_secret: "not-returned"
    }
  end
end
