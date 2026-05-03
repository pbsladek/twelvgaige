defmodule Twelvgaige.Shell.Format.JSON do
  @moduledoc false

  @behaviour Twelvgaige.Shell.Format

  alias Twelvgaige.Shell.Validation, as: V

  @impl true
  def extensions, do: [".json"]

  @impl true
  def parse(contents, path) when is_binary(contents) do
    case Jason.decode(contents) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        V.error(:invalid_shell, "JSON shell document must be a map", [], %{
          file_path: path,
          format: "json"
        })

      {:error, %Jason.DecodeError{} = error} ->
        V.error(:invalid_shell, "failed to parse JSON shell file", [], %{
          file_path: path,
          format: "json",
          reason: Exception.message(error)
        })
    end
  end
end
