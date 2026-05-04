defmodule Twelvgaige.Store.SQLiteEncryptedLiveTest do
  use ExUnit.Case, async: false

  @moduletag :sqlcipher_live

  use Twelvgaige.TestSupport.StoreContract, persistent: true

  alias Twelvgaige.Store.SQLite, as: SQLiteStore
  alias Twelvgaige.Store.SQLite.Migration
  alias Twelvgaige.Store.SQLiteEncrypted

  setup do
    assert System.get_env("TWELVGAIGE_SQLCIPHER_LIVE") == "1",
           "set TWELVGAIGE_SQLCIPHER_LIVE=1 to run live SQLCipher store tests"

    assert is_binary(System.get_env("TWELVGAIGE_SQLCIPHER_LIVE_KEY")),
           "set TWELVGAIGE_SQLCIPHER_LIVE_KEY to run live SQLCipher store tests"

    dir =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_sqlite_encrypted_live_#{System.unique_integer([:positive])}"
      )

    path = Path.join(dir, "store.db")
    name = :"sqlite_encrypted_live_#{System.unique_integer([:positive])}"

    on_exit(fn -> File.rm_rf(dir) end)

    %{
      name: name,
      path: path,
      store: name,
      store_module: SQLiteEncrypted,
      store_child_id: name,
      store_start_opts: [
        name: name,
        path: path,
        key_env: "TWELVGAIGE_SQLCIPHER_LIVE_KEY"
      ]
    }
  end

  test "encrypted store files do not contain raw canary payloads", %{
    name: name,
    path: path,
    store_start_opts: opts
  } do
    start_supervised!({SQLiteEncrypted, opts})

    canary = "twelvgaige-raw-canary-#{System.unique_integer([:positive])}"

    snapshot = %{
      id: "encrypted_canary_round",
      status: :firing,
      version: 0,
      input: %{"secret" => canary},
      shots: [%{id: "root", kind: :slug, status: :pending, attempt: 0, output: canary}]
    }

    manifest = %{
      round_id: "encrypted_canary_round",
      shell_id: "encrypted_canary",
      workflow: %{id: "encrypted_canary", canary: canary}
    }

    audit = [
      %{
        event_type: :round_created,
        round_id: "encrypted_canary_round",
        actor: "system",
        payload: %{canary: canary}
      }
    ]

    assert :ok = GenServer.call(name, {:create_round, snapshot, manifest, audit})

    bytes =
      [path, path <> "-wal", path <> "-shm"]
      |> Enum.filter(&File.exists?/1)
      |> Enum.map(&File.read!/1)
      |> IO.iodata_to_binary()

    refute bytes =~ canary
  end

  test "plaintext SQLite store migrates to SQLCipher and reopens with key", %{
    name: name,
    path: destination
  } do
    source = destination <> ".plain"
    source_name = :"sqlite_plain_source_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec({SQLiteStore, name: source_name, path: source}, id: source_name)
    )

    snapshot = %{id: "migrated_round", status: :firing, version: 0}
    manifest = %{round_id: "migrated_round", shell_id: "workflow", workflow: %{id: "workflow"}}
    assert :ok = GenServer.call(source_name, {:create_round, snapshot, manifest, []})
    stop_supervised!(source_name)

    assert {:ok, %{"destination" => ^destination, "encrypted" => true}} =
             Migration.plaintext_to_encrypted(source, destination,
               key_env: "TWELVGAIGE_SQLCIPHER_LIVE_KEY"
             )

    start_supervised!(
      {SQLiteEncrypted, name: name, path: destination, key_env: "TWELVGAIGE_SQLCIPHER_LIVE_KEY"}
    )

    assert {:ok, ^snapshot} = GenServer.call(name, {:get_round, "migrated_round"})
    assert {:ok, ^manifest} = GenServer.call(name, {:get_manifest, "migrated_round"})
  end
end
