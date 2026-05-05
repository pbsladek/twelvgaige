defmodule Twelvgaige.Breech.IPC.EndpointTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.Breech.IPC.Protocol
  alias Twelvgaige.Breech.Lock

  setup do
    dir =
      Path.join(System.tmp_dir!(), "twelvgaige_endpoint_#{System.unique_integer([:positive])}")

    path = Path.join(dir, "breech.endpoint.json")

    on_exit(fn -> File.rm_rf(dir) end)

    %{dir: dir, path: path}
  end

  test "writes and discovers a private TCP endpoint file", %{dir: dir, path: path} do
    address = {:tcp, {127, 0, 0, 1}, 44_321}

    assert :ok = Endpoint.write(%{address: address, token: "secret"}, path: path)

    assert {:ok, endpoint} = Endpoint.discover(path: path)
    assert endpoint.address == address
    assert endpoint.address_text == "tcp://127.0.0.1:44321"
    assert endpoint.token == "secret"
    assert endpoint.path == path
    assert endpoint.api_version == Protocol.api_version()
    assert endpoint.version == Twelvgaige.version()

    unless match?({:win32, _name}, :os.type()) do
      assert {:ok, %{mode: dir_mode}} = File.stat(dir)
      assert {:ok, %{mode: file_mode}} = File.stat(path)
      assert Bitwise.band(dir_mode, 0o077) == 0
      assert Bitwise.band(file_mode, 0o077) == 0
    end
  end

  test "writes and discovers a Unix socket endpoint file", %{path: path} do
    socket_path = Path.join(Path.dirname(path), "breech.sock")
    address = {:unix, socket_path}

    assert :ok = Endpoint.write(%{address: address, token: nil}, path: path)

    assert {:ok, endpoint} = Endpoint.discover(path: path)
    assert endpoint.address == address
    assert endpoint.address_text == "unix://#{socket_path}"
    assert endpoint.api_version == Protocol.api_version()
    assert endpoint.token == nil
  end

  test "writes and discovers a Windows named pipe endpoint file", %{path: path} do
    pipe_path = ~S(\\.\pipe\twelvgaige-test-breech)
    address = {:npipe, pipe_path}

    assert :ok = Endpoint.write(%{address: address, token: nil}, path: path)

    assert {:ok, endpoint} = Endpoint.discover(path: path)
    assert endpoint.address == address
    assert endpoint.address_text == "npipe:////./pipe/twelvgaige-test-breech"
    assert endpoint.api_version == Protocol.api_version()
    assert endpoint.token == nil
  end

  test "Windows runtime defaults use local app data", %{path: _path} do
    runtime_dir =
      Endpoint.default_runtime_dir(
        os_type: {:win32, :nt},
        env: %{"LOCALAPPDATA" => "C:/Users/test/AppData/Local"}
      )

    assert runtime_dir == Path.join(["C:/Users/test/AppData/Local", "Twelvgaige", "run"])
  end

  test "missing endpoint discovers as none", %{path: path} do
    assert :none = Endpoint.discover(path: path)
  end

  test "endpoint discovery rejects mismatched API versions", %{path: path} do
    File.mkdir_p!(Path.dirname(path))

    endpoint = %{
      "kind" => "twelvgaige.breech.endpoint",
      "api_version" => Protocol.api_version() + 1,
      "version" => Twelvgaige.version(),
      "address" => "tcp://127.0.0.1:44325",
      "token" => "secret",
      "pid" => System.pid(),
      "created_at" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }

    File.write!(path, Jason.encode!(endpoint))

    assert {:error, error} = Endpoint.discover(path: path)
    assert error.class == :policy_error
    assert error.reason == :daemon_version_mismatch
    assert error.details.expected_api_version == Protocol.api_version()
    assert error.details.endpoint_api_version == Protocol.api_version() + 1
  end

  test "endpoint discovery reports malformed JSON", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not-json")

    assert {:error, %Jason.DecodeError{}} = Endpoint.discover(path: path)
  end

  test "endpoint discovery reports invalid endpoint addresses", %{path: path} do
    File.mkdir_p!(Path.dirname(path))

    endpoint = %{
      "kind" => "twelvgaige.breech.endpoint",
      "api_version" => Protocol.api_version(),
      "version" => Twelvgaige.version(),
      "address" => "tcp://localhost:44325",
      "token" => "secret",
      "pid" => System.pid(),
      "created_at" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }

    File.write!(path, Jason.encode!(endpoint))

    assert {:error, :invalid_ipc_address} = Endpoint.discover(path: path)
  end

  test "stale cleanup requires a verified singleton lock", %{path: path} do
    assert :ok =
             Endpoint.write(%{address: {:tcp, {127, 0, 0, 1}, 44_322}, token: "secret"},
               path: path
             )

    assert {:error, :lock_required} = Endpoint.cleanup_stale(path: path)
    assert {:ok, _endpoint} = Endpoint.read(path: path)

    assert :ok =
             Endpoint.cleanup_stale(
               path: path,
               lock_verified?: true,
               probe: fn _endpoint -> {:error, :daemon_unavailable} end
             )

    assert :none = Endpoint.discover(path: path)
  end

  test "stale cleanup removes corrupt endpoint files after lock verification", %{path: path} do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "{not-json")

    assert :ok = Endpoint.cleanup_stale(path: path, lock_verified?: true)
    assert :none = Endpoint.discover(path: path)
  end

  test "stale cleanup removes endpoint files with invalid addresses after lock verification", %{
    path: path
  } do
    File.mkdir_p!(Path.dirname(path))

    endpoint = %{
      "kind" => "twelvgaige.breech.endpoint",
      "api_version" => Protocol.api_version(),
      "version" => Twelvgaige.version(),
      "address" => "tcp://localhost:44325",
      "token" => "secret",
      "pid" => System.pid(),
      "created_at" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }

    File.write!(path, Jason.encode!(endpoint))

    assert :ok = Endpoint.cleanup_stale(path: path, lock_verified?: true)
    assert :none = Endpoint.discover(path: path)
  end

  test "stale cleanup does not remove a live daemon endpoint", %{path: path} do
    assert :ok =
             Endpoint.write(%{address: {:tcp, {127, 0, 0, 1}, 44_323}, token: "secret"},
               path: path
             )

    assert {:error, :daemon_running} =
             Endpoint.cleanup_stale(
               path: path,
               lock_verified?: true,
               probe: fn _endpoint -> {:ok, %{"status" => "running"}} end
             )

    assert {:ok, _endpoint} = Endpoint.read(path: path)
  end

  test "stale cleanup accepts a verified daemon lock", %{dir: dir, path: path} do
    lock_path = Path.join(dir, "breech.lock")
    assert {:ok, lock} = Lock.acquire(path: lock_path)

    assert :ok =
             Endpoint.write(%{address: {:tcp, {127, 0, 0, 1}, 44_324}, token: "secret"},
               path: path
             )

    assert :ok =
             Endpoint.cleanup_stale(
               path: path,
               lock: lock,
               probe: fn _endpoint -> {:error, :daemon_unavailable} end
             )

    assert :none = Endpoint.discover(path: path)
    assert :ok = Lock.release(lock)
  end
end
