defmodule Twelvgaige.Manager.Store.LocalTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.Store.Local

  test "starts the durable memory store at the requested owner-local path" do
    path =
      Path.join(System.tmp_dir!(), "manager-local-#{System.unique_integer([:positive])}.term")

    on_exit(fn -> File.rm_rf(path) end)

    assert {:ok, pid} = Local.start_link(path: path, name: nil)
    assert Process.alive?(pid)
    assert :sys.get_state(pid).persistence_path == path
  end

  test "requires an explicit persistence path" do
    assert_raise KeyError, fn -> Local.start_link([]) end
  end
end
