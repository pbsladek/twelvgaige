defmodule Twelvgaige.Store.ConfigTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Store.Config
  alias Twelvgaige.Store.File, as: FileStore
  alias Twelvgaige.Store.Memory
  alias Twelvgaige.Store.SQLite

  setup do
    previous_config = Application.get_env(:twelvgaige, :store)
    previous_file_env = System.get_env("TWELVGAIGE_STORE_FILE")
    previous_sqlite_env = System.get_env("TWELVGAIGE_STORE_SQLITE")

    Application.delete_env(:twelvgaige, :store)
    System.delete_env("TWELVGAIGE_STORE_FILE")
    System.delete_env("TWELVGAIGE_STORE_SQLITE")

    on_exit(fn ->
      restore_app_config(previous_config)
      restore_env("TWELVGAIGE_STORE_FILE", previous_file_env)
      restore_env("TWELVGAIGE_STORE_SQLITE", previous_sqlite_env)
    end)

    :ok
  end

  test "defaults to memory store" do
    assert Config.resolve() == Memory
    assert Config.module(Memory) == Memory
    assert Config.child_spec(Memory) == Memory
  end

  test "application config wins over environment config" do
    System.put_env("TWELVGAIGE_STORE_FILE", "/tmp/ignored.etf")
    System.put_env("TWELVGAIGE_STORE_SQLITE", "/tmp/ignored.db")
    Application.put_env(:twelvgaige, :store, Memory)

    assert Config.resolve() == Memory
  end

  test "uses tuple store config from options" do
    config = {FileStore, path: "/tmp/twelvgaige.etf"}

    assert Config.resolve(store: config) == config
    assert Config.module(config) == FileStore
    assert Config.child_spec(config) == config
  end

  test "uses TWELVGAIGE_STORE_FILE when no application config is set" do
    System.put_env("TWELVGAIGE_STORE_FILE", "/tmp/twelvgaige-env.etf")

    assert Config.resolve() == {FileStore, path: "/tmp/twelvgaige-env.etf"}
  end

  test "uses TWELVGAIGE_STORE_SQLITE ahead of file env when no application config is set" do
    System.put_env("TWELVGAIGE_STORE_FILE", "/tmp/twelvgaige-env.etf")
    System.put_env("TWELVGAIGE_STORE_SQLITE", "/tmp/twelvgaige-env.db")

    assert Config.resolve() == {SQLite, path: "/tmp/twelvgaige-env.db"}
  end

  defp restore_app_config(nil), do: Application.delete_env(:twelvgaige, :store)
  defp restore_app_config(previous), do: Application.put_env(:twelvgaige, :store, previous)

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, previous), do: System.put_env(name, previous)
end
