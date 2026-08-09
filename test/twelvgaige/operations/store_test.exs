defmodule Twelvgaige.Operations.StoreTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Operations.Store

  setup do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige-ops-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    path = Path.join(root, "operations.sqlite3")
    store = start_supervised!({Store, name: nil, path: path})
    %{root: root, path: path, store: store}
  end

  test "migrates, versions, batches atomically, and claims occurrences once", %{store: store} do
    assert {:ok, %{schema_version: 3}} = Store.stats(server: store)
    assert :ok = Store.put(:sessions, "one", %{status: :running}, server: store)

    assert {:ok, %{version: 1, value: %{status: :running}}} =
             Store.get(:sessions, "one", server: store)

    assert :ok =
             Store.compare_and_put(:sessions, "one", 1, %{status: :completed}, server: store)

    assert {:error, :version_conflict} =
             Store.compare_and_put(:sessions, "one", 1, %{status: :failed}, server: store)

    assert :ok =
             Store.put_many_new(
               [{:batch, "a", 1}, {:batch, "b", 2}],
               server: store,
               retention_class: :security
             )

    assert {:error, _reason} =
             Store.put_many_new([{:batch, "c", 3}, {:batch, "a", 4}], server: store)

    assert {:error, :not_found} = Store.get(:batch, "c", server: store)
    assert :claimed = Store.claim_once(:automation, "job:1", %{}, server: store)
    assert :duplicate = Store.claim_once(:automation, "job:1", %{}, server: store)
  end

  test "retention honors holds and backup restore removes live authority", %{
    root: root,
    store: store
  } do
    expired = ~U[2026-01-01 00:00:00Z]
    held_until = ~U[2027-01-01 00:00:00Z]

    assert :ok =
             Store.put(:raw, "expired", :remove,
               server: store,
               expires_at: expired,
               now: expired
             )

    assert :ok =
             Store.put(:raw, "held", :keep,
               server: store,
               expires_at: expired,
               hold_until: held_until,
               now: expired
             )

    assert :ok = Store.put(:control_token, "current", %{hash: "secret"}, server: store)

    assert :ok =
             Store.put(
               :session,
               "session_1",
               %{
                 id: "session_1",
                 status: :running,
                 credential_lease_id: "lease_1",
                 egress_lease_id: "egress_1",
                 control_epoch: 7,
                 controller_pid: self(),
                 runtime: :codex,
                 driver: :codex_app_server,
                 native_session_id: "thread_exact_1",
                 workspace_id: "ws_exact_1",
                 base_commit: String.duplicate("a", 40),
                 sandbox_backend: :podman,
                 sandbox_manifest_digest: "sha256:" <> String.duplicate("b", 64)
               },
               server: store
             )

    assert {:ok, 1} = Store.prune(server: store, now: ~U[2026-06-01 00:00:00Z])
    assert {:error, :not_found} = Store.get(:raw, "expired", server: store)
    assert {:ok, %{value: :keep}} = Store.get(:raw, "held", server: store)

    backup = Path.join(root, "backup.sqlite3")
    restored = Path.join(root, "restored.sqlite3")
    assert {:ok, %{live_credentials_included: false}} = Store.backup(backup, server: store)

    backup_store =
      start_supervised!({Store, name: nil, path: backup}, id: :sanitized_backup_store)

    assert {:error, :not_found} = Store.get(:control_token, "current", server: backup_store)

    assert {:ok, %{value: backup_session}} =
             Store.get(:session, "session_1", server: backup_store)

    assert backup_session.status == :awaiting_reconciliation
    assert backup_session.credential_lease_id == nil
    assert backup_session.egress_lease_id == nil
    assert backup_session.control_epoch == 8
    assert backup_session.controller_pid == nil
    GenServer.stop(backup_store)

    assert {:ok, %{live_credentials_restored: false}} = Store.restore_backup(backup, restored)

    restored_store =
      start_supervised!({Store, name: nil, path: restored}, id: :restored_ops_store)

    assert {:error, :not_found} = Store.get(:control_token, "current", server: restored_store)

    assert {:ok, %{value: session}} = Store.get(:session, "session_1", server: restored_store)
    assert session.id == "session_1"
    assert session.status == :awaiting_reconciliation
    assert session.credential_lease_id == nil
    assert session.egress_lease_id == nil
    assert session.control_epoch == 9
    assert session.controller_pid == nil

    assert Map.take(session, [
             :id,
             :runtime,
             :driver,
             :native_session_id,
             :workspace_id,
             :base_commit,
             :sandbox_backend,
             :sandbox_manifest_digest
           ]) == %{
             id: "session_1",
             runtime: :codex,
             driver: :codex_app_server,
             native_session_id: "thread_exact_1",
             workspace_id: "ws_exact_1",
             base_commit: String.duplicate("a", 40),
             sandbox_backend: :podman,
             sandbox_manifest_digest: "sha256:" <> String.duplicate("b", 64)
           }
  end

  test "audit export remains a verifiable hash chain", %{root: root, store: store} do
    assert {:ok, _} =
             Store.append_audit(
               %{event_type: :one, occurred_at: ~U[2026-08-02 00:00:00Z]},
               server: store
             )

    assert {:ok, _} =
             Store.append_audit(
               %{event_type: :two, occurred_at: ~U[2026-08-02 00:00:01Z]},
               server: store
             )

    key = :crypto.strong_rand_bytes(32)
    path = Path.join(root, "audit.json")

    assert {:ok, %{events: 2}} =
             Twelvgaige.Operations.AuditExport.export(path, key,
               store: store,
               owner_uid: 501,
               authorize: fn -> :ok end
             )

    assert {:ok, %{"events" => events}} = Twelvgaige.Operations.AuditExport.verify(path, key)
    assert length(events) == 2
  end

  test "audit retention advances an anchored chain and accepts later appends", %{store: store} do
    old = ~U[2026-01-01 00:00:00Z]
    recent = ~U[2026-04-01 00:00:00Z]

    assert {:ok, first} =
             Store.append_audit(%{event_type: :old, occurred_at: old}, server: store)

    assert {:ok, _second} =
             Store.append_audit(%{event_type: :recent, occurred_at: recent}, server: store)

    assert {:ok, 1} = Store.prune(server: store, now: ~U[2026-04-02 00:00:00Z])
    assert {:ok, snapshot} = Store.audit_snapshot(server: store)
    assert snapshot.base_hash == first.audit_chain_hash
    assert snapshot.pruned_through_sequence == 1
    assert length(snapshot.events) == 1
    assert :ok = Twelvgaige.Audit.Chain.verify_from(snapshot.base_hash, snapshot.events)

    assert {:ok, appended} =
             Store.append_audit(
               %{event_type: :after_prune, occurred_at: ~U[2026-04-02 00:01:00Z]},
               server: store
             )

    assert appended.audit_previous_hash == snapshot.chain_head
    assert {:ok, final} = Store.audit_snapshot(server: store)
    assert length(final.events) == 2
    assert :ok = Twelvgaige.Audit.Chain.verify_from(final.base_hash, final.events)
  end

  test "upgrades an existing version-two database without rebuilding it", %{root: root} do
    path = Path.join(root, "version-two.sqlite3")
    {:ok, connection} = Exqlite.Sqlite3.open(path)

    assert :ok =
             Exqlite.Sqlite3.execute(
               connection,
               """
               CREATE TABLE records(
                 namespace TEXT NOT NULL,
                 record_key TEXT NOT NULL,
                 value BLOB NOT NULL,
                 version INTEGER NOT NULL,
                 retention_class TEXT NOT NULL,
                 expires_at TEXT,
                 hold_until TEXT,
                 inserted_at TEXT NOT NULL,
                 updated_at TEXT NOT NULL,
                 PRIMARY KEY(namespace, record_key)
               );
               CREATE TABLE replay_claims(
                 namespace TEXT NOT NULL,
                 occurrence_id TEXT NOT NULL,
                 value BLOB NOT NULL,
                 claimed_at TEXT NOT NULL,
                 PRIMARY KEY(namespace, occurrence_id)
               );
               CREATE TABLE audit_events(
                 sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                 event_id TEXT NOT NULL UNIQUE,
                 occurred_at TEXT NOT NULL,
                 chain_hash TEXT NOT NULL,
                 payload TEXT NOT NULL
               );
               CREATE INDEX records_expiry_idx ON records(expires_at, hold_until);
               PRAGMA user_version = 2;
               """
             )

    assert :ok = Exqlite.Sqlite3.close(connection)

    upgraded = start_supervised!({Store, name: nil, path: path}, id: :upgraded_v2_store)
    assert {:ok, %{schema_version: 3}} = Store.stats(server: upgraded)

    assert {:ok, _event} =
             Store.append_audit(
               %{event_type: :after_upgrade, occurred_at: ~U[2026-08-07 00:00:00Z]},
               server: upgraded
             )

    assert {:ok, %{event_count: 1, pruned_through_sequence: 0}} =
             Store.audit_snapshot(server: upgraded)
  end

  test "restore verifies the independently signed audit checkpoint", %{
    root: root,
    store: store
  } do
    {:ok, identity} = Twelvgaige.Operations.LocalIdentity.current()
    key = :crypto.strong_rand_bytes(32)
    checkpoint = Path.join(root, "audit/checkpoints.ndjson")

    anchor =
      start_supervised!(
        {Twelvgaige.Operations.AuditAnchor,
         name: nil,
         store: store,
         path: checkpoint,
         signing_key: key,
         owner_uid: identity.uid,
         checkpoint_on_start?: false,
         interval_ms: 86_400_000}
      )

    assert {:ok, _event} =
             Store.append_audit(%{event_type: :backup_ready}, server: store)

    assert {:ok, %{sequence: 1}} =
             Twelvgaige.Operations.AuditAnchor.run(server: anchor)

    backup = Path.join(root, "verified-backup.sqlite3")
    restored = Path.join(root, "verified-restore.sqlite3")
    assert {:ok, _report} = Store.backup(backup, server: store)

    assert {:ok, %{audit_checkpoint_verified: true}} =
             Store.restore_backup(backup, restored,
               audit_checkpoint_path: checkpoint,
               audit_signing_key: key,
               owner_uid: identity.uid
             )

    [line] = checkpoint |> File.read!() |> String.split("\n", trim: true)
    tampered = line |> Jason.decode!() |> Map.put("audit_position", 99) |> Jason.encode!()
    File.write!(checkpoint, tampered <> "\n")
    rejected = Path.join(root, "rejected-restore.sqlite3")

    assert {:error, {:restored_audit_checkpoint_invalid, :audit_checkpoint_hash_invalid}} =
             Store.restore_backup(backup, rejected,
               audit_checkpoint_path: checkpoint,
               audit_signing_key: key,
               owner_uid: identity.uid
             )

    refute File.exists?(rejected)

    preserved = Path.join(root, "preserved-destination.sqlite3")
    File.write!(preserved, "existing destination")

    assert {:error, {:restored_audit_checkpoint_invalid, :audit_checkpoint_hash_invalid}} =
             Store.restore_backup(backup, preserved,
               replace?: true,
               audit_checkpoint_path: checkpoint,
               audit_signing_key: key,
               owner_uid: identity.uid
             )

    assert File.read!(preserved) == "existing destination"

    assert {:error, :restore_source_is_destination} =
             Store.restore_backup(backup, backup, replace?: true)
  end

  test "uses the configured raw, security, and audit retention periods", %{root: root} do
    configured =
      start_supervised!(
        {Store,
         name: nil,
         path: Path.join(root, "configured-retention.sqlite3"),
         raw_retention_days: 7,
         security_retention_days: 11},
        id: :configured_retention_store
      )

    now = ~U[2026-08-07 00:00:00Z]
    assert :ok = Store.put(:raw, "one", 1, server: configured, now: now)

    assert :ok =
             Store.put(:security, "one", 1,
               server: configured,
               now: now,
               retention_class: :security
             )

    assert {:ok, _event} =
             Store.append_audit(%{event_type: :configured, occurred_at: now},
               server: configured
             )

    assert {:ok, %{expires_at: raw_expiry}} = Store.get(:raw, "one", server: configured)

    assert {:ok, %{expires_at: security_expiry}} =
             Store.get(:security, "one", server: configured)

    assert raw_expiry == DateTime.add(now, 7 * 86_400, :second)
    assert security_expiry == DateTime.add(now, 11 * 86_400, :second)

    assert {:ok, 1} =
             Store.prune(server: configured, now: DateTime.add(now, 8 * 86_400, :second))

    assert {:error, :not_found} = Store.get(:raw, "one", server: configured)
    assert {:ok, %{value: 1}} = Store.get(:security, "one", server: configured)
    assert {:ok, %{event_count: 1}} = Store.audit_snapshot(server: configured)

    assert {:ok, 2} =
             Store.prune(server: configured, now: DateTime.add(now, 12 * 86_400, :second))

    assert {:error, :not_found} = Store.get(:security, "one", server: configured)

    assert {:ok, %{event_count: 0, pruned_through_sequence: 1}} =
             Store.audit_snapshot(server: configured)
  end

  test "audit persistence normalizes non-JSON operational results without crashing", %{
    store: store
  } do
    assert {:ok, _event} =
             Store.append_audit(
               %{
                 event_type: :operation_reported,
                 details: %{result: {:error, :backend_down}, worker: self()}
               },
               server: store
             )

    assert {:ok, %{events: [stored]}} = Store.audit_snapshot(server: store)
    assert stored.details.result == "{:error, :backend_down}"
    assert String.starts_with?(stored.details.worker, "#PID<")
    assert :ok = Twelvgaige.Audit.Chain.verify([stored])
  end
end
