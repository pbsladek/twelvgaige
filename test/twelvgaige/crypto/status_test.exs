defmodule Twelvgaige.Crypto.StatusTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Crypto.Status
  alias Twelvgaige.Store.Memory
  alias Twelvgaige.Store.SQLite
  alias Twelvgaige.Store.SQLiteEncrypted

  test "reports memory store as unencrypted and non-durable" do
    report = Status.report(store_config: Memory, http_listener: false)

    assert %{
             "status" => "ok",
             "store" => %{
               "backend" => "memory",
               "persistent" => false,
               "encrypted" => false,
               "encryption" => "none",
               "warnings" => warnings
             }
           } = report

    assert "memory store is not durable" in warnings
    assert "local store is not encrypted by Twelvgaige" in warnings
  end

  test "reports sqlite summary retention without claiming encryption" do
    report =
      Status.report(
        store_config: {SQLite, path: "/tmp/twelvgaige.sqlite3", sensitive_retention: :summary},
        http_listener: false
      )

    assert %{
             "store" => %{
               "backend" => "sqlite",
               "persistent" => true,
               "encrypted" => false,
               "sensitive_retention" => "summary",
               "warnings" => warnings
             }
           } = report

    assert Enum.any?(warnings, &String.contains?(&1, "sensitive payloads are summarized"))
  end

  test "reports encrypted sqlite as SQLCipher and fail-closed" do
    report =
      Status.report(
        store_config: {SQLiteEncrypted, path: "/tmp/twelvgaige.enc.sqlite3", key_env: "KEY_ENV"},
        http_listener: false
      )

    assert %{
             "store" => %{
               "backend" => "sqlite_encrypted",
               "persistent" => true,
               "encrypted" => true,
               "encryption" => "sqlcipher",
               "key_backend" => "env",
               "warnings" => warnings
             }
           } = report

    assert Enum.any?(warnings, &String.contains?(&1, "fails closed"))
  end

  test "reports loopback HTTP as local-only and not native TLS" do
    report = Status.report(store_config: Memory, http_listener: [ip: {127, 0, 0, 1}])

    assert %{
             "http_listener" => %{
               "enabled" => true,
               "bind" => "127.0.0.1",
               "tls_mode" => "loopback_http",
               "native_tls_supported" => false,
               "mtls_supported" => false,
               "warnings" => []
             }
           } = report
  end

  test "reports remote proxy mode as proxy-terminated transport security" do
    report =
      Status.report(
        store_config: Memory,
        http_listener: [
          ip: {0, 0, 0, 0},
          allow_remote?: true,
          bearer_token: "secret",
          behind_tls_proxy?: true
        ]
      )

    assert %{
             "http_listener" => %{
               "bind" => "0.0.0.0",
               "tls_mode" => "trusted_proxy",
               "bearer_configured" => true,
               "warnings" => warnings
             }
           } = report

    assert Enum.any?(warnings, &String.contains?(&1, "configured proxy"))
  end

  test "reports tls options as unsupported until native TLS lands" do
    report =
      Status.report(
        store_config: Memory,
        http_listener: [
          ip: {0, 0, 0, 0},
          allow_remote?: true,
          bearer_token: "secret",
          tls_options: [certfile: "server.crt"]
        ]
      )

    assert %{
             "http_listener" => %{
               "tls_mode" => "native_tls_not_implemented",
               "warnings" => warnings
             }
           } = report

    assert Enum.any?(warnings, &String.contains?(&1, "native TLS is not implemented"))
  end

  test "reports release artifact attestations without claiming project-managed signing keys" do
    report = Status.report(store_config: Memory, http_listener: false)

    assert %{
             "release" => %{
               "checksums" => true,
               "signed_checksums" => false,
               "attestations" => true,
               "warnings" => warnings
             }
           } = report

    assert Enum.any?(warnings, &String.contains?(&1, "project-managed signing keys"))
  end

  test "reports explicit env key backend risk" do
    report =
      Status.report(
        store_config: Memory,
        http_listener: false,
        key_manager: {Twelvgaige.Crypto.KeyManager.EnvBackend, allow_insecure_key_backend?: true}
      )

    assert %{
             "key_manager" => %{
               "enabled" => true,
               "backend" => "env",
               "os_protected" => false,
               "allow_insecure_key_backend" => true,
               "warnings" => warnings
             }
           } = report

    assert Enum.any?(warnings, &String.contains?(&1, "not OS-protected"))
  end

  test "reports macOS keychain backend as OS protected command-wrapper integration" do
    report =
      Status.report(
        store_config: Memory,
        http_listener: false,
        key_manager: Twelvgaige.Crypto.KeyManager.MacOSKeychainBackend
      )

    assert %{
             "key_manager" => %{
               "enabled" => true,
               "backend" => "macos_keychain",
               "os_protected" => true,
               "warnings" => warnings
             }
           } = report

    assert Enum.any?(warnings, &String.contains?(&1, "security command wrapper"))
  end

  test "reports Linux Secret Service backend as desktop Linux only" do
    report =
      Status.report(
        store_config: Memory,
        http_listener: false,
        key_manager: Twelvgaige.Crypto.KeyManager.LinuxSecretServiceBackend
      )

    assert %{
             "key_manager" => %{
               "enabled" => true,
               "backend" => "linux_secret_service",
               "os_protected" => true,
               "warnings" => warnings
             }
           } = report

    assert Enum.any?(warnings, &String.contains?(&1, "not universal headless server support"))
  end

  test "reports Windows DPAPI backend as OS protected pending release verification" do
    report =
      Status.report(
        store_config: Memory,
        http_listener: false,
        key_manager: Twelvgaige.Crypto.KeyManager.WindowsDPAPIBackend
      )

    assert %{
             "key_manager" => %{
               "enabled" => true,
               "backend" => "windows_dpapi",
               "os_protected" => true,
               "warnings" => warnings
             }
           } = report

    assert Enum.any?(warnings, &String.contains?(&1, "Windows release verification is pending"))
  end
end
