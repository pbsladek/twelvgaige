defmodule Twelvgaige.Security.FileMode do
  @moduledoc """
  Conservative local filesystem permission helpers.

  These helpers are best-effort on Windows and strict on POSIX platforms. They
  are intended for runtime, store, and log paths that may contain tokens,
  prompts, tool output, audit events, or recovery snapshots.
  """

  import Bitwise

  @private_dir 0o700
  @private_file 0o600
  @world_writable 0o002
  @sticky 0o1000

  @spec ensure_private_dir(Path.t()) :: :ok | {:error, term()}
  def ensure_private_dir(path) when is_binary(path) do
    path = Path.expand(path)

    with :ok <- refuse_world_writable_parent(path),
         :ok <- File.mkdir_p(path) do
      chmod_if_supported(path, @private_dir)
    end
  end

  def ensure_private_dir(_path), do: {:error, :invalid_path}

  @spec ensure_private_parent_dir(Path.t()) :: :ok | {:error, term()}
  def ensure_private_parent_dir(file_path) when is_binary(file_path) do
    parent = file_path |> Path.expand() |> Path.dirname()

    if File.dir?(parent) do
      refuse_world_writable_parent(parent)
    else
      ensure_private_dir(parent)
    end
  end

  def ensure_private_parent_dir(_file_path), do: {:error, :invalid_path}

  @spec ensure_private_file(Path.t()) :: :ok | {:error, term()}
  def ensure_private_file(path) when is_binary(path) do
    path = Path.expand(path)

    with {:ok, stat} <- File.stat(path),
         false <- stat.type == :directory do
      chmod_if_supported(path, @private_file)
    else
      true -> {:error, :is_directory}
      {:error, _reason} = error -> error
    end
  end

  def ensure_private_file(_path), do: {:error, :invalid_path}

  @spec ensure_private_existing_files([Path.t()]) :: :ok | {:error, term()}
  def ensure_private_existing_files(paths) when is_list(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.exists?(path) do
        true ->
          case ensure_private_file(path) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end

        false ->
          {:cont, :ok}
      end
    end)
  end

  @spec refuse_world_writable_parent(Path.t()) :: :ok | {:error, term()}
  def refuse_world_writable_parent(path) when is_binary(path) do
    if windows?() do
      :ok
    else
      path
      |> nearest_existing_parent()
      |> reject_insecure_parent()
    end
  end

  def refuse_world_writable_parent(_path), do: {:error, :invalid_path}

  @spec chmod_if_supported(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  def chmod_if_supported(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, :eperm} -> if(windows?(), do: :ok, else: {:error, :eperm})
      {:error, _reason} = error -> error
    end
  end

  defp nearest_existing_parent(path) do
    path = Path.expand(path)

    cond do
      File.exists?(path) ->
        path

      parent = Path.dirname(path) ->
        if parent == path do
          path
        else
          nearest_existing_parent(parent)
        end
    end
  end

  defp reject_insecure_parent(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} ->
        if world_writable_without_sticky?(mode) do
          {:error, {:insecure_world_writable_parent, path}}
        else
          :ok
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp world_writable_without_sticky?(mode) do
    (mode &&& @world_writable) != 0 and (mode &&& @sticky) == 0
  end

  defp windows? do
    match?({:win32, _name}, :os.type())
  end
end
