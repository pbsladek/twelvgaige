defmodule Twelvgaige.Operations.OperatorIPCTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Artifact.Store, as: ArtifactStore
  alias Twelvgaige.Breech.IPC.{Client, Server}

  alias Twelvgaige.Operations.{
    AuditAnchor,
    Keyring,
    Keys,
    LocalIdentity,
    RetentionEnforcer,
    SessionControl,
    Store
  }

  @token "phase-seven-operator-token"

  test "authenticated IPC exposes store, retention, artifact, and release operations" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-operator-ipc-#{System.unique_integer([:positive])}"
      )

    store = start_supervised!({Store, name: nil, path: Path.join(root, "operations.sqlite3")})
    {:ok, identity} = LocalIdentity.current()

    {:ok, keys} =
      Keys.resolve(data_root: root, operations_master_key: :crypto.strong_rand_bytes(32))

    artifacts =
      start_supervised!(
        {ArtifactStore,
         name: nil,
         root: Path.join(root, "artifacts"),
         key: keys.artifact_key,
         key_id: keys.artifact_key_id,
         previous_keys: keys.artifact_previous_keys}
      )

    keyring = start_supervised!({Keyring, name: nil, keys: keys, artifact_store: artifacts})

    control =
      start_supervised!(
        {SessionControl,
         name: nil,
         store: store,
         owner_uid: identity.uid,
         username: identity.username,
         artifact_store: artifacts}
      )

    retention =
      start_supervised!(
        {RetentionEnforcer,
         name: nil, store: store, artifact_store: artifacts, interval_ms: 86_400_000}
      )

    endpoint_path = Path.join(root, "runtime/breech.endpoint.json")

    audit_anchor =
      start_supervised!(
        {AuditAnchor,
         name: nil,
         store: store,
         path: Path.join(root, "audit/checkpoints.ndjson"),
         signing_key: keys.audit_export_key,
         owner_uid: identity.uid,
         checkpoint_on_start?: false,
         interval_ms: 86_400_000}
      )

    server =
      start_supervised!(
        {Server,
         port: 0,
         token: @token,
         endpoint_path: endpoint_path,
         operations: control,
         retention: retention,
         artifact_store: artifacts,
         keyring: keyring,
         audit_anchor: audit_anchor,
         audit_export_key: keys.audit_export_key}
      )

    address = {:tcp, {127, 0, 0, 1}, Server.port(server)}
    opts = [token: @token]

    assert {:ok, %{"schema_version" => 3}} = Client.operations_store_stats(address, opts)
    assert {:ok, %{"status" => "missing"}} = Client.operations_audit_status(address, opts)
    assert {:ok, %{"sequence" => 1}} = Client.checkpoint_operations_audit(address, opts)

    assert {:ok, %{"status" => "healthy", "checkpoint_count" => 1}} =
             Client.operations_audit_status(address, opts)

    assert {:ok, cli_status, 0} =
             Twelvgaige.CLI.Dispatcher.run([
               "operations",
               "audit",
               "status",
               "--endpoint",
               endpoint_path,
               "--format",
               "json"
             ])

    assert %{"status" => "healthy"} = Jason.decode!(cli_status)

    assert {:ok, cli_checkpoint, 0} =
             Twelvgaige.CLI.Dispatcher.run([
               "operations",
               "audit",
               "checkpoint",
               "--endpoint",
               endpoint_path,
               "--format",
               "json"
             ])

    assert %{"sequence" => 2} = Jason.decode!(cli_checkpoint)

    assert {:ok, _session} =
             SessionControl.register(
               %{
                 id: "session_dashboard",
                 status: :running,
                 runtime: :codex,
                 usage: %{
                   input_tokens: 10,
                   output_tokens: 5,
                   total_tokens: 15,
                   cost_micros: 25
                 },
                 nested_agents: [%{id: "native_child"}]
               },
               server: control
             )

    assert {:ok,
            %{
              "cost" => 25,
              "tokens" => %{"total" => 15},
              "nested_agents" => %{"total" => 1},
              "audit_checkpoint" => %{"status" => "healthy"}
            }} = Client.operations_dashboard(address, opts)

    backup = Path.join(root, "backup.sqlite3")
    restored = Path.join(root, "restored.sqlite3")

    assert {:ok, %{"live_credentials_included" => false}} =
             Client.backup_operations_store(address, backup, opts)

    assert {:ok,
            %{
              "live_credentials_restored" => false,
              "audit_checkpoint_verified" => true
            }} =
             Client.restore_operations_store(address, backup, restored, opts)

    assert {:ok, _ref} = ArtifactStore.put(%{value: 1}, server: artifacts)

    assert {:ok, %{"artifacts" => 1, "current_key_id" => old_key_id}} =
             Client.artifact_inventory(address, opts)

    assert {:ok, %{"artifacts_rotated" => 1, "new_key_id" => new_key_id}} =
             Client.rotate_artifact_key(address, opts)

    refute new_key_id == old_key_id

    assert {:ok, %{"records_removed" => _count}} = Client.run_retention(address, opts)
    assert {:ok, %{"status" => status}} = Client.retention_status(address, opts)
    assert status in ["healthy", "starting"]

    audit_export = Path.join(root, "operator-audit.json")

    assert {:ok, %{"events" => event_count}} =
             Client.export_operations_audit(address, audit_export, opts)

    assert event_count >= 1
    assert {:ok, replacement} = Client.rotate_token(address, opts)
    refute replacement == @token

    assert {:error, %{reason: :daemon_auth_failed}} =
             Client.operations_store_stats(address, token: @token)

    assert {:ok, audit_events} = Store.list_audit(server: store)
    event_types = Enum.map(audit_events, & &1.event_type)
    assert "audit_export_requested" in event_types
    assert "control_token_rotated" in event_types
    assert "control_authentication_failed" in event_types
    refute String.contains?(:erlang.term_to_binary(audit_events), replacement)
  end
end
