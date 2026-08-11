defmodule Twelvgaige.Breech.LockTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.Lock

  setup do
    dir = Path.join(System.tmp_dir!(), "twelvgaige_lock_#{System.unique_integer([:positive])}")
    lock_path = Path.join(dir, "breech.lock")

    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, lock_path: lock_path}
  end

  test "acquires, verifies, and releases daemon singleton lock", %{
    dir: dir,
    lock_path: lock_path
  } do
    assert {:ok, lock} = Lock.acquire(path: lock_path, token: "owner-token")
    assert Lock.verified?(lock)

    assert {:ok, owner} = Lock.read_owner(lock_path)
    assert owner["kind"] == "twelvgaige.breech.lock"
    assert owner["token"] == "owner-token"
    assert owner["pid"] == System.pid()

    assert {:ok, %{mode: dir_mode}} = File.stat(dir)
    assert {:ok, %{mode: lock_mode}} = File.stat(lock_path)
    assert {:ok, %{mode: owner_mode}} = File.stat(Path.join(lock_path, "owner.json"))
    assert Bitwise.band(dir_mode, 0o077) == 0
    assert Bitwise.band(lock_mode, 0o077) == 0
    assert Bitwise.band(owner_mode, 0o077) == 0

    assert :ok = Lock.release(lock)
    refute File.exists?(lock_path)
  end

  test "rejects concurrent lock acquisition", %{lock_path: lock_path} do
    assert {:ok, lock} = Lock.acquire(path: lock_path, token: "first")

    assert {:error, {:already_locked, owner}} = Lock.acquire(path: lock_path, token: "second")
    assert owner["token"] == "first"

    assert :ok = Lock.release(lock)
  end

  test "does not release a lock owned by another token", %{lock_path: lock_path} do
    assert {:ok, %Lock{} = lock} = Lock.acquire(path: lock_path, token: "first")

    forged = %Lock{lock | token: "second"}
    assert {:error, :lock_not_owned} = Lock.release(forged)
    assert File.exists?(lock_path)

    assert :ok = Lock.release(lock)
  end
end
