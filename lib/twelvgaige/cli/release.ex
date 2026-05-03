defmodule Twelvgaige.CLI.Release do
  @moduledoc """
  Release wrapper entrypoint.

  Mix release management scripts reserve `bin/<release_name>` for lifecycle
  commands. The native bundle ships a separate `bin/twelvgaige` wrapper that
  writes CLI arguments to a NUL-delimited file and invokes this module through
  the release `eval` command.
  """

  alias Twelvgaige.CLI.Main

  @args_file_env "TWELVGAIGE_RELEASE_CLI_ARGS_FILE"

  @spec main() :: :ok
  def main do
    @args_file_env
    |> System.get_env()
    |> args_from_file()
    |> Main.main()
  end

  @spec args_from_file(nil | Path.t()) :: [String.t()]
  def args_from_file(nil), do: []

  def args_from_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, ""} ->
        []

      {:ok, contents} ->
        contents = trim_trailing_nul(contents)

        if contents == "" do
          []
        else
          contents
          |> :binary.split(<<0>>, [:global])
          |> Enum.map(&to_string/1)
        end

      {:error, reason} ->
        raise "failed to read release CLI args file #{inspect(path)}: #{inspect(reason)}"
    end
  end

  defp trim_trailing_nul(contents) do
    last_index = byte_size(contents) - 1

    if last_index >= 0 and :binary.at(contents, last_index) == 0 do
      binary_part(contents, 0, last_index)
    else
      contents
    end
  end
end
