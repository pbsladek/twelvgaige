defmodule Twelvgaige.Workspace.Transport do
  @moduledoc "Import/export rules shared by bind-worktree and copy-snapshot sandboxes."

  alias Twelvgaige.Workspace

  @spec export_declared(Workspace.t(), [String.t()], Path.t()) ::
          {:ok, [Path.t()]} | {:error, term()}
  def export_declared(%Workspace{} = workspace, declared_paths, destination)
      when is_list(declared_paths) do
    destination = Path.expand(destination)

    with :ok <- File.mkdir_p(destination) do
      Enum.reduce_while(declared_paths, {:ok, []}, fn relative, {:ok, exported} ->
        with {:ok, source} <- resolve_declared(workspace.path, relative),
             {:ok, target} <- resolve_declared(destination, relative),
             :ok <- reject_symlink(source),
             :ok <- File.mkdir_p(Path.dirname(target)),
             :ok <- copy_entry(source, target) do
          {:cont, {:ok, [target | exported]}}
        else
          {:error, reason} -> {:halt, {:error, {relative, reason}}}
        end
      end)
      |> case do
        {:ok, paths} -> {:ok, Enum.reverse(paths)}
        {:error, _reason} = error -> error
      end
    end
  end

  @spec mount_contract(Workspace.t()) :: map()
  def mount_contract(%Workspace{transport: :bind_worktree} = workspace) do
    %{
      mode: :bind,
      source: workspace.path,
      destination: "/workspace",
      writable: workspace.writable
    }
  end

  def mount_contract(%Workspace{transport: :copy_snapshot} = workspace) do
    %{
      mode: :copy,
      source: workspace.path,
      destination: "/workspace",
      writable_host_mount: false,
      writable: workspace.writable
    }
  end

  @doc "Rejects symlinks and non-file/directory entries in a sandbox export."
  def validate_export_tree(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, names} <- File.ls(path) do
          Enum.reduce_while(names, :ok, fn name, :ok ->
            case validate_export_tree(Path.join(path, name)) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, :symlink_not_exportable}

      {:ok, _stat} ->
        {:error, :unsupported_file_type}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Validates a complete runtime workspace, including repository-contained relative symlinks."
  def validate_runtime_tree(path, opts \\ []) do
    root = Path.expand(path)
    maximum = Keyword.get(opts, :max_bytes)

    with {:ok, %{bytes: bytes, entries: entries}} <- validate_runtime_entry(root, root, 0, 0),
         :ok <- within_runtime_limit(bytes, maximum) do
      {:ok, %{bytes: bytes, entries: entries}}
    end
  end

  defp validate_runtime_entry(_root, _path, _bytes, entries) when entries > 1_000_000,
    do: {:error, :runtime_workspace_entry_limit_exceeded}

  defp validate_runtime_entry(root, path, bytes, entries) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        {:ok, %{bytes: bytes + size, entries: entries + 1}}

      {:ok, %File.Stat{type: :directory}} ->
        with {:ok, names} <- File.ls(path) do
          Enum.reduce_while(names, {:ok, %{bytes: bytes, entries: entries + 1}}, fn name,
                                                                                    {:ok, acc} ->
            case validate_runtime_entry(root, Path.join(path, name), acc.bytes, acc.entries) do
              {:ok, next} -> {:cont, {:ok, next}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end

      {:ok, %File.Stat{type: :symlink}} ->
        with {:ok, target} <- File.read_link(path),
             :ok <- safe_runtime_symlink(root, path, target) do
          {:ok, %{bytes: bytes + byte_size(target), entries: entries + 1}}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, {:runtime_workspace_file_type_denied, type}}

      {:error, reason} ->
        {:error, {:runtime_workspace_stat_failed, reason}}
    end
  end

  defp safe_runtime_symlink(root, path, target) do
    resolved = Path.expand(target, Path.dirname(path))

    if Path.type(target) == :relative and
         (resolved == root or String.starts_with?(resolved, root <> "/")),
       do: :ok,
       else: {:error, :runtime_workspace_symlink_escapes_root}
  end

  defp within_runtime_limit(_bytes, nil), do: :ok
  defp within_runtime_limit(bytes, maximum) when is_integer(maximum) and bytes <= maximum, do: :ok
  defp within_runtime_limit(_bytes, _maximum), do: {:error, :runtime_workspace_size_exceeded}

  defp resolve_declared(root, relative) when is_binary(relative) do
    expanded_root = Path.expand(root)
    expanded = Path.expand(relative, expanded_root)

    if expanded == expanded_root or String.starts_with?(expanded, expanded_root <> "/") do
      {:ok, expanded}
    else
      {:error, :path_traversal}
    end
  end

  defp reject_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :symlink_not_exportable}
      {:ok, _stat} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_entry(source, target) do
    case File.stat(source) do
      {:ok, %File.Stat{type: :regular}} -> File.cp(source, target)
      {:ok, %File.Stat{type: :directory}} -> copy_directory(source, target)
      {:ok, _stat} -> {:error, :unsupported_file_type}
      {:error, reason} -> {:error, reason}
    end
  end

  defp copy_directory(source, target) do
    with :ok <- File.mkdir_p(target),
         {:ok, names} <- File.ls(source) do
      Enum.reduce_while(names, :ok, fn name, :ok ->
        source_entry = Path.join(source, name)
        target_entry = Path.join(target, name)

        case reject_symlink(source_entry) do
          :ok ->
            case copy_entry(source_entry, target_entry) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
    end
  end
end
