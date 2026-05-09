defmodule Twelvgaige.CLI.Commands.StoreModulesTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.CLI.Commands.StoreBackupRestore
  alias Twelvgaige.CLI.Commands.StoreSecurity
  alias Twelvgaige.Crypto.EnvelopeCipher
  alias Twelvgaige.Crypto.EnvelopeFile
  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyMaterial
  alias Twelvgaige.Store.SQLite, as: SQLiteStore

  @tag :persistence
  test "store backup/restore module preserves consent and replacement behavior" do
    root = tmp_dir!("twelvgaige_store_backup_restore_modules")
    store_path = Path.join(root, "store.db")
    backup_path = Path.join(root, "backup.db")
    restored_path = Path.join(root, "restored.db")

    previous_store = Application.get_env(:twelvgaige, :store)
    Application.put_env(:twelvgaige, :store, {SQLiteStore, path: store_path})

    on_exit(fn -> restore_store_config(previous_store) end)

    start_supervised!({SQLiteStore, path: store_path})
    snapshot = %{id: "store_modules_round", status: :firing, version: 0}

    manifest = %{
      round_id: "store_modules_round",
      shell_id: "workflow",
      workflow: %{id: "workflow"}
    }

    assert :ok = GenServer.call(SQLiteStore, {:create_round, snapshot, manifest, []})

    assert {:ok, output, 7} = StoreBackupRestore.backup(backup_path, [])
    assert output =~ "plaintext SQLite backups require --allow-plaintext-export"

    assert {:ok, output, 0} =
             StoreBackupRestore.backup(backup_path, [
               "--allow-plaintext-export",
               "--format",
               "json"
             ])

    assert %{"status" => "ok", "destination" => ^backup_path} = Jason.decode!(output)

    assert {:ok, output, 0} =
             StoreBackupRestore.restore(backup_path, restored_path, ["--format", "json"])

    assert %{"status" => "ok", "destination" => ^restored_path, "replaced" => false} =
             Jason.decode!(output)

    assert {:ok, output, 4} = StoreBackupRestore.restore(backup_path, restored_path, [])
    assert output =~ "restore destination already exists"
  end

  test "store backup/restore module renders unsupported and missing-source errors" do
    root = tmp_dir!("twelvgaige_store_backup_restore_errors")
    missing_source = Path.join(root, "missing.db")
    destination = Path.join(root, "restored.db")
    previous_store = Application.get_env(:twelvgaige, :store)
    Application.put_env(:twelvgaige, :store, Twelvgaige.Store.Memory)

    on_exit(fn -> restore_store_config(previous_store) end)

    assert {:ok, output, 4} =
             StoreBackupRestore.backup(Path.join(root, "backup.db"), ["--format", "json"])

    assert %{"error" => %{"reason" => "store_backup_unsupported"}} = Jason.decode!(output)

    Application.put_env(:twelvgaige, :store, {SQLiteStore, path: Path.join(root, "store.db")})

    assert {:ok, output, 6} =
             StoreBackupRestore.restore(missing_source, destination, ["--format", "json"])

    assert %{"error" => %{"reason" => "backup_source_not_found"}} = Jason.decode!(output)
  end

  test "store security module validates migration arguments and JSON errors" do
    root = tmp_dir!("twelvgaige_store_security_migration")
    source = Path.join(root, "source.db")
    destination = Path.join(root, "encrypted.db")
    key_env = "TWELVGAIGE_STORE_SECURITY_KEY_#{System.unique_integer([:positive])}"
    System.put_env(key_env, "test-sqlcipher-key")

    on_exit(fn -> System.delete_env(key_env) end)

    assert {:ok, output, 4} = StoreSecurity.migrate_sqlcipher([])
    assert output =~ "--source is required"

    assert {:ok, output, 6} =
             StoreSecurity.migrate_sqlcipher([
               "--source",
               source,
               "--destination",
               destination,
               "--key-env",
               key_env,
               "--format",
               "json"
             ])

    assert %{"error" => %{"reason" => "migration_source_not_found"}} = Jason.decode!(output)
  end

  test "store security module can rewrap envelope metadata" do
    root = tmp_dir!("twelvgaige_store_security_rewrap")
    envelope_path = Path.join(root, "store-envelope.json")
    backup_path = Path.join(root, "store-envelope.backup.json")
    old_env = "TWELVGAIGE_STORE_SECURITY_OLD_#{System.unique_integer([:positive])}"
    new_env = "TWELVGAIGE_STORE_SECURITY_NEW_#{System.unique_integer([:positive])}"
    old_bytes = String.duplicate("a", 32)
    new_bytes = String.duplicate("b", 32)

    System.put_env(old_env, "base64:" <> Base.encode64(old_bytes))
    System.put_env(new_env, "base64:" <> Base.encode64(new_bytes))

    on_exit(fn ->
      System.delete_env(old_env)
      System.delete_env(new_env)
    end)

    assert {:ok, envelope} =
             EnvelopeCipher.wrap_dek(String.duplicate("d", 32), env_key("store-key", old_bytes))

    assert :ok = EnvelopeFile.write(envelope_path, envelope)

    assert {:ok, output, 4} =
             StoreSecurity.rewrap_envelope(envelope_path, [
               "--old-key-env",
               old_env,
               "--new-key-env",
               new_env
             ])

    assert output =~ "--backup is required"

    assert {:ok, output, 0} =
             StoreSecurity.rewrap_envelope(envelope_path, [
               "--backup",
               backup_path,
               "--old-key-env",
               old_env,
               "--new-key-env",
               new_env,
               "--format",
               "json"
             ])

    assert %{"status" => "ok", "path" => ^envelope_path, "backup" => ^backup_path} =
             Jason.decode!(output)

    assert {:ok, rewrapped} = EnvelopeFile.read(envelope_path)
    assert rewrapped.metadata["rotation"] == "rewrap"
    assert File.exists?(backup_path)
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp restore_store_config(nil), do: Application.delete_env(:twelvgaige, :store)
  defp restore_store_config(previous), do: Application.put_env(:twelvgaige, :store, previous)

  defp env_key(id, bytes) do
    {:ok, material} = KeyMaterial.new(bytes)

    %Key{
      id: id,
      backend: :env,
      status: :active,
      version: 1,
      material: material
    }
  end
end
