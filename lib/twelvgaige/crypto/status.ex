defmodule Twelvgaige.Crypto.Status do
  @moduledoc """
  Reports the current cryptography and transport-security posture.

  This module is intentionally descriptive. It must not claim encryption,
  signing, TLS, or mTLS unless the corresponding implementation is active.
  """

  alias Twelvgaige.Store.Config, as: StoreConfig
  alias Twelvgaige.Store.File, as: FileStore
  alias Twelvgaige.Store.Memory
  alias Twelvgaige.Store.SQLite
  alias Twelvgaige.Store.SQLiteEncrypted

  @spec report(keyword()) :: map()
  def report(opts \\ []) do
    store_config = Keyword.get(opts, :store_config, StoreConfig.resolve())

    http_config =
      Keyword.get(opts, :http_listener, Application.get_env(:twelvgaige, :http_listener))

    key_manager_config =
      Keyword.get(opts, :key_manager, Application.get_env(:twelvgaige, :key_manager, false))

    %{
      "status" => "ok",
      "store" => store_status(store_config),
      "key_manager" => key_manager_status(key_manager_config),
      "http_listener" => http_listener_status(http_config),
      "providers" => provider_status(),
      "audit" => audit_status(),
      "release" => release_status()
    }
  end

  defp store_status(config) do
    {module, opts} = normalize_store_config(config)
    backend = store_backend(module)
    sensitive_retention = opts |> Keyword.get(:sensitive_retention, :redacted) |> to_string()

    %{
      "backend" => backend,
      "persistent" => backend in ["file", "sqlite", "sqlite_encrypted"],
      "encrypted" => backend == "sqlite_encrypted",
      "encryption" => store_encryption(backend),
      "key_ref" => nil,
      "key_backend" => store_key_backend(backend, opts),
      "sensitive_retention" => sensitive_retention,
      "warnings" => store_warnings(backend, sensitive_retention)
    }
  end

  defp key_manager_status(config) when config in [false, nil] do
    %{
      "enabled" => false,
      "backend" => nil,
      "os_protected" => false,
      "allow_insecure_key_backend" => false,
      "warnings" => []
    }
  end

  defp key_manager_status({backend, opts}) when is_atom(backend) and is_list(opts) do
    insecure_accepted? = Keyword.get(opts, :allow_insecure_key_backend?, false) == true

    %{
      "enabled" => true,
      "backend" => backend_name(backend),
      "os_protected" => os_protected_backend?(backend),
      "allow_insecure_key_backend" => insecure_accepted?,
      "warnings" => key_manager_warnings(backend, insecure_accepted?)
    }
  end

  defp key_manager_status(backend) when is_atom(backend), do: key_manager_status({backend, []})

  defp key_manager_status(_config) do
    %{
      "enabled" => false,
      "backend" => "invalid_config",
      "os_protected" => false,
      "allow_insecure_key_backend" => false,
      "warnings" => ["key_manager config must be false, nil, a module, or {module, opts}"]
    }
  end

  defp backend_name(Twelvgaige.Crypto.KeyManager.EnvBackend), do: "env"
  defp backend_name(Twelvgaige.Crypto.KeyManager.FileBackend), do: "file"

  defp backend_name(Twelvgaige.Crypto.KeyManager.LinuxSecretServiceBackend),
    do: "linux_secret_service"

  defp backend_name(Twelvgaige.Crypto.KeyManager.MacOSKeychainBackend), do: "macos_keychain"
  defp backend_name(Twelvgaige.Crypto.KeyManager.WindowsDPAPIBackend), do: "windows_dpapi"
  defp backend_name(Twelvgaige.Crypto.KeyManager.TestBackend), do: "test"
  defp backend_name(backend), do: inspect(backend)

  defp os_protected_backend?(Twelvgaige.Crypto.KeyManager.LinuxSecretServiceBackend), do: true
  defp os_protected_backend?(Twelvgaige.Crypto.KeyManager.MacOSKeychainBackend), do: true
  defp os_protected_backend?(Twelvgaige.Crypto.KeyManager.WindowsDPAPIBackend), do: true
  defp os_protected_backend?(_backend), do: false

  defp key_manager_warnings(Twelvgaige.Crypto.KeyManager.MacOSKeychainBackend, _accepted?) do
    [
      "macOS keychain backend uses the security command wrapper; locked keychains may prompt or fail"
    ]
  end

  defp key_manager_warnings(Twelvgaige.Crypto.KeyManager.LinuxSecretServiceBackend, _accepted?) do
    [
      "Linux Secret Service backend requires secret-tool, a user D-Bus session, and an unlocked collection; it is not universal headless server support"
    ]
  end

  defp key_manager_warnings(Twelvgaige.Crypto.KeyManager.WindowsDPAPIBackend, _accepted?) do
    [
      "Windows DPAPI backend uses a PowerShell command wrapper and user-profile-bound protected files; Windows release verification is pending"
    ]
  end

  defp key_manager_warnings(Twelvgaige.Crypto.KeyManager.EnvBackend, true) do
    ["env key backend is explicit but not OS-protected"]
  end

  defp key_manager_warnings(Twelvgaige.Crypto.KeyManager.FileBackend, true) do
    ["file key backend is explicit but not OS-protected"]
  end

  defp key_manager_warnings(backend, false)
       when backend in [
              Twelvgaige.Crypto.KeyManager.EnvBackend,
              Twelvgaige.Crypto.KeyManager.FileBackend
            ] do
    ["env/file key backends require allow_insecure_key_backend?: true"]
  end

  defp key_manager_warnings(_backend, _insecure_accepted?), do: []

  defp normalize_store_config({module, opts}) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp normalize_store_config(module) when is_atom(module), do: {module, []}

  defp store_backend(Memory), do: "memory"
  defp store_backend(FileStore), do: "file"
  defp store_backend(SQLite), do: "sqlite"
  defp store_backend(SQLiteEncrypted), do: "sqlite_encrypted"
  defp store_backend(module) when is_atom(module), do: inspect(module)

  defp store_encryption("sqlite_encrypted"), do: "sqlcipher"
  defp store_encryption(_backend), do: "none"

  defp store_key_backend("sqlite_encrypted", opts) do
    cond do
      Keyword.has_key?(opts, :key_manager) -> inspect(Keyword.get(opts, :key_manager))
      Keyword.has_key?(opts, :key_env) -> "env"
      Keyword.has_key?(opts, :key) -> "direct"
      true -> nil
    end
  end

  defp store_key_backend(_backend, _opts), do: nil

  defp store_warnings("sqlite_encrypted", _sensitive_retention) do
    [
      "SQLCipher encrypted store fails closed when the linked SQLite driver lacks SQLCipher",
      "encrypted backup and restore commands are still pending"
    ]
  end

  defp store_warnings("memory", _sensitive_retention) do
    [
      "memory store is not durable",
      "local store is not encrypted by Twelvgaige"
    ]
  end

  defp store_warnings(_backend, "summary") do
    ["local store is not encrypted by Twelvgaige; sensitive payloads are summarized"]
  end

  defp store_warnings(_backend, _sensitive_retention) do
    [
      "local store is not encrypted by Twelvgaige",
      "use OS or volume encryption for laptop at-rest protection"
    ]
  end

  defp http_listener_status(config) when config in [false, nil] do
    %{
      "enabled" => false,
      "bind" => nil,
      "tls_mode" => "disabled",
      "native_tls_supported" => false,
      "mtls_supported" => false,
      "mutating_routes_require_bearer" => true,
      "warnings" => []
    }
  end

  defp http_listener_status(opts) when is_list(opts) do
    ip = Keyword.get(opts, :ip, {127, 0, 0, 1})
    loopback? = local_ip?(ip)
    proxy? = Keyword.get(opts, :behind_tls_proxy?, false)
    tls_configured? = Keyword.has_key?(opts, :tls_options)
    bearer? = configured_bearer?(opts)
    trusted_proxy_cidrs = opts |> Keyword.get(:trusted_proxy_cidrs, []) |> List.wrap()

    %{
      "enabled" => true,
      "bind" => format_ip(ip),
      "allow_remote" => Keyword.get(opts, :allow_remote?, false),
      "behind_tls_proxy" => proxy?,
      "trusted_proxy_cidrs_configured" => trusted_proxy_cidrs != [],
      "bearer_configured" => bearer?,
      "tls_mode" => tls_mode(loopback?, proxy?, tls_configured?),
      "native_tls_supported" => false,
      "mtls_supported" => false,
      "mutating_routes_require_bearer" => true,
      "warnings" =>
        http_warnings(loopback?, proxy?, tls_configured?, bearer?, trusted_proxy_cidrs)
    }
  end

  defp http_listener_status(_config) do
    %{
      "enabled" => false,
      "bind" => nil,
      "tls_mode" => "invalid_config",
      "native_tls_supported" => false,
      "mtls_supported" => false,
      "mutating_routes_require_bearer" => true,
      "warnings" => ["http_listener config must be false, nil, or a keyword list"]
    }
  end

  defp configured_bearer?(opts) do
    present?(Keyword.get(opts, :bearer_token)) or present?(Keyword.get(opts, :auth_token))
  end

  defp present?(value), do: is_binary(value) and value != ""

  defp tls_mode(true, _proxy?, _tls_configured?), do: "loopback_http"
  defp tls_mode(false, true, _tls_configured?), do: "trusted_proxy"
  defp tls_mode(false, false, true), do: "native_tls_not_implemented"
  defp tls_mode(false, false, false), do: "raw_remote_http_rejected"

  defp http_warnings(true, _proxy?, true, _bearer?, _trusted_proxy_cidrs) do
    ["native TLS is not implemented; loopback listener still uses HTTP"]
  end

  defp http_warnings(true, _proxy?, _tls_configured?, _bearer?, _trusted_proxy_cidrs), do: []

  defp http_warnings(false, true, _tls_configured?, true, []) do
    [
      "remote trusted-proxy mode requires trusted_proxy_cidrs",
      "trusted-proxy mode relies on the configured proxy for TLS/mTLS termination"
    ]
  end

  defp http_warnings(false, true, _tls_configured?, true, _trusted_proxy_cidrs) do
    ["trusted-proxy mode relies on the configured proxy for TLS/mTLS termination"]
  end

  defp http_warnings(false, true, _tls_configured?, false, _trusted_proxy_cidrs) do
    [
      "remote trusted-proxy mode still requires bearer auth for mutating routes",
      "trusted-proxy mode relies on the configured proxy for TLS/mTLS termination"
    ]
  end

  defp http_warnings(false, false, true, _bearer?, _trusted_proxy_cidrs) do
    ["native TLS is not implemented; non-loopback tls_options are rejected"]
  end

  defp http_warnings(false, false, false, _bearer?, _trusted_proxy_cidrs) do
    ["raw non-loopback HTTP is rejected"]
  end

  defp provider_status do
    %{
      "hosted_tls_verification" => "configured",
      "tls_regression_tests" => "policy_tests_present",
      "hosted_providers" => ["anthropic", "openai", "gemini"],
      "local_providers" => ["ollama"],
      "policy" => %{
        "hosted_https_required" => true,
        "hosted_official_hosts_by_default" => true,
        "auth_headers_suppressed_on_policy_denial" => true,
        "redirects_disabled" => true
      },
      "warnings" => ["provider certificate fixture tests are not complete yet"]
    }
  end

  defp audit_status do
    %{
      "checkpoint_hash_chain" => true,
      "checkpoint_signing" => "optional_hmac_sha256",
      "live_signing" => false,
      "warnings" => [
        "audit checkpoint exports are tamper-evident; optional HMAC signing is export-only",
        "live store is not tamper-proof"
      ]
    }
  end

  defp release_status do
    %{
      "checksums" => true,
      "signed_checksums" => false,
      "attestations" => true,
      "warnings" => [
        "release artifacts use GitHub artifact attestations; project-managed signing keys are not implemented"
      ]
    }
  end

  defp local_ip?({127, _, _, _}), do: true
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp local_ip?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp local_ip?({0, _, _, _}), do: false
  defp local_ip?({_, _, _, _}), do: false
  defp local_ip?({_, _, _, _, _, _, _, _}), do: false
  defp local_ip?(_ip), do: false

  defp format_ip(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
  rescue
    _error -> inspect(ip)
  end
end
