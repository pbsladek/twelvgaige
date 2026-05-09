defmodule Twelvgaige.CLI.Commands.StoreSecurity do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.StoreFormat
  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_format: 1]

  @spec migrate_sqlcipher([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def migrate_sqlcipher(args) do
    with {:ok, opts} <- parse_migrate_sqlcipher_opts(args) do
      case Twelvgaige.store_migrate_plaintext_to_encrypted(opts[:source], opts[:destination],
             key_env: opts[:key_env],
             replace?: opts[:replace?]
           ) do
        {:ok, report} ->
          {:ok, StoreFormat.migration(report, opts[:format]), 0}

        {:error, error} ->
          {:ok, StoreFormat.error(error, opts[:format]), StoreFormat.exit_code(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec rewrap_envelope(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def rewrap_envelope(path, args) do
    with {:ok, opts} <- parse_rewrap_envelope_opts(args) do
      case Twelvgaige.store_rewrap_envelope(path,
             backup: opts[:backup],
             old_key_env: opts[:old_key_env],
             new_key_env: opts[:new_key_env]
           ) do
        {:ok, report} ->
          {:ok, StoreFormat.rewrap(report, opts[:format]), 0}

        {:error, error} ->
          {:ok, StoreFormat.error(error, opts[:format]), StoreFormat.exit_code(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_migrate_sqlcipher_opts(args),
    do:
      parse_migrate_sqlcipher_opts(args,
        format: :human,
        source: nil,
        destination: nil,
        key_env: nil,
        replace?: false
      )

  defp parse_migrate_sqlcipher_opts([], opts) do
    cond do
      is_nil(opts[:source]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--source is required")}

      is_nil(opts[:destination]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--destination is required")}

      is_nil(opts[:key_env]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--key-env is required")}

      true ->
        {:ok, opts}
    end
  end

  defp parse_migrate_sqlcipher_opts(["--source", source | rest], opts) do
    parse_migrate_sqlcipher_opts(rest, Keyword.put(opts, :source, source))
  end

  defp parse_migrate_sqlcipher_opts(["--destination", destination | rest], opts) do
    parse_migrate_sqlcipher_opts(rest, Keyword.put(opts, :destination, destination))
  end

  defp parse_migrate_sqlcipher_opts(["--key-env", key_env | rest], opts) do
    parse_migrate_sqlcipher_opts(rest, Keyword.put(opts, :key_env, key_env))
  end

  defp parse_migrate_sqlcipher_opts(["--replace" | rest], opts) do
    parse_migrate_sqlcipher_opts(rest, Keyword.put(opts, :replace?, true))
  end

  defp parse_migrate_sqlcipher_opts(["--format", format | rest], opts) do
    parse_migrate_sqlcipher_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_migrate_sqlcipher_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_rewrap_envelope_opts(args),
    do:
      parse_rewrap_envelope_opts(args,
        format: :human,
        backup: nil,
        old_key_env: nil,
        new_key_env: nil
      )

  defp parse_rewrap_envelope_opts([], opts) do
    cond do
      is_nil(opts[:backup]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--backup is required")}

      is_nil(opts[:old_key_env]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--old-key-env is required")}

      is_nil(opts[:new_key_env]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--new-key-env is required")}

      true ->
        {:ok, opts}
    end
  end

  defp parse_rewrap_envelope_opts(["--backup", backup | rest], opts) do
    parse_rewrap_envelope_opts(rest, Keyword.put(opts, :backup, backup))
  end

  defp parse_rewrap_envelope_opts(["--old-key-env", env | rest], opts) do
    parse_rewrap_envelope_opts(rest, Keyword.put(opts, :old_key_env, env))
  end

  defp parse_rewrap_envelope_opts(["--new-key-env", env | rest], opts) do
    parse_rewrap_envelope_opts(rest, Keyword.put(opts, :new_key_env, env))
  end

  defp parse_rewrap_envelope_opts(["--format", format | rest], opts) do
    parse_rewrap_envelope_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_rewrap_envelope_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end
end
