defmodule Twelvgaige.Breech.DaemonTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.Daemon

  test "uses Unix sockets by default on non-Windows platforms" do
    runtime_dir =
      Path.join(System.tmp_dir!(), "twelvgaige_daemon_unix_#{System.unique_integer([:positive])}")

    opts = Daemon.server_opts(runtime_dir: runtime_dir, os_type: {:unix, :darwin})

    assert Keyword.fetch!(opts, :transport) == :unix
    assert Keyword.fetch!(opts, :socket_path) == Path.join(runtime_dir, "breech.sock")
    assert Keyword.fetch!(opts, :endpoint_path) == Path.join(runtime_dir, "breech.endpoint.json")
    assert Keyword.fetch!(opts, :lock_path) == Path.join(runtime_dir, "breech.lock")
  end

  test "uses authenticated loopback TCP by default on Windows until native pipes are verified" do
    runtime_dir =
      Path.join(System.tmp_dir!(), "twelvgaige_daemon_win_#{System.unique_integer([:positive])}")

    opts = Daemon.server_opts(runtime_dir: runtime_dir, os_type: {:win32, :nt})

    assert Keyword.fetch!(opts, :transport) == :tcp
    assert Keyword.fetch!(opts, :port) == 0
    refute Keyword.has_key?(opts, :pipe_path)
    assert Keyword.fetch!(opts, :endpoint_path) == Path.join(runtime_dir, "breech.endpoint.json")

    paths = Daemon.paths(runtime_dir: runtime_dir, os_type: {:win32, :nt})
    assert paths.transport == "tcp"
    assert paths.socket_path == nil
    assert paths.pipe_path =~ ~S(\\.\pipe\twelvgaige-)
    assert paths.windows_named_pipe == paths.pipe_path
  end

  test "keeps named pipe transport explicitly selectable for platform verification" do
    runtime_dir =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_daemon_npipe_#{System.unique_integer([:positive])}"
      )

    opts = Daemon.server_opts(runtime_dir: runtime_dir, transport: :npipe)

    assert Keyword.fetch!(opts, :transport) == :npipe
    assert Keyword.fetch!(opts, :pipe_path) =~ ~S(\\.\pipe\twelvgaige-)
  end
end
