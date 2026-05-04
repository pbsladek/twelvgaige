defmodule Twelvgaige.Crypto.KeyManagerTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Crypto.Envelope
  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyManager
  alias Twelvgaige.Crypto.KeyManager.EnvBackend
  alias Twelvgaige.Crypto.KeyManager.FileBackend
  alias Twelvgaige.Crypto.KeyManager.LinuxSecretServiceBackend
  alias Twelvgaige.Crypto.KeyManager.MacOSKeychainBackend
  alias Twelvgaige.Crypto.KeyManager.TestBackend
  alias Twelvgaige.Crypto.KeyManager.WindowsDPAPIBackend
  alias Twelvgaige.Crypto.KeyMaterial

  test "test backend supports create fetch rotate and retire through the behaviour" do
    assert {:ok, %Key{id: "round-store", version: 1} = created} =
             KeyManager.create_key(TestBackend, id: "round-store")

    assert {:ok, %Key{id: "round-store", version: 1}} =
             KeyManager.fetch_key(TestBackend, created.id)

    assert {:ok, %Key{id: "round-store", version: 2} = rotated} =
             KeyManager.rotate_key(TestBackend, created.id)

    refute rotated.material.bytes == created.material.bytes

    assert {:ok, %Key{id: "round-store", status: :retired}} =
             KeyManager.retire_key(TestBackend, created.id)

    assert {:error, :key_retired} = KeyManager.fetch_key(TestBackend, created.id)
  end

  test "key material and envelopes redact raw bytes in inspect output" do
    raw = String.duplicate("a", 32)
    assert {:ok, material} = KeyMaterial.new(raw)

    key = %Key{
      id: "redacted",
      backend: :test,
      status: :active,
      version: 1,
      material: material
    }

    envelope =
      Envelope.new(
        key_id: "redacted",
        key_backend: :test,
        algorithm: "test-wrap",
        wrapped_dek: "wrapped-secret"
      )

    refute inspect(material) =~ raw
    refute inspect(key) =~ raw
    assert inspect(key) =~ "[REDACTED]"
    refute inspect(envelope) =~ "wrapped-secret"
  end

  test "env backend requires explicit insecure-backend acceptance" do
    env = "TWELVGAIGE_TEST_KEY_#{System.unique_integer([:positive])}"
    value = "base64:" <> Base.encode64(String.duplicate("k", 32))

    System.put_env(env, value)
    on_exit(fn -> System.delete_env(env) end)

    assert {:error, :insecure_key_backend_not_allowed} =
             KeyManager.fetch_key(EnvBackend, "env-key", env: env)

    assert {:ok, %Key{id: "env-key", backend: :env, material: %KeyMaterial{}}} =
             KeyManager.fetch_key(EnvBackend, "env-key",
               env: env,
               allow_insecure_key_backend?: true
             )
  end

  test "file backend supports create fetch rotate and retire with explicit acceptance" do
    path = tmp_key_path()

    assert {:error, :insecure_key_backend_not_allowed} =
             KeyManager.create_key(FileBackend, id: "file-key", path: path)

    assert {:ok, %Key{id: "file-key", version: 1} = created} =
             KeyManager.create_key(FileBackend,
               id: "file-key",
               path: path,
               allow_insecure_key_backend?: true
             )

    assert File.exists?(path)

    assert {:ok, %Key{id: "file-key", version: 1}} =
             KeyManager.fetch_key(FileBackend, created.id,
               path: path,
               allow_insecure_key_backend?: true
             )

    assert {:ok, %Key{id: "file-key", version: 2} = rotated} =
             KeyManager.rotate_key(FileBackend, created.id,
               path: path,
               allow_insecure_key_backend?: true
             )

    refute rotated.material.bytes == created.material.bytes

    assert {:ok, %Key{id: "file-key", status: :retired}} =
             KeyManager.retire_key(FileBackend, created.id,
               path: path,
               allow_insecure_key_backend?: true
             )

    assert {:error, :key_retired} =
             KeyManager.fetch_key(FileBackend, created.id,
               path: path,
               allow_insecure_key_backend?: true
             )
  end

  @tag :posix_only
  test "file backend rejects group or world readable key files where modes are exposed" do
    posix_only(fn ->
      path = tmp_key_path()

      assert {:ok, %Key{id: "file-key"}} =
               KeyManager.create_key(FileBackend,
                 id: "file-key",
                 path: path,
                 allow_insecure_key_backend?: true
               )

      File.chmod!(path, 0o644)

      assert {:error, {:insecure_key_file_mode, ^path}} =
               KeyManager.fetch_key(FileBackend, "file-key",
                 path: path,
                 allow_insecure_key_backend?: true
               )
    end)
  end

  test "macOS keychain backend maps create fetch rotate and retire to security commands" do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    runner = fake_security_runner(store)

    opts = [
      id: "keychain-key",
      platform: {:unix, :darwin},
      runner: runner,
      service: "twelvgaige.test"
    ]

    assert {:ok, %Key{id: "keychain-key", backend: :macos_keychain, version: 1} = created} =
             KeyManager.create_key(MacOSKeychainBackend, opts)

    assert created.metadata["service"] == "twelvgaige.test"

    assert {:ok, %Key{id: "keychain-key", version: 1}} =
             KeyManager.fetch_key(MacOSKeychainBackend, "keychain-key", opts)

    assert {:ok, %Key{id: "keychain-key", version: 2} = rotated} =
             KeyManager.rotate_key(MacOSKeychainBackend, "keychain-key", opts)

    refute rotated.material.bytes == created.material.bytes

    assert {:ok, %Key{id: "keychain-key", status: :retired}} =
             KeyManager.retire_key(MacOSKeychainBackend, "keychain-key", opts)

    assert {:error, :key_not_found} =
             KeyManager.fetch_key(MacOSKeychainBackend, "keychain-key", opts)
  end

  test "macOS keychain backend rejects non-macOS platforms" do
    assert {:error, :unsupported_key_backend_platform} =
             KeyManager.create_key(MacOSKeychainBackend,
               id: "keychain-key",
               platform: {:unix, :linux},
               runner: fake_security_runner(self())
             )
  end

  test "Linux Secret Service backend maps lifecycle to secret-tool commands" do
    {:ok, store} = Agent.start_link(fn -> %{} end)
    runner = fake_secret_tool_runner(store)

    opts = [
      id: "linux-key",
      platform: {:unix, :linux},
      runner: runner,
      service: "twelvgaige.test"
    ]

    assert {:ok, %Key{id: "linux-key", backend: :linux_secret_service, version: 1} = created} =
             KeyManager.create_key(LinuxSecretServiceBackend, opts)

    assert created.metadata["service"] == "twelvgaige.test"
    assert created.metadata["storage"] == "secret_service"

    assert {:ok, %Key{id: "linux-key", version: 1}} =
             KeyManager.fetch_key(LinuxSecretServiceBackend, "linux-key", opts)

    assert {:ok, %Key{id: "linux-key", version: 2} = rotated} =
             KeyManager.rotate_key(LinuxSecretServiceBackend, "linux-key", opts)

    refute rotated.material.bytes == created.material.bytes

    assert {:ok, %Key{id: "linux-key", status: :retired}} =
             KeyManager.retire_key(LinuxSecretServiceBackend, "linux-key", opts)

    assert {:error, :key_not_found} =
             KeyManager.fetch_key(LinuxSecretServiceBackend, "linux-key", opts)
  end

  test "Linux Secret Service backend rejects non-Linux platforms" do
    assert {:error, :unsupported_key_backend_platform} =
             KeyManager.create_key(LinuxSecretServiceBackend,
               id: "linux-key",
               platform: {:unix, :darwin},
               runner: fake_secret_tool_runner(self())
             )
  end

  test "windows DPAPI backend stores protected payloads and supports lifecycle" do
    path = tmp_key_path()
    runner = fake_dpapi_runner()

    opts = [
      id: "dpapi-key",
      platform: {:win32, :nt},
      path: path,
      runner: runner
    ]

    assert {:ok, %Key{id: "dpapi-key", backend: :windows_dpapi, version: 1} = created} =
             KeyManager.create_key(WindowsDPAPIBackend, opts)

    assert File.exists?(path)
    refute File.read!(path) =~ created.material.bytes
    assert File.read!(path) =~ "protected_payload"

    assert {:ok, %Key{id: "dpapi-key", version: 1}} =
             KeyManager.fetch_key(WindowsDPAPIBackend, "dpapi-key", opts)

    assert {:ok, %Key{id: "dpapi-key", version: 2} = rotated} =
             KeyManager.rotate_key(WindowsDPAPIBackend, "dpapi-key", opts)

    refute rotated.material.bytes == created.material.bytes

    assert {:ok, %Key{id: "dpapi-key", status: :retired}} =
             KeyManager.retire_key(WindowsDPAPIBackend, "dpapi-key", opts)

    assert {:error, :key_retired} =
             KeyManager.fetch_key(WindowsDPAPIBackend, "dpapi-key", opts)
  end

  test "windows DPAPI backend rejects non-Windows platforms" do
    assert {:error, :unsupported_key_backend_platform} =
             KeyManager.create_key(WindowsDPAPIBackend,
               id: "dpapi-key",
               platform: {:unix, :darwin},
               path: tmp_key_path(),
               runner: fake_dpapi_runner()
             )
  end

  defp tmp_key_path do
    dir =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-key-manager-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(dir)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    Path.join(dir, "key.json")
  end

  defp posix_only(fun) do
    case :os.type() do
      {:win32, _name} -> :ok
      _posix -> fun.()
    end
  end

  defp fake_security_runner(store) do
    fn args, _opts ->
      case args do
        ["find-generic-password" | rest] ->
          key = security_key(rest)

          case Agent.get(store, &Map.get(&1, key)) do
            nil -> {"not found", 44}
            payload -> {payload, 0}
          end

        ["add-generic-password" | rest] ->
          key = security_key(rest)
          update? = "--update" in rest or "-U" in rest
          payload = security_value(rest, "-w")

          Agent.get_and_update(store, fn entries ->
            cond do
              is_nil(payload) ->
                {{"missing password", 1}, entries}

              Map.has_key?(entries, key) and not update? ->
                {{"already exists", 45}, entries}

              true ->
                {{"", 0}, Map.put(entries, key, payload)}
            end
          end)

        ["delete-generic-password" | rest] ->
          key = security_key(rest)

          Agent.get_and_update(store, fn entries ->
            if Map.has_key?(entries, key) do
              {{"", 0}, Map.delete(entries, key)}
            else
              {{"not found", 44}, entries}
            end
          end)
      end
    end
  end

  defp security_key(args), do: {security_value(args, "-s"), security_value(args, "-a")}

  defp security_value([flag, value | _rest], flag), do: value
  defp security_value([_other | rest], flag), do: security_value(rest, flag)
  defp security_value([], _flag), do: nil

  defp fake_secret_tool_runner(store) do
    fn args, stdin, _opts ->
      case args do
        ["lookup" | rest] ->
          key = secret_service_key(rest)

          case Agent.get(store, &Map.get(&1, key)) do
            nil -> {"not found", 1}
            payload -> {payload, 0}
          end

        ["store", "--label", _label | rest] ->
          key = secret_service_key(rest)

          Agent.update(store, &Map.put(&1, key, stdin))
          {"", 0}

        ["clear" | rest] ->
          key = secret_service_key(rest)

          Agent.get_and_update(store, fn entries ->
            if Map.has_key?(entries, key) do
              {{"", 0}, Map.delete(entries, key)}
            else
              {{"not found", 1}, entries}
            end
          end)
      end
    end
  end

  defp secret_service_key(args) do
    args
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [key, value] -> {key, value}
      [key] -> {key, nil}
    end)
    |> Map.new()
    |> Map.take(["application", "service", "id"])
  end

  defp fake_dpapi_runner do
    fn args, stdin, _opts ->
      script = List.last(args)

      cond do
        String.contains?(script, "]::Protect") ->
          {"dpapi:" <> Base.encode64(stdin), 0}

        String.contains?(script, "]::Unprotect") ->
          with "dpapi:" <> encoded <- stdin,
               {:ok, decoded} <- Base.decode64(encoded) do
            {decoded, 0}
          else
            _invalid -> {"invalid protected payload", 1}
          end

        true ->
          {"unknown script", 1}
      end
    end
  end
end
