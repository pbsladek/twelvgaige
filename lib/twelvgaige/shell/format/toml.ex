defmodule Twelvgaige.Shell.Format.TOML do
  @moduledoc false

  @behaviour Twelvgaige.Shell.Format

  alias Twelvgaige.Shell.Validation, as: V

  @impl true
  def extensions, do: [".toml"]

  @impl true
  def parse(contents, path) when is_binary(contents) do
    case TomlElixir.decode(contents, spec: :"1.0.0") do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:error, error} ->
        V.error(:invalid_shell, "failed to parse TOML shell file", [], %{
          file_path: path,
          format: "toml",
          reason: error_message(error)
        })
    end
  end

  defp error_message(%{__exception__: true} = error), do: Exception.message(error)
end
