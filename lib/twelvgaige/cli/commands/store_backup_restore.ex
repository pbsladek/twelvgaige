defmodule Twelvgaige.CLI.Commands.StoreBackupRestore do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.StoreFormat
  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_format: 1]

  @spec backup(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def backup(destination, args) do
    with {:ok, opts} <- parse_backup_opts(args) do
      case Twelvgaige.store_backup(destination,
             allow_plaintext_export?: opts[:allow_plaintext_export?]
           ) do
        {:ok, report} ->
          {:ok, StoreFormat.backup(report, opts[:format]), 0}

        {:error, error} ->
          {:ok, StoreFormat.error(error, opts[:format]), StoreFormat.exit_code(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec restore(String.t(), String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def restore(source, destination, args) do
    with {:ok, opts} <- parse_restore_opts(args) do
      case Twelvgaige.store_restore_backup(source, destination, replace?: opts[:replace?]) do
        {:ok, report} ->
          {:ok, StoreFormat.restore(report, opts[:format]), 0}

        {:error, error} ->
          {:ok, StoreFormat.error(error, opts[:format]), StoreFormat.exit_code(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_backup_opts(args),
    do: parse_backup_opts(args, format: :human, allow_plaintext_export?: false)

  defp parse_backup_opts([], opts), do: {:ok, opts}

  defp parse_backup_opts(["--allow-plaintext-export" | rest], opts) do
    parse_backup_opts(rest, Keyword.put(opts, :allow_plaintext_export?, true))
  end

  defp parse_backup_opts(["--format", format | rest], opts) do
    parse_backup_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_backup_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_restore_opts(args), do: parse_restore_opts(args, format: :human, replace?: false)
  defp parse_restore_opts([], opts), do: {:ok, opts}

  defp parse_restore_opts(["--replace" | rest], opts) do
    parse_restore_opts(rest, Keyword.put(opts, :replace?, true))
  end

  defp parse_restore_opts(["--format", format | rest], opts) do
    parse_restore_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_restore_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end
end
