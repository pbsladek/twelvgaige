defmodule Twelvgaige.Workspace.DirectApply do
  @moduledoc "Explicit, journaled application to the developer's current worktree."

  import Bitwise

  alias Twelvgaige.Lifecycle.FaultMatrix
  alias Twelvgaige.Workspace.Git.ManagedWorkspace
  alias Twelvgaige.Workspace.Git.SourceRead
  alias Twelvgaige.Workspace.{Canonical, RepositoryInspection}

  def backup_path(root, request_id) do
    suffix =
      :crypto.hash(:sha256, request_id) |> Base.url_encode64(padding: false) |> binary_part(0, 20)

    Path.join(root, "backup-#{suffix}")
  end

  def check(workspace, result, opts \\ []) do
    repository = workspace.repository
    manifest = result.manifest
    base = field(manifest, :source_base_commit)

    with true <- File.dir?(repository),
         {:ok, head} <- SourceRead.resolve_commit(repository, "HEAD", opts),
         true <- head == base,
         {:ok, status} <- SourceRead.status(repository, opts),
         true <- status == "",
         :ok <- SourceRead.check_patch(repository, result.patch, opts) do
      {:ok,
       %{
         workspace_id: workspace.id,
         repository: repository,
         base_commit: base,
         result_tree: field(manifest, :result_tree),
         patch_digest: field(manifest, :patch_digest),
         target: "current-worktree",
         dry_run: true,
         applicable: true,
         expected_epoch: workspace.control_epoch
       }}
    else
      false -> {:error, :workspace_apply_target_drifted_or_dirty}
      {:error, _reason} = error -> error
    end
  end

  def apply(workspace, result, backup_root, opts \\ []) do
    with {:ok, report} <- check(workspace, result, opts),
         {:ok, authority} <- mutation_authority(workspace, opts),
         {:ok, backup} <-
           FaultMatrix.around(
             opts,
             :direct_apply,
             :backup_publish,
             lifecycle_metadata(workspace, opts),
             fn -> backup(workspace, result.manifest, backup_root, opts) end
           ),
         :ok <-
           FaultMatrix.around(
             opts,
             :direct_apply,
             :current_worktree_patch_apply,
             lifecycle_metadata(workspace, opts),
             fn -> ManagedWorkspace.apply_patch(authority, result.patch, opts) end
           ),
         {:ok, capture} <-
           FaultMatrix.around(
             opts,
             :direct_apply,
             :current_worktree_result_verify,
             lifecycle_metadata(workspace, opts),
             fn ->
               ManagedWorkspace.capture_result(
                 authority,
                 report.base_commit,
                 Keyword.put(opts, :artifact_base, report.base_commit)
               )
             end
           ),
         true <- capture.result_tree == report.result_tree do
      {:ok,
       report
       |> Map.merge(%{
         dry_run: false,
         path: workspace.repository,
         backup_path: backup.path,
         backup_expires_at: backup.expires_at,
         verified_result_tree: capture.result_tree
       })}
    else
      false -> {:error, :workspace_apply_result_tree_mismatch}
      {:error, _reason} = error -> error
    end
  end

  def recovery_evidence(workspace, backup_root, request_id, opts \\ []) do
    backup_path = backup_path(backup_root, request_id)

    with true <- File.dir?(backup_path),
         true <- File.regular?(Path.join(backup_path, "backup.json")),
         {:ok, inspection} <- RepositoryInspection.inspect(workspace.repository, opts) do
      {:ok,
       %{
         backup_path: backup_path,
         source_state_token: inspection.source_state_token,
         base_commit: inspection.base_commit,
         repository: workspace.repository
       }}
    else
      false -> {:error, :workspace_apply_backup_missing}
      {:error, _reason} = error -> error
    end
  end

  def restore(workspace, backup_path, expected_source_token, opts \\ []) do
    with {:ok, inspection} <- RepositoryInspection.inspect(workspace.repository, opts),
         true <- inspection.source_state_token == expected_source_token,
         {:ok, encoded} <- File.read(Path.join(backup_path, "backup.json")),
         {:ok, manifest} <- Jason.decode(encoded),
         :ok <- validate_backup_manifest(manifest, workspace),
         :ok <- validate_restore_entries(manifest, backup_path),
         :ok <- validate_restore_index(manifest["index"], backup_path),
         :ok <- restore_entries(workspace.repository, manifest["entries"], backup_path),
         :ok <- restore_index(workspace.repository, manifest["index"], backup_path, opts),
         {:ok, head} <- SourceRead.resolve_commit(workspace.repository, "HEAD", opts),
         true <- head == manifest["base_commit"],
         {:ok, ""} <- SourceRead.status(workspace.repository, opts) do
      {:ok,
       %{
         workspace_id: workspace.id,
         repository: workspace.repository,
         backup_path: backup_path,
         restored_base_commit: head,
         status: :restored
       }}
    else
      false -> {:error, :workspace_recovery_source_drifted}
      {:ok, _dirty} -> {:error, :workspace_recovery_not_clean}
      {:error, _reason} = error -> error
    end
  end

  defp backup(workspace, manifest, root, opts) do
    request_id = Keyword.fetch!(opts, :request_id)
    path = backup_path(root, request_id)
    files_path = Path.join(path, "files")
    created_at = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
    expires_at = DateTime.add(created_at, Keyword.get(opts, :backup_retention_days, 7), :day)

    with false <- File.exists?(path),
         :ok <- File.mkdir_p(files_path),
         :ok <- File.chmod(path, 0o700),
         :ok <- File.chmod(files_path, 0o700),
         {:ok, entries} <- backup_paths(workspace.repository, changed_paths(manifest), files_path),
         {:ok, index_path} <- SourceRead.index_path(workspace.repository, opts),
         {:ok, index_entry} <- backup_index(index_path, path),
         backup_manifest <- %{
           "schema_version" => 1,
           "workspace_id" => workspace.id,
           "repository" => Canonical.path(workspace.repository),
           "base_commit" => field(manifest, :source_base_commit),
           "result_tree" => field(manifest, :result_tree),
           "patch_digest" => field(manifest, :patch_digest),
           "created_at" => DateTime.to_iso8601(created_at),
           "expires_at" => DateTime.to_iso8601(expires_at),
           "entries" => entries,
           "index" => index_entry
         },
         {:ok, encoded} <- Jason.encode(backup_manifest, pretty: true),
         :ok <- File.write(Path.join(path, "backup.json"), [encoded, "\n"], [:binary, :exclusive]),
         :ok <- File.chmod(Path.join(path, "backup.json"), 0o600) do
      {:ok, %{path: path, expires_at: expires_at}}
    else
      true ->
        {:error, :workspace_apply_backup_exists}

      {:error, reason} ->
        _ = File.rm_rf(path)
        {:error, {:workspace_apply_backup_failed, reason}}
    end
  end

  defp changed_paths(manifest) do
    manifest
    |> field(:changed_paths, [])
    |> Enum.flat_map(fn change ->
      [field(change, :path), field(change, :old_path), field(change, :new_path)]
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp backup_paths(repository, encoded_paths, destination) do
    encoded_paths
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {encoded, index}, {:ok, entries} ->
      with {:ok, relative} <- Canonical.decode_path(encoded),
           :ok <- safe_relative(relative),
           {:ok, entry} <- backup_entry(repository, relative, destination, index) do
        {:cont, {:ok, [entry | entries]}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp backup_entry(repository, relative, destination, index) do
    source = Path.join(repository, relative)
    name = Integer.to_string(index)
    target = Path.join(destination, name)

    case File.lstat(source) do
      {:ok, %{type: :regular, mode: mode}} ->
        with :ok <- File.cp(source, target),
             :ok <- File.chmod(target, 0o600) do
          {:ok,
           %{
             "path" => Canonical.path(relative),
             "state" => "file",
             "backup" => name,
             "mode" => mode,
             "digest" => file_digest(target)
           }}
        end

      {:ok, %{type: :symlink}} ->
        with {:ok, link} <- File.read_link(source) do
          {:ok,
           %{
             "path" => Canonical.path(relative),
             "state" => "symlink",
             "target" => Canonical.path(link)
           }}
        end

      {:error, :enoent} ->
        {:ok, %{"path" => Canonical.path(relative), "state" => "missing"}}

      {:ok, %{type: type}} ->
        {:error, {:workspace_apply_backup_type_unsupported, relative, type}}

      {:error, reason} ->
        {:error, {:workspace_apply_backup_read_failed, relative, reason}}
    end
  end

  defp backup_index(index_path, destination) do
    target = Path.join(destination, "index")

    case File.read(index_path) do
      {:ok, bytes} ->
        with :ok <- File.write(target, bytes, [:binary, :exclusive]),
             :ok <- File.chmod(target, 0o600) do
          {:ok,
           %{
             "state" => "file",
             "bytes" => byte_size(bytes),
             "digest" => bytes_digest(bytes)
           }}
        end

      {:error, :enoent} ->
        {:ok, %{"state" => "missing"}}

      {:error, reason} ->
        {:error, {:workspace_apply_index_backup_failed, reason}}
    end
  end

  defp safe_relative(path) do
    normalized = Path.split(path)

    cond do
      path == "" -> {:error, :workspace_apply_path_invalid}
      Path.type(path) != :relative -> {:error, :workspace_apply_path_invalid}
      Enum.any?(normalized, &(&1 in ["..", ".", ""])) -> {:error, :workspace_apply_path_invalid}
      true -> :ok
    end
  end

  defp validate_backup_manifest(manifest, workspace) do
    workspace_id = workspace.id

    with 1 <- manifest["schema_version"],
         ^workspace_id <- manifest["workspace_id"],
         {:ok, repository} <- Canonical.decode_path(manifest["repository"]),
         true <- Path.expand(repository) == workspace.repository,
         entries when is_list(entries) <- manifest["entries"],
         index when is_map(index) <- manifest["index"] do
      :ok
    else
      _invalid -> {:error, :workspace_recovery_backup_invalid}
    end
  end

  defp validate_restore_entries(manifest, backup_path) do
    Enum.reduce_while(manifest["entries"], :ok, fn entry, :ok ->
      with {:ok, relative} <- Canonical.decode_path(entry["path"]),
           :ok <- safe_relative(relative),
           :ok <- validate_backup_entry(entry, backup_path) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_backup_entry(
         %{"state" => "file", "backup" => name, "mode" => mode, "digest" => digest},
         backup_path
       )
       when is_binary(name) and is_integer(mode) and is_binary(digest) do
    path = Path.join([backup_path, "files", name])

    cond do
      not File.regular?(path) -> {:error, :workspace_recovery_backup_file_missing}
      file_digest(path) != digest -> {:error, :workspace_recovery_backup_digest_mismatch}
      true -> :ok
    end
  end

  defp validate_backup_entry(%{"state" => "symlink", "target" => target}, _backup_path) do
    case Canonical.decode_path(target) do
      {:ok, _link} -> :ok
      {:error, _reason} -> {:error, :workspace_recovery_backup_invalid}
    end
  end

  defp validate_backup_entry(%{"state" => "missing"}, _backup_path), do: :ok

  defp validate_backup_entry(_entry, _backup_path),
    do: {:error, :workspace_recovery_backup_invalid}

  defp validate_restore_index(
         %{"state" => "file", "bytes" => bytes, "digest" => digest},
         backup_path
       )
       when is_integer(bytes) and bytes >= 0 and is_binary(digest) do
    path = Path.join(backup_path, "index")

    case File.read(path) do
      {:ok, contents} when byte_size(contents) == bytes ->
        if bytes_digest(contents) == digest,
          do: :ok,
          else: {:error, :workspace_recovery_backup_digest_mismatch}

      {:ok, _contents} ->
        {:error, :workspace_recovery_backup_size_mismatch}

      {:error, :enoent} ->
        {:error, :workspace_recovery_backup_file_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_restore_index(%{"state" => "missing"}, _backup_path), do: :ok

  defp validate_restore_index(_index, _backup_path),
    do: {:error, :workspace_recovery_backup_invalid}

  defp restore_entries(repository, entries, backup_path) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      {:ok, relative} = Canonical.decode_path(entry["path"])
      target = Path.join(repository, relative)

      case restore_entry(target, entry, backup_path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp restore_entry(target, %{"state" => "file", "backup" => name} = entry, backup_path) do
    with :ok <- replaceable_target(target),
         :ok <- remove_optional(target),
         :ok <- File.mkdir_p(Path.dirname(target)),
         :ok <- File.cp(Path.join([backup_path, "files", name]), target),
         :ok <- File.chmod(target, entry["mode"] &&& 0o777) do
      :ok
    end
  end

  defp restore_entry(target, %{"state" => "symlink", "target" => encoded}, _backup_path) do
    with :ok <- replaceable_target(target),
         :ok <- remove_optional(target),
         :ok <- File.mkdir_p(Path.dirname(target)),
         {:ok, link} <- Canonical.decode_path(encoded),
         :ok <- File.ln_s(link, target) do
      :ok
    end
  end

  defp restore_entry(target, %{"state" => "missing"}, _backup_path) do
    with :ok <- replaceable_target(target), do: remove_optional(target)
  end

  defp restore_index(repository, %{"state" => "file"}, backup_path, opts) do
    with {:ok, index_path} <- SourceRead.index_path(repository, opts),
         :ok <- File.cp(Path.join(backup_path, "index"), index_path) do
      :ok
    end
  end

  defp restore_index(repository, %{"state" => "missing"}, _backup_path, opts) do
    with {:ok, index_path} <- SourceRead.index_path(repository, opts),
         do: remove_optional(index_path)
  end

  defp replaceable_target(path) do
    case File.lstat(path) do
      {:ok, %{type: type}} when type in [:regular, :symlink] -> :ok
      {:error, :enoent} -> :ok
      {:ok, %{type: type}} -> {:error, {:workspace_recovery_target_type_invalid, path, type}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp remove_optional(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_digest(path) do
    path
    |> File.stream!(64 * 1024, [])
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp bytes_digest(bytes) do
    :sha256
    |> :crypto.hash(bytes)
    |> Base.encode16(case: :lower)
  end

  defp mutation_authority(workspace, opts) do
    ManagedWorkspace.authorize(workspace,
      root: workspace.repository,
      expected_epoch: Keyword.get(opts, :expected_epoch),
      lease: Keyword.get(opts, :request_id),
      operation_id: Keyword.get(opts, :operation_id),
      request_id: Keyword.get(opts, :request_id),
      audit_fun: Keyword.get(opts, :git_audit_fun),
      scope: :direct_apply
    )
  end

  defp lifecycle_metadata(workspace, opts) do
    %{
      operation_id: Keyword.get(opts, :operation_id),
      request_id: Keyword.get(opts, :request_id),
      workspace_id: workspace.id
    }
  end

  defp field(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
