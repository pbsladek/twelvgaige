defmodule Twelvgaige.Crypto.MacOSKeychainLiveTest do
  use ExUnit.Case, async: false

  @moduletag :keychain_live

  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyManager
  alias Twelvgaige.Crypto.KeyManager.MacOSKeychainBackend

  test "real macOS Keychain backend can create fetch rotate and delete a key" do
    if :os.type() == {:unix, :darwin} do
      assert System.get_env("TWELVGAIGE_KEYCHAIN_LIVE") == "1",
             "set TWELVGAIGE_KEYCHAIN_LIVE=1 to run live macOS Keychain tests"

      suffix = System.unique_integer([:positive])
      key_id = "twelvgaige-live-test-#{suffix}"
      service = "twelvgaige.live-test.#{suffix}"
      opts = [id: key_id, service: service]

      _ = KeyManager.retire_key(MacOSKeychainBackend, key_id, opts)
      on_exit(fn -> KeyManager.retire_key(MacOSKeychainBackend, key_id, opts) end)

      assert {:ok, %Key{id: ^key_id, backend: :macos_keychain, version: 1} = created} =
               KeyManager.create_key(MacOSKeychainBackend, opts)

      assert {:ok, %Key{id: ^key_id, version: 1}} =
               KeyManager.fetch_key(MacOSKeychainBackend, key_id, opts)

      assert {:ok, %Key{id: ^key_id, version: 2} = rotated} =
               KeyManager.rotate_key(MacOSKeychainBackend, key_id, opts)

      refute rotated.material.bytes == created.material.bytes

      assert {:ok, %Key{id: ^key_id, status: :retired}} =
               KeyManager.retire_key(MacOSKeychainBackend, key_id, opts)

      assert {:error, :key_not_found} =
               KeyManager.fetch_key(MacOSKeychainBackend, key_id, opts)
    end
  end
end
