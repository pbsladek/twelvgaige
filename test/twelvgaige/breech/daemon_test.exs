defmodule Twelvgaige.Breech.DaemonTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.Daemon

  test "uses Unix sockets by default" do
    runtime_dir =
      Path.join(System.tmp_dir!(), "twelvgaige_daemon_unix_#{System.unique_integer([:positive])}")

    opts = Daemon.server_opts(runtime_dir: runtime_dir)

    assert Keyword.fetch!(opts, :transport) == :unix
    assert Keyword.fetch!(opts, :socket_path) == Path.join(runtime_dir, "breech.sock")
    assert Keyword.fetch!(opts, :endpoint_path) == Path.join(runtime_dir, "breech.endpoint.json")
    assert Keyword.fetch!(opts, :lock_path) == Path.join(runtime_dir, "breech.lock")
  end

  test "rejects transports outside Unix sockets and loopback TCP" do
    assert {:error, {:unsupported_ipc_transport, :unsupported}} =
             Twelvgaige.Breech.IPC.Server.start_link(transport: :unsupported)
  end
end
