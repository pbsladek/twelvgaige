defmodule Twelvgaige.Authoring.AtomicFile do
  @moduledoc """
  Atomic file writes for authoring commands.

  Authoring writes go through a temporary sibling file and rename into place so
  failed writes do not leave partial workflow shells behind.
  """

  alias Twelvgaige.Error

  @spec write(Path.t(), iodata(), keyword()) :: :ok | {:error, Error.t()}
  def write(path, contents, opts \\ [])

  def write(path, contents, opts) when is_binary(path) do
    tmp_path = Keyword.get_lazy(opts, :tmp_path, fn -> tmp_path(path) end)
    mkdir_fun = Keyword.get(opts, :mkdir_fun, &File.mkdir_p/1)
    write_fun = Keyword.get(opts, :write_fun, &File.write/2)
    rename_fun = Keyword.get(opts, :rename_fun, &File.rename/2)
    rm_fun = Keyword.get(opts, :rm_fun, &File.rm/1)

    with :ok <- mkdir_fun.(Path.dirname(path)),
         :ok <- write_fun.(tmp_path, contents),
         :ok <- rename_fun.(tmp_path, path) do
      :ok
    else
      {:error, reason} ->
        _ = rm_fun.(tmp_path)

        {:error,
         Error.new(:input_error, :invalid_shell, "unable to write shell file",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  def write(_path, _contents, _opts) do
    {:error, Error.new(:input_error, :invalid_shell, "write path must be a string")}
  end

  defp tmp_path(path), do: "#{path}.tmp-#{System.unique_integer([:positive])}"
end
