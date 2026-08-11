defmodule Twelvgaige.Workspace.RuntimeImport do
  @moduledoc "Durably validates and swaps a stopped sandbox result into its managed workspace."

  alias Twelvgaige.Workspace.Transport

  @journal_version 1

  def replace(staging, destination, opts) do
    staging = Path.expand(staging)
    destination = Path.expand(destination)
    backup = backup_path(destination)
    journal = journal_path(destination)

    with :ok <- allowed_destination(destination, opts),
         :ok <- staging_is_sibling(staging, destination),
         :ok <- recover(destination, Keyword.put(opts, :preserve_staging, staging)),
         :ok <- no_untracked_backup(backup),
         {:ok, measurements} <-
           Transport.validate_runtime_tree(staging,
             max_bytes: Keyword.get(opts, :max_export_bytes)
           ),
         record <- journal_record(staging, destination, backup, measurements, "prepared"),
         :ok <- persist_journal(journal, record),
         :ok <- fault(opts, :intent_persisted),
         :ok <- move_original(destination, backup),
         :ok <- fault(opts, :original_moved),
         :ok <- persist_journal(journal, %{record | "phase" => "original_moved"}),
         :ok <- install_staging(staging, destination, backup, journal),
         :ok <- fault(opts, :staging_installed),
         :ok <- persist_journal(journal, %{record | "phase" => "staging_installed"}),
         :ok <- remove_backup(backup),
         :ok <- fault(opts, :backup_removed),
         :ok <- persist_journal(journal, %{record | "phase" => "backup_removed"}),
         :ok <- remove_journal(journal),
         :ok <- fault(opts, :journal_removed) do
      {:ok,
       Map.merge(measurements, %{
         destination: destination,
         source_repository_replaced: false,
         managed_snapshot_replaced: true
       })}
    end
  end

  @doc "Reconciles an interrupted import using its exact write-ahead journal and filesystem state."
  def recover(destination, opts) do
    destination = Path.expand(destination)
    journal = journal_path(destination)
    backup = backup_path(destination)

    with :ok <- allowed_destination(destination, opts) do
      case File.lstat(journal) do
        {:error, :enoent} -> no_untracked_backup(backup)
        {:ok, %{type: :regular}} -> recover_journal(journal, destination, opts)
        {:ok, _other} -> {:error, :runtime_workspace_journal_invalid}
        {:error, reason} -> {:error, {:runtime_workspace_journal_stat_failed, reason}}
      end
    end
  end

  defp recover_journal(journal, destination, opts) do
    with {:ok, encoded} <- File.read(journal),
         {:ok, record} <- Jason.decode(encoded),
         :ok <- validate_journal(record, destination),
         states <- journal_states(record),
         :ok <- reconcile_states(states, record, journal, opts) do
      :ok
    else
      {:error, %Jason.DecodeError{}} -> {:error, :runtime_workspace_journal_corrupt}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_states(
         %{destination: :directory, backup: :missing, staging: :directory},
         record,
         journal,
         opts
       ) do
    with :ok <- maybe_remove_staging(record["staging"], opts),
         :ok <- remove_journal(journal) do
      :ok
    end
  end

  defp reconcile_states(
         %{destination: :directory, backup: :missing, staging: :missing},
         _record,
         journal,
         _opts
       ),
       do: remove_journal(journal)

  defp reconcile_states(%{destination: :missing, backup: :directory}, record, journal, opts) do
    with :ok <-
           rename_exact(
             record["backup"],
             record["destination"],
             :runtime_workspace_restore_failed
           ),
         :ok <- maybe_remove_staging(record["staging"], opts),
         :ok <- remove_journal(journal) do
      :ok
    end
  end

  defp reconcile_states(
         %{destination: :directory, backup: :directory, staging: :missing},
         record,
         journal,
         opts
       ) do
    with {:ok, _measurements} <-
           Transport.validate_runtime_tree(record["destination"],
             max_bytes: Keyword.get(opts, :max_export_bytes)
           ),
         :ok <- remove_backup(record["backup"]),
         :ok <- remove_journal(journal) do
      :ok
    end
  end

  defp reconcile_states(_states, _record, _journal, _opts),
    do: {:error, :runtime_workspace_reconciliation_required}

  defp journal_states(record) do
    %{
      destination: path_state(record["destination"]),
      backup: path_state(record["backup"]),
      staging: path_state(record["staging"])
    }
  end

  defp path_state(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} -> :directory
      {:error, :enoent} -> :missing
      {:ok, _other} -> :invalid
      {:error, _reason} -> :invalid
    end
  end

  defp journal_record(staging, destination, backup, measurements, phase) do
    %{
      "schema_version" => @journal_version,
      "phase" => phase,
      "staging" => staging,
      "destination" => destination,
      "backup" => backup,
      "entries" => Map.get(measurements, :entries),
      "bytes" => Map.get(measurements, :bytes)
    }
  end

  defp validate_journal(
         %{
           "schema_version" => @journal_version,
           "phase" => phase,
           "staging" => staging,
           "destination" => destination,
           "backup" => backup
         },
         destination
       )
       when phase in ["prepared", "original_moved", "staging_installed", "backup_removed"] and
              is_binary(staging) do
    cond do
      backup != backup_path(destination) ->
        {:error, :runtime_workspace_journal_identity_mismatch}

      Path.dirname(staging) != Path.dirname(destination) ->
        {:error, :runtime_workspace_journal_identity_mismatch}

      staging == destination or staging == backup ->
        {:error, :runtime_workspace_journal_identity_mismatch}

      true ->
        :ok
    end
  end

  defp validate_journal(_record, _destination), do: {:error, :runtime_workspace_journal_invalid}

  defp allowed_destination(destination, opts) do
    roots = Keyword.fetch!(opts, :allowed_export_roots) |> Enum.map(&Path.expand/1)

    if Enum.any?(roots, &(destination == &1 or String.starts_with?(destination, &1 <> "/"))),
      do: :ok,
      else: {:error, :runtime_workspace_destination_denied}
  end

  defp staging_is_sibling(staging, destination) do
    if Path.dirname(staging) == Path.dirname(destination) and staging != destination and
         staging != backup_path(destination) and staging != journal_path(destination),
       do: :ok,
       else: {:error, :runtime_workspace_staging_invalid}
  end

  defp no_untracked_backup(backup) do
    case File.lstat(backup) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :runtime_workspace_untracked_backup}
      {:error, reason} -> {:error, {:runtime_workspace_backup_stat_failed, reason}}
    end
  end

  defp move_original(destination, backup) do
    rename_exact(destination, backup, :runtime_workspace_backup_failed)
  end

  defp install_staging(staging, destination, backup, journal) do
    case File.rename(staging, destination) do
      :ok ->
        :ok

      {:error, reason} ->
        restore = File.rename(backup, destination)
        if restore == :ok, do: remove_journal(journal)
        {:error, {:runtime_workspace_install_failed, reason, restore}}
    end
  end

  defp rename_exact(source, destination, error_name) do
    case File.rename(source, destination) do
      :ok -> :ok
      {:error, reason} -> {:error, {error_name, reason}}
    end
  end

  defp remove_backup(backup) do
    case File.rm_rf(backup) do
      {:ok, _removed} -> :ok
      {:error, reason, path} -> {:error, {:runtime_workspace_backup_cleanup_failed, path, reason}}
    end
  end

  defp maybe_remove_staging(staging, opts) do
    if Keyword.get(opts, :preserve_staging) == staging do
      :ok
    else
      case File.lstat(staging) do
        {:ok, %{type: :directory}} ->
          case File.rm_rf(staging) do
            {:ok, _removed} ->
              :ok

            {:error, reason, path} ->
              {:error, {:runtime_workspace_staging_cleanup_failed, path, reason}}
          end

        {:error, :enoent} ->
          :ok

        {:ok, _other} ->
          {:error, :runtime_workspace_staging_cleanup_target_invalid}

        {:error, reason} ->
          {:error, {:runtime_workspace_staging_cleanup_stat_failed, reason}}
      end
    end
  end

  defp persist_journal(path, record) do
    temporary = path <> ".tmp-" <> random_id()

    result =
      with {:ok, encoded} <- Jason.encode(record),
           {:ok, device} <- File.open(temporary, [:write, :binary, :exclusive]),
           :ok <- write_and_sync(device, encoded),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, reason} -> {:error, {:runtime_workspace_journal_persist_failed, reason}}
      end

    if result != :ok, do: File.rm(temporary)
    result
  end

  defp write_and_sync(device, encoded) do
    try do
      with :ok <- IO.binwrite(device, encoded), :ok <- :file.sync(device) do
        :ok
      end
    after
      File.close(device)
    end
  end

  defp remove_journal(journal) do
    case File.rm(journal) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:runtime_workspace_journal_cleanup_failed, reason}}
    end
  end

  defp fault(opts, stage) do
    case Keyword.get(opts, :fault_fun) do
      fun when is_function(fun, 1) ->
        case fun.(stage) do
          :ok -> :ok
          {:error, reason} -> {:error, {:runtime_workspace_fault, stage, reason}}
          _other -> {:error, {:runtime_workspace_fault_invalid, stage}}
        end

      nil ->
        :ok
    end
  end

  defp backup_path(destination), do: destination <> ".runtime-backup"
  defp journal_path(destination), do: destination <> ".runtime-import.json"

  defp random_id,
    do: :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
end
