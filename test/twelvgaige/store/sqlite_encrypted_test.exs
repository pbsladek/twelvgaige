defmodule Twelvgaige.Store.SQLiteEncryptedTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Store.SQLiteEncrypted

  @moduletag :persistence

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_sqlite_encrypted_#{System.unique_integer([:positive])}"
      )

    path = Path.join(dir, "store.db")
    on_exit(fn -> File.rm_rf(dir) end)
    %{path: path}
  end

  test "requires a SQLCipher key", %{path: path} do
    Process.flag(:trap_exit, true)

    assert {:error, :sqlcipher_key_required} =
             SQLiteEncrypted.start_link(path: path, name: :encrypted_store_no_key)

    refute File.exists?(path)
  end

  test "fails closed when the linked SQLite driver is not SQLCipher", %{path: path} do
    Process.flag(:trap_exit, true)

    assert {:error, :sqlcipher_unavailable} =
             SQLiteEncrypted.start_link(
               path: path,
               key: "test-key",
               name: :encrypted_store_unavailable
             )

    refute File.exists?(path)
  end

  test "restore helper refuses to overwrite unless replacement is explicit", %{path: path} do
    backup = Path.join(Path.dirname(path), "backup.db")
    destination = Path.join(Path.dirname(path), "destination.db")

    File.mkdir_p!(Path.dirname(path))
    File.write!(backup, "backup")
    File.write!(destination, "old")

    assert {:error, :restore_destination_exists} =
             SQLiteEncrypted.restore_backup(backup, destination)

    assert {:ok, %{"destination" => ^destination, "replaced" => true, "bytes" => 6}} =
             SQLiteEncrypted.restore_backup(backup, destination, replace?: true)

    assert File.read!(destination) == "backup"
  end
end
