defmodule Twelvgaige.CLI.Commands.StoreFormat do
  @moduledoc false

  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [encode_line: 1, format_warnings: 1, value: 2, value: 3]

  def backup(report, :json), do: encode_line(report)

  def backup(report, :human) do
    warnings = format_warnings(value(report, :warnings, []))

    """
    Store backup complete
    Source: #{value(report, :source)}
    Destination: #{value(report, :destination)}
    Mode: #{value(report, :mode)}
    Encrypted: #{value(report, :encrypted)}
    Plaintext export: #{value(report, :plaintext)}
    Warnings:
    #{warnings}
    """
  end

  def restore(report, :json), do: encode_line(report)

  def restore(report, :human) do
    """
    Store restore complete
    Source: #{value(report, :source)}
    Destination: #{value(report, :destination)}
    Bytes: #{value(report, :bytes)}
    Replaced: #{value(report, :replaced)}
    """
  end

  def migration(report, :json), do: encode_line(report)

  def migration(report, :human) do
    warnings = format_warnings(value(report, :warnings, []))

    """
    Store SQLCipher migration complete
    Source: #{value(report, :source)}
    Destination: #{value(report, :destination)}
    Driver: #{value(report, :driver)}
    Cipher version: #{value(report, :cipher_version)}
    Migration versions: #{inspect(value(report, :migration_versions, []))}
    Open without key rejected: #{value(report, :open_without_key_rejected)}
    Replaced: #{value(report, :replaced)}
    Warnings:
    #{warnings}
    """
  end

  def rewrap(report, :json), do: encode_line(report)

  def rewrap(report, :human) do
    warnings = format_warnings(value(report, :warnings, []))

    """
    Store envelope rewrap complete
    Envelope: #{value(report, :path)}
    Backup: #{value(report, :backup)}
    Key: #{value(report, :key_id)} backend=#{value(report, :key_backend)}
    Previous key: #{value(report, :previous_key_id)} backend=#{value(report, :previous_key_backend)}
    Database rekeyed: #{value(report, :database_rekeyed)}
    Warnings:
    #{warnings}
    """
  end

  def error(error, :json) do
    %{error: %{reason: error_reason(error), message: error_message(error)}}
    |> encode_line()
  end

  def error(error, :human), do: "error: #{error_message(error)}\n"

  def exit_code(:backup_source_not_found), do: 6
  def exit_code(:migration_source_not_found), do: 6
  def exit_code(:plaintext_export_not_allowed), do: 7
  def exit_code(:backup_destination_exists), do: 4
  def exit_code(:restore_destination_exists), do: 4
  def exit_code(:migration_destination_exists), do: 4
  def exit_code(:migration_same_path), do: 4
  def exit_code(:migration_source_invalid), do: 4
  def exit_code(:sqlcipher_key_required), do: 4
  def exit_code(:sqlcipher_unavailable), do: 4
  def exit_code(:envelope_backup_required), do: 4
  def exit_code(:old_key_env_required), do: 4
  def exit_code(:new_key_env_required), do: 4
  def exit_code(:envelope_not_found), do: 6
  def exit_code(:envelope_backup_exists), do: 4
  def exit_code(:invalid_envelope_file), do: 4
  def exit_code(:dek_unwrap_failed), do: 4
  def exit_code({:store_backup_unsupported, _module}), do: 4
  def exit_code({:store_restore_unsupported, _module}), do: 4
  def exit_code(error), do: ExitCode.for_error(error)

  defp error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp error_reason(_reason), do: "store_error"

  defp error_message(:plaintext_export_not_allowed) do
    "plaintext SQLite backups require --allow-plaintext-export"
  end

  defp error_message(:backup_destination_exists), do: "backup destination already exists"
  defp error_message(:backup_source_not_found), do: "backup source does not exist"
  defp error_message(:restore_destination_exists), do: "restore destination already exists"
  defp error_message(:migration_source_not_found), do: "migration source does not exist"
  defp error_message(:migration_destination_exists), do: "migration destination already exists"
  defp error_message(:migration_same_path), do: "migration source and destination must differ"
  defp error_message(:migration_source_invalid), do: "migration source is not a valid store"
  defp error_message(:sqlcipher_key_required), do: "SQLCipher migration requires --key-env"
  defp error_message(:sqlcipher_unavailable), do: "SQLite driver is not built with SQLCipher"
  defp error_message(:envelope_backup_required), do: "envelope rewrap requires --backup"
  defp error_message(:old_key_env_required), do: "envelope rewrap requires --old-key-env"
  defp error_message(:new_key_env_required), do: "envelope rewrap requires --new-key-env"
  defp error_message(:envelope_not_found), do: "envelope file does not exist"
  defp error_message(:envelope_backup_exists), do: "envelope backup already exists"
  defp error_message(:invalid_envelope_file), do: "invalid envelope file"
  defp error_message(:dek_unwrap_failed), do: "failed to unwrap envelope with old key"

  defp error_message({:store_backup_unsupported, module}) do
    "store backend #{inspect(module)} does not support backup"
  end

  defp error_message({:store_restore_unsupported, module}) do
    "store backend #{inspect(module)} does not support restore"
  end

  defp error_message(reason), do: inspect(reason)
end
