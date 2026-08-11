defmodule Twelvgaige.Workspace.SourceCapture do
  @moduledoc "Creates a stable private workspace from committed, staged, or working-tree source."

  import Bitwise

  alias Twelvgaige.Workspace.Git.ManagedWorkspace
  alias Twelvgaige.Workspace.Git.SourceRead
  alias Twelvgaige.Workspace.{RepositoryInspection, SourceManifest}

  @modes [:committed, :staged, :working_tree]
  @default_max_overlay_files 10_000
  @default_max_overlay_file_bytes 100 * 1_024 * 1_024
  @default_max_overlay_bytes 512 * 1_024 * 1_024

  @spec capture(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def capture(repository, destination, opts \\ []) do
    attempts = Keyword.get(opts, :source_capture_attempts, 2)

    destination = Path.expand(destination)

    with :ok <- ensure_destination_absent(destination) do
      do_capture(Path.expand(repository), destination, opts, attempts)
    end
  end

  defp do_capture(_repository, _destination, _opts, 0),
    do: {:error, :source_changed}

  defp do_capture(repository, destination, opts, attempts) do
    result =
      with {:ok, mode} <- source_mode(Keyword.get(opts, :source_mode, :committed)),
           :ok <- include_policy(opts),
           {:ok, before} <- RepositoryInspection.inspect(repository, opts),
           :ok <- expected_source(before, opts),
           :ok <- admit(before, mode),
           :ok <- SourceRead.copy_snapshot(repository, destination, before.base_commit, opts),
           {:ok, authority} <- managed_authority(destination, opts),
           :ok <- apply_source_mode(before, mode, authority, opts),
           {:ok, input} <-
             ManagedWorkspace.capture_result(authority, before.base_commit,
               artifact_base: before.base_commit,
               persist_objects?: true,
               allowed_paths: [],
               max_result_files:
                 Keyword.get(opts, :max_overlay_files, @default_max_overlay_files),
               max_result_file_bytes:
                 Keyword.get(opts, :max_overlay_file_bytes, @default_max_overlay_file_bytes),
               max_result_bytes: Keyword.get(opts, :max_overlay_bytes, @default_max_overlay_bytes)
             ),
           {:ok, workspace_baseline} <-
             ManagedWorkspace.create_input_baseline(
               authority,
               before.base_commit,
               input.result_tree,
               before.source_state_token,
               opts
             ),
           :ok <- source_capture_hook(opts, before, destination),
           {:ok, after_inspection} <- RepositoryInspection.inspect(repository, opts),
           :ok <- unchanged(before, after_inspection),
           {:ok, base_tree} <-
             ManagedWorkspace.resolve_tree(authority, before.base_commit, opts),
           {:ok, manifest} <-
             SourceManifest.new(%{
               repository_identity: before.logical_identity,
               base_commit: before.base_commit,
               base_tree: base_tree,
               source_mode: mode,
               input_tree: input.result_tree,
               workspace_baseline_commit: workspace_baseline,
               overlay_entries: input.changed_paths,
               source_state_token: before.source_state_token,
               include_untracked: Keyword.get(opts, :include_untracked, false),
               include_ignored: Keyword.get(opts, :include_ignored, false),
               limits: %{
                 files: Keyword.get(opts, :max_overlay_files, @default_max_overlay_files),
                 file_bytes:
                   Keyword.get(opts, :max_overlay_file_bytes, @default_max_overlay_file_bytes),
                 total_bytes: Keyword.get(opts, :max_overlay_bytes, @default_max_overlay_bytes)
               }
             }) do
        {:ok,
         %{
           inspection: before,
           manifest: manifest,
           workspace_baseline_commit: workspace_baseline
         }}
      end

    case result do
      {:error, :source_changed} when attempts > 1 ->
        with :ok <- cleanup_capture_destination(destination) do
          do_capture(repository, destination, opts, attempts - 1)
        end

      {:error, _reason} = error ->
        case cleanup_capture_destination(destination) do
          :ok -> error
          {:error, cleanup_reason} -> {:error, {:source_capture_cleanup_failed, cleanup_reason}}
        end

      {:ok, _capture} = success ->
        success
    end
  end

  defp ensure_destination_absent(destination) do
    case File.lstat(destination) do
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:source_capture_destination_unavailable, reason}}
      {:ok, _stat} -> {:error, :source_capture_destination_exists}
    end
  end

  defp cleanup_capture_destination(destination) do
    case File.lstat(destination) do
      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}

      {:ok, _stat} ->
        case File.rm_rf(destination) do
          {:ok, _paths} -> :ok
          {:error, reason, path} -> {:error, {reason, path}}
        end
    end
  end

  defp source_mode(mode) when mode in @modes, do: {:ok, mode}
  defp source_mode("committed"), do: {:ok, :committed}
  defp source_mode("staged"), do: {:ok, :staged}
  defp source_mode("working-tree"), do: {:ok, :working_tree}
  defp source_mode("working_tree"), do: {:ok, :working_tree}
  defp source_mode(_mode), do: {:error, :source_mode_invalid}

  defp include_policy(opts) do
    if Keyword.get(opts, :include_ignored, false) and
         not Keyword.get(opts, :include_untracked, false),
       do: {:error, :include_ignored_requires_include_untracked},
       else: :ok
  end

  defp admit(%{unsupported_features: [_first | _rest] = features}, _mode),
    do: {:error, {:repository_features_unsupported, features}}

  defp admit(%{dirtiness: %{unmerged: count}}, _mode) when count > 0,
    do: {:error, :repository_has_unmerged_paths}

  defp admit(%{dirtiness: %{clean: false}}, :committed),
    do: {:error, :committed_source_requires_clean_repository}

  defp admit(_inspection, _mode), do: :ok

  defp expected_source(inspection, opts) do
    case Keyword.get(opts, :expected_source_state_token) do
      nil -> :ok
      token when token == inspection.source_state_token -> :ok
      _token -> {:error, :source_changed}
    end
  end

  defp apply_source_mode(_inspection, :committed, _authority, _opts), do: :ok

  defp apply_source_mode(inspection, :staged, authority, opts) do
    with {:ok, patch} <- SourceRead.staged_patch(inspection.root, inspection.base_commit, opts),
         :ok <- ManagedWorkspace.apply_patch(authority, patch, opts) do
      :ok
    end
  end

  defp apply_source_mode(inspection, :working_tree, authority, opts) do
    with :ok <- apply_source_mode(inspection, :staged, authority, opts),
         {:ok, destination} <- ManagedWorkspace.root(authority),
         {:ok, status} <-
           SourceRead.read(
             inspection.root,
             [
               "status",
               "--porcelain=v2",
               "-z",
               "--untracked-files=all",
               "--ignored=matching"
             ],
             opts
           ),
         {:ok, actions} <- overlay_actions(status, opts),
         :ok <- apply_actions(inspection.root, destination, actions, opts) do
      :ok
    end
  end

  defp managed_authority(destination, opts) do
    operation_id = Keyword.get(opts, :creation_operation_id)

    ManagedWorkspace.authorize(
      %{
        id: Keyword.get(opts, :workspace_id),
        path: destination,
        control_epoch: 0
      },
      expected_epoch: 0,
      lease: operation_id,
      operation_id: operation_id,
      request_id: Keyword.get(opts, :request_id),
      audit_fun: Keyword.get(opts, :git_audit_fun),
      scope: :execution
    )
  end

  defp unchanged(before, after_inspection) do
    if before.source_state_token == after_inspection.source_state_token and
         before.base_commit == after_inspection.base_commit,
       do: :ok,
       else: {:error, :source_changed}
  end

  defp source_capture_hook(opts, inspection, destination) do
    case Keyword.get(opts, :source_capture_hook) do
      hook when is_function(hook, 2) -> hook.(inspection, destination)
      nil -> :ok
    end
  end

  defp overlay_actions(status, opts) do
    status
    |> split_nul()
    |> overlay_actions(opts, [])
  end

  defp overlay_actions([], _opts, acc), do: {:ok, Enum.reverse(acc)}
  defp overlay_actions(["" | rest], opts, acc), do: overlay_actions(rest, opts, acc)

  defp overlay_actions([<<?1, ?\s, _x, y, _rest::binary>> = entry | rest], opts, acc) do
    acc = if y == ?., do: acc, else: [{:materialize, field_after_spaces(entry, 8)} | acc]
    overlay_actions(rest, opts, acc)
  end

  defp overlay_actions(
         [<<?2, ?\s, _x, y, _rest::binary>> = entry, original | rest],
         opts,
         acc
       ) do
    target = field_after_spaces(entry, 9)
    acc = if y == ?., do: acc, else: [{:materialize, target}, {:remove, original} | acc]
    overlay_actions(rest, opts, acc)
  end

  defp overlay_actions([<<?u, ?\s, _entry::binary>> | _remaining], _opts, _acc),
    do: {:error, :working_tree_unmerged}

  defp overlay_actions([<<??, ?\s, path::binary>> | rest], opts, acc) do
    acc =
      if Keyword.get(opts, :include_untracked, false), do: [{:materialize, path} | acc], else: acc

    overlay_actions(rest, opts, acc)
  end

  defp overlay_actions([<<?!, ?\s, path::binary>> | rest], opts, acc) do
    acc =
      if Keyword.get(opts, :include_ignored, false), do: [{:materialize, path} | acc], else: acc

    overlay_actions(rest, opts, acc)
  end

  defp overlay_actions([_unknown | rest], opts, acc), do: overlay_actions(rest, opts, acc)

  defp apply_actions(source_root, destination_root, actions, opts) do
    limits = %{
      files: Keyword.get(opts, :max_overlay_files, @default_max_overlay_files),
      file_bytes: Keyword.get(opts, :max_overlay_file_bytes, @default_max_overlay_file_bytes),
      total_bytes: Keyword.get(opts, :max_overlay_bytes, @default_max_overlay_bytes)
    }

    actions
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, 0, 0}, fn action, {:ok, files, bytes} ->
      case apply_action(source_root, destination_root, action, files, bytes, limits) do
        {:ok, next_files, next_bytes} -> {:cont, {:ok, next_files, next_bytes}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _files, _bytes} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp apply_action(_source_root, destination_root, {:remove, relative}, files, bytes, _limits) do
    with {:ok, destination} <- destination_path(destination_root, relative),
         :ok <- remove_destination(destination) do
      {:ok, files, bytes}
    end
  end

  defp apply_action(source_root, destination_root, {:materialize, relative}, files, bytes, limits) do
    with {:ok, source} <- source_path(source_root, relative),
         {:ok, destination} <- destination_path(destination_root, relative),
         {:ok, next_files, next_bytes} <-
           copy_entry(source_root, source, destination, files, bytes, limits) do
      {:ok, next_files, next_bytes}
    end
  end

  defp copy_entry(source_root, source, destination, files, bytes, limits) do
    with {:ok, stat} <- File.lstat(source) do
      case stat.type do
        :regular -> copy_regular(source, destination, stat, files, bytes, limits)
        :symlink -> copy_symlink(source_root, source, destination, files, bytes, limits)
        :directory -> copy_directory(source_root, source, destination, files, bytes, limits)
        type -> {:error, {:source_overlay_special_file_unsupported, source, type}}
      end
    else
      {:error, :enoent} ->
        with :ok <- remove_destination(destination), do: {:ok, files, bytes}

      {:error, reason} ->
        {:error, {:source_overlay_read_failed, source, reason}}
    end
  end

  defp copy_regular(source, destination, stat, files, bytes, limits) do
    next_files = files + 1
    next_bytes = bytes + stat.size

    with :ok <- within_limits(next_files, stat.size, next_bytes, limits),
         :ok <- remove_destination(destination),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.cp(source, destination),
         :ok <- File.chmod(destination, owner_mode(stat.mode)) do
      {:ok, next_files, next_bytes}
    end
  end

  defp copy_symlink(source_root, source, destination, files, bytes, limits) do
    with {:ok, target} <- File.read_link(source),
         :ok <- safe_symlink_target(source_root, source, target),
         :ok <- within_limits(files + 1, byte_size(target), bytes + byte_size(target), limits),
         :ok <- remove_destination(destination),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.ln_s(target, destination) do
      {:ok, files + 1, bytes + byte_size(target)}
    end
  end

  defp copy_directory(source_root, source, destination, files, bytes, limits) do
    with :ok <- File.mkdir_p(destination),
         :ok <- File.chmod(destination, 0o700),
         {:ok, names} <- File.ls(source) do
      Enum.reduce_while(names, {:ok, files, bytes}, fn name, {:ok, count, total} ->
        case copy_entry(
               source_root,
               Path.join(source, name),
               Path.join(destination, name),
               count,
               total,
               limits
             ) do
          {:ok, next_count, next_total} -> {:cont, {:ok, next_count, next_total}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp source_path(root, relative), do: bounded_path(root, relative, :source_overlay_path_invalid)

  defp destination_path(root, relative),
    do: bounded_path(root, relative, :source_overlay_destination_invalid)

  defp bounded_path(root, relative, error) when is_binary(relative) and relative != "" do
    path = Path.expand(relative, root)
    relative_to_root = Path.relative_to(path, root)

    if relative_to_root != ".." and not String.starts_with?(relative_to_root, "../") and
         Path.type(relative_to_root) != :absolute,
       do: {:ok, path},
       else: {:error, {error, relative}}
  end

  defp bounded_path(_root, relative, error), do: {:error, {error, relative}}

  defp remove_destination(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.rm_rf(path) do
          {:ok, _paths} -> :ok
          {:error, reason, _path} -> {:error, reason}
        end

      {:ok, _stat} ->
        File.rm(path)

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_symlink_target(root, source, target) do
    resolved = Path.expand(target, Path.dirname(source))

    if within_root?(resolved, root),
      do: :ok,
      else: {:error, {:source_overlay_symlink_escapes_repository, source}}
  end

  defp within_root?(path, root) do
    relative = Path.relative_to(path, root)

    relative != ".." and not String.starts_with?(relative, "../") and
      Path.type(relative) != :absolute
  end

  defp within_limits(files, file_bytes, total_bytes, limits) do
    cond do
      files > limits.files -> {:error, :source_overlay_too_many_files}
      file_bytes > limits.file_bytes -> {:error, :source_overlay_file_too_large}
      total_bytes > limits.total_bytes -> {:error, :source_overlay_too_large}
      true -> :ok
    end
  end

  defp owner_mode(mode) do
    if (mode &&& 0o111) == 0, do: 0o600, else: 0o700
  end

  defp field_after_spaces(binary, count), do: field_after_spaces(binary, count, 0)
  defp field_after_spaces(rest, count, count), do: rest

  defp field_after_spaces(<<?\s, rest::binary>>, count, seen),
    do: field_after_spaces(rest, count, seen + 1)

  defp field_after_spaces(<<_byte, rest::binary>>, count, seen),
    do: field_after_spaces(rest, count, seen)

  defp field_after_spaces(<<>>, _count, _seen), do: ""
  defp split_nul(binary), do: :binary.split(binary, <<0>>, [:global])
end
