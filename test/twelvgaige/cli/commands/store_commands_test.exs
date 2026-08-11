defmodule Twelvgaige.CLI.Commands.StoreCommandsTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.CLI.{Main, ResultEnvelope}
  alias Twelvgaige.Crypto.EnvelopeCipher
  alias Twelvgaige.Crypto.EnvelopeFile
  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyMaterial
  alias Twelvgaige.Store.SQLite, as: SQLiteStore

  defp decode_cli_result!(output) do
    decoded = Jason.decode!(output)

    case ResultEnvelope.result(decoded) do
      {:ok, result} -> result
      {:error, :invalid_cli_result_envelope} -> decoded
      {:error, error} -> %{"error" => error}
    end
  end

  @tag :persistence
  test "store backup command preserves plaintext export consent" do
    root = tmp_dir!("twelvgaige_cli_store_backup")
    path = Path.join(root, "store.db")
    backup_path = Path.join(root, "backup.db")

    previous_store = Application.get_env(:twelvgaige, :store)
    Application.put_env(:twelvgaige, :store, {SQLiteStore, path: path})

    on_exit(fn ->
      restore_store_config(previous_store)
    end)

    start_supervised!({SQLiteStore, path: path})

    snapshot = %{id: "cli_backup_round", status: :firing, version: 0}
    manifest = %{round_id: "cli_backup_round", shell_id: "workflow", workflow: %{id: "workflow"}}
    assert :ok = GenServer.call(SQLiteStore, {:create_round, snapshot, manifest, []})

    assert {:ok, output, 7} = Main.run(["store", "backup", backup_path])
    assert output =~ "plaintext SQLite backups require --allow-plaintext-export"
    refute File.exists?(backup_path)

    assert {:ok, output, 0} =
             Main.run([
               "store",
               "backup",
               backup_path,
               "--allow-plaintext-export",
               "--format",
               "json"
             ])

    assert %{
             "status" => "ok",
             "destination" => ^backup_path,
             "mode" => "plaintext",
             "plaintext" => true
           } = decode_cli_result!(output)

    assert File.exists?(backup_path)

    assert {:ok, output, 4} =
             Main.run(["store", "backup", backup_path, "--allow-plaintext-export"])

    assert output =~ "backup destination already exists"
  end

  @tag :persistence
  test "store restore command refuses overwrite unless replacement is explicit" do
    root = tmp_dir!("twelvgaige_cli_store_restore")
    source = Path.join(root, "backup.db")
    destination = Path.join(root, "restored.db")

    previous_store = Application.get_env(:twelvgaige, :store)
    Application.put_env(:twelvgaige, :store, {SQLiteStore, path: Path.join(root, "store.db")})

    on_exit(fn ->
      restore_store_config(previous_store)
    end)

    File.write!(source, "backup")

    assert {:ok, output, 0} =
             Main.run(["store", "restore", source, destination, "--format", "json"])

    assert %{
             "status" => "ok",
             "source" => ^source,
             "destination" => ^destination,
             "replaced" => false
           } = decode_cli_result!(output)

    assert File.read!(destination) == "backup"

    File.write!(source, "replacement")

    assert {:ok, output, 4} = Main.run(["store", "restore", source, destination])
    assert output =~ "restore destination already exists"

    assert {:ok, output, 0} = Main.run(["store", "restore", source, destination, "--replace"])
    assert output =~ "Store restore complete"
    assert File.read!(destination) == "replacement"
  end

  test "store commands render restore and unsupported-backend failures as JSON" do
    root = tmp_dir!("twelvgaige_cli_store_json_errors")
    missing_source = Path.join(root, "missing.db")
    destination = Path.join(root, "restored.db")
    previous_store = Application.get_env(:twelvgaige, :store)
    Application.put_env(:twelvgaige, :store, {SQLiteStore, path: Path.join(root, "store.db")})

    on_exit(fn ->
      restore_store_config(previous_store)
    end)

    assert {:ok, output, 6} =
             Main.run(["store", "restore", missing_source, destination, "--format", "json"])

    assert %{
             "error" => %{
               "reason" => "backup_source_not_found",
               "message" => "backup source does not exist"
             }
           } = decode_cli_result!(output)

    Application.put_env(:twelvgaige, :store, Twelvgaige.Store.Memory)

    assert {:ok, output, 4} =
             Main.run(["store", "backup", Path.join(root, "backup.db"), "--format", "json"])

    assert %{
             "error" => %{
               "reason" => "store_backup_unsupported",
               "message" => message
             }
           } = decode_cli_result!(output)

    assert message =~ "does not support backup"
  end

  test "store migrate-sqlcipher requires explicit source, destination, and key env" do
    root = tmp_dir!("twelvgaige_cli_store_migration")
    source = Path.join(root, "source.db")
    destination = Path.join(root, "encrypted.db")

    assert {:ok, output, 4} = Main.run(["store", "migrate-sqlcipher"])
    assert output =~ "--source is required"

    assert {:ok, output, 4} =
             Main.run(["store", "migrate-sqlcipher", "--source", source])

    assert output =~ "--destination is required"

    assert {:ok, output, 4} =
             Main.run([
               "store",
               "migrate-sqlcipher",
               "--source",
               source,
               "--destination",
               destination
             ])

    assert output =~ "--key-env is required"

    assert {:ok, output, 4} =
             Main.run([
               "store",
               "migrate-sqlcipher",
               "--source",
               source,
               "--destination",
               destination,
               "--key-env",
               "TWELVGAIGE_MISSING_SQLCIPHER_KEY"
             ])

    assert output =~ "SQLCipher migration requires --key-env"
    refute File.exists?(destination)
  end

  test "store migrate-sqlcipher reports source and destination errors as JSON" do
    root = tmp_dir!("twelvgaige_cli_store_migration_json")
    missing_source = Path.join(root, "missing.db")
    destination = Path.join(root, "encrypted.db")
    key_env = "TWELVGAIGE_CLI_SQLCIPHER_KEY_#{System.unique_integer([:positive])}"
    System.put_env(key_env, "test-sqlcipher-key")

    on_exit(fn ->
      System.delete_env(key_env)
    end)

    assert {:ok, output, 6} =
             Main.run([
               "store",
               "migrate-sqlcipher",
               "--source",
               missing_source,
               "--destination",
               destination,
               "--key-env",
               key_env,
               "--format",
               "json"
             ])

    assert %{
             "error" => %{
               "reason" => "migration_source_not_found",
               "message" => "migration source does not exist"
             }
           } = decode_cli_result!(output)

    File.write!(destination, "already exists")

    assert {:ok, output, 4} =
             Main.run([
               "store",
               "migrate-sqlcipher",
               "--source",
               destination,
               "--destination",
               destination,
               "--key-env",
               key_env,
               "--format",
               "json"
             ])

    assert %{
             "error" => %{
               "reason" => "migration_same_path",
               "message" => "migration source and destination must differ"
             }
           } = decode_cli_result!(output)
  end

  test "store rewrap-envelope requires a backup and rotates envelope metadata" do
    root = tmp_dir!("twelvgaige_cli_store_rewrap")
    envelope_path = Path.join(root, "store-envelope.json")
    backup_path = Path.join(root, "store-envelope.backup.json")
    old_env = "TWELVGAIGE_CLI_OLD_REWRAP_KEY_#{System.unique_integer([:positive])}"
    new_env = "TWELVGAIGE_CLI_NEW_REWRAP_KEY_#{System.unique_integer([:positive])}"
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
             Main.run([
               "store",
               "rewrap-envelope",
               envelope_path,
               "--old-key-env",
               old_env,
               "--new-key-env",
               new_env
             ])

    assert output =~ "--backup is required"

    assert {:ok, output, 0} =
             Main.run([
               "store",
               "rewrap-envelope",
               envelope_path,
               "--backup",
               backup_path,
               "--old-key-env",
               old_env,
               "--new-key-env",
               new_env,
               "--format",
               "json"
             ])

    assert %{
             "status" => "ok",
             "mode" => "rewrap",
             "path" => ^envelope_path,
             "backup" => ^backup_path,
             "database_rekeyed" => false
           } = decode_cli_result!(output)

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
