defmodule Twelvgaige.CLI.Commands.Crypto do
  @moduledoc false

  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [
      encode_line: 1,
      format_command_error: 2,
      format_warnings: 1,
      parse_format: 1,
      value: 2,
      value: 3
    ]

  @spec status(keyword()) :: {:ok, String.t(), non_neg_integer()}
  def status(opts) do
    format = Keyword.fetch!(opts, :format)
    {:ok, format_status(Twelvgaige.crypto_status(), format), 0}
  end

  @spec sqlcipher_spike([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def sqlcipher_spike(args) do
    with {:ok, opts} <- parse_sqlcipher_spike_opts(args) do
      case Twelvgaige.sqlcipher_spike(sqlcipher_spike_opts(opts)) do
        {:ok, report} ->
          {:ok, format_sqlcipher_spike(report, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_sqlcipher_spike_error(error, opts[:format]), 4}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_sqlcipher_spike_opts(args),
    do: parse_sqlcipher_spike_opts(args, format: :human, path: nil, key_env: nil)

  defp parse_sqlcipher_spike_opts([], opts), do: {:ok, opts}

  defp parse_sqlcipher_spike_opts(["--format", format | rest], opts) do
    parse_sqlcipher_spike_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_sqlcipher_spike_opts(["--path", path | rest], opts) do
    parse_sqlcipher_spike_opts(rest, Keyword.put(opts, :path, path))
  end

  defp parse_sqlcipher_spike_opts(["--key-env", env | rest], opts) do
    parse_sqlcipher_spike_opts(rest, Keyword.put(opts, :key_env, env))
  end

  defp parse_sqlcipher_spike_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp sqlcipher_spike_opts(opts) do
    []
    |> maybe_put(:path, opts[:path])
    |> maybe_put(:key_env, opts[:key_env])
  end

  defp format_status(status, :json), do: encode_line(status)

  defp format_status(status, :human) do
    store = value(status, :store, %{})
    key_manager = value(status, :key_manager, %{})
    http = value(status, :http_listener, %{})
    providers = value(status, :providers, %{})
    audit = value(status, :audit, %{})
    release = value(status, :release, %{})

    warnings =
      [store, key_manager, http, providers, audit, release]
      |> Enum.flat_map(&List.wrap(value(&1, :warnings, [])))
      |> format_warnings()

    """
    Crypto posture: #{value(status, :status)}
    Store: #{value(store, :backend)} encryption=#{value(store, :encryption)} encrypted=#{value(store, :encrypted)}
    Key manager: #{if(value(key_manager, :enabled), do: value(key_manager, :backend), else: "disabled")}
    HTTP listener: #{if(value(http, :enabled), do: value(http, :tls_mode), else: "disabled")}
    Native TLS: #{value(http, :native_tls_supported)}
    mTLS: #{value(http, :mtls_supported)}
    Provider TLS: #{value(providers, :hosted_tls_verification)} tests=#{value(providers, :tls_regression_tests)}
    Audit checkpoint hash chain: #{value(audit, :checkpoint_hash_chain)}
    Audit signing: #{value(audit, :checkpoint_signing)}
    Release checksums: #{value(release, :checksums)}
    Release signatures: #{value(release, :signed_checksums)}
    Release attestations: #{value(release, :attestations)}
    Warnings:
    #{warnings}
    """
  end

  defp format_sqlcipher_spike(report, :json), do: encode_line(report)

  defp format_sqlcipher_spike(report, :human) do
    warnings =
      report
      |> value(:warnings, [])
      |> format_warnings()

    """
    SQLCipher spike: #{value(report, :status)}
    Driver: #{value(report, :driver)}
    Path: #{value(report, :path)}
    Available: #{value(report, :available)}
    Cipher version: #{value(report, :cipher_version) || "none"}
    Migrations: #{value(report, :migrations)}
    Reopen with key: #{value(report, :reopen_with_key)}
    Open without key rejected: #{value(report, :open_without_key_rejected)}
    Warnings:
    #{warnings}
    """
  end

  defp format_sqlcipher_spike_error(error, :json) do
    %{
      error: %{
        reason: sqlcipher_spike_error_reason(error),
        message: sqlcipher_spike_error_message(error)
      }
    }
    |> encode_line()
  end

  defp format_sqlcipher_spike_error(error, :human) do
    "error: #{sqlcipher_spike_error_message(error)}\n"
  end

  defp sqlcipher_spike_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sqlcipher_spike_error_reason(_reason), do: "sqlcipher_spike_failed"

  defp sqlcipher_spike_error_message(:sqlcipher_key_required) do
    "SQLCipher is available, but a key is required; set TWELVGAIGE_SQLCIPHER_SPIKE_KEY or pass --key-env"
  end

  defp sqlcipher_spike_error_message(reason), do: inspect(reason)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
