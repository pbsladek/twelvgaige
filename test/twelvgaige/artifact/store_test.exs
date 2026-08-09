defmodule Twelvgaige.Artifact.StoreTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Artifact.Store

  test "encrypts artifacts, authenticates references, and prunes by retention class" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige-artifacts-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)
    now = ~U[2026-08-02 12:00:00Z]
    server = start_supervised!({Store, name: nil, root: root, key: :crypto.strong_rand_bytes(32)})

    assert {:ok, ref} =
             Store.put(%{secret: "api_key=very-secret"},
               server: server,
               round_id: "round_1",
               now: now
             )

    assert ref.encrypted
    assert ref.retention_class == :raw
    assert DateTime.diff(ref.expires_at, now, :day) == 30
    assert {:ok, %{secret: "api_key=very-secret"}} = Store.get(ref, server: server)

    [path] = Path.wildcard(Path.join(root, "*.artifact"))
    refute File.read!(path) =~ "very-secret"

    assert {:ok, 0} = Store.prune(server: server, now: DateTime.add(now, 29, :day))
    assert {:ok, 1} = Store.prune(server: server, now: DateTime.add(now, 30, :day))
    assert {:error, :enoent} = Store.get(ref, server: server)
  end

  test "fails closed without a 256-bit key" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige-artifacts-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(root) end)

    previous = Process.flag(:trap_exit, true)
    on_exit(fn -> Process.flag(:trap_exit, previous) end)

    assert {:error, :artifact_key_must_be_32_bytes} =
             Store.start_link(name: nil, root: root, key: "short")
  end

  test "rotates every encrypted artifact and persists active-session retention holds" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-artifact-rotation-#{System.unique_integer([:positive])}"
      )

    old_key = :crypto.strong_rand_bytes(32)
    new_key = :crypto.strong_rand_bytes(32)
    now = ~U[2026-08-02 12:00:00Z]
    server = start_supervised!({Store, name: nil, root: root, key: old_key, key_id: "old"})

    assert {:ok, first} = Store.put(%{value: 1}, server: server, now: now)
    assert {:ok, second} = Store.put(%{value: 2}, server: server, now: now)
    assert :ok = Store.hold(first.id, :indefinite, server: server)

    assert {:ok, %{artifacts_rotated: 2, old_key_id: "old", new_key_id: "new"}} =
             Store.rotate_key(new_key, server: server, key_id: "new")

    assert {:ok, %{value: 1}} = Store.get(first, server: server)
    assert {:ok, %{value: 2}} = Store.get(second, server: server)

    assert {:ok, %{current_key_id: "new", readable_key_ids: ["new"]}} =
             Store.inventory(server: server)

    assert {:ok, 1} = Store.prune(server: server, now: DateTime.add(now, 31, :day))
    assert {:ok, %{value: 1}} = Store.get(first, server: server)
    assert {:error, :enoent} = Store.get(second, server: server)

    GenServer.stop(server)

    restarted =
      start_supervised!(
        {Store, name: nil, root: root, key: new_key, key_id: "new"},
        id: :restarted_artifact_store
      )

    assert {:ok, %{holds: holds}} = Store.inventory(server: restarted)
    assert holds[first.id] == :indefinite
    assert :ok = Store.release_hold(first.id, server: restarted)
    assert {:ok, 1} = Store.prune(server: restarted, now: DateTime.add(now, 31, :day))
  end
end
