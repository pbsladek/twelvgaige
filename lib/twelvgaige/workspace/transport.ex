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
