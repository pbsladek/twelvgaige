defmodule Twelvgaige.Store.SQLiteMigrationTest do
  use ExUnit.Case, async: false

  @moduletag :persistence

  alias Twelvgaige.Store.SQLite, as: SQLiteStore
  alias Twelvgaige.Store.SQLite.Migration

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_sqlite_migration_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, source: Path.join(dir, "source.db"), destination: Path.join(dir, "encrypted.db")}
  end

  test "requires a SQLCipher key before touching source or destination", %{
    source: source,
    destination: destination
  } do
    assert {:error, :sqlcipher_key_required} =
             Migration.plaintext_to_encrypted(source, destination, key_env: "MISSING_KEY_ENV")

    refute File.exists?(destination)
  end

  test "requires an existing source store when key is present", %{
    source: source,
    destination: destination
  } do
    assert {:error, :migration_source_not_found} =
             Migration.plaintext_to_encrypted(source, destination, key: "secret")

    refute File.exists?(destination)
  end

  test "refuses same source and destination path before probing SQLCipher", %{source: source} do
    File.write!(source, "not a store")

    assert {:error, :migration_same_path} =
             Migration.plaintext_to_encrypted(source, source, key: "secret")
  end

  test "refuses to overwrite an existing destination unless replacement is explicit", %{
    source: source,
    destination: destination
  } do
    create_plaintext_source!(source)
    File.write!(destination, "existing")

    assert {:error, :migration_destination_exists} =
             Migration.plaintext_to_encrypted(source, destination, key: "secret")

    assert File.read!(destination) == "existing"
  end

  test "fails closed before creating target when SQLCipher is unavailable", %{
    source: source,
    destination: destination
  } do
    create_plaintext_source!(source)

    case Migration.plaintext_to_encrypted(source, destination, key: "secret") do
      {:error, :sqlcipher_unavailable} ->
        refute File.exists?(destination)

      {:ok, report} ->
        assert %{"encrypted" => true, "destination" => ^destination} = report
        assert File.exists?(destination)
    end
  end

  defp create_plaintext_source!(path) do
    name = :"sqlite_migration_source_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({SQLiteStore, name: name, path: path}, id: name))

    snapshot = %{id: "migration_round", status: :firing, version: 0}
    manifest = %{round_id: "migration_round", shell_id: "workflow", workflow: %{id: "workflow"}}
    assert :ok = GenServer.call(name, {:create_round, snapshot, manifest, []})

    stop_supervised!(name)
  end
end
