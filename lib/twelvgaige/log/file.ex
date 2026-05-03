defmodule Twelvgaige.Log.File do
  @moduledoc """
  Bounded JSON-lines file sink for structured logs.

  Retention is byte-oriented and local-first: after each append, oldest complete
  JSON lines are dropped until the file is within the configured cap.
  """

  alias Twelvgaige.Security.FileMode

  @spec write_line(Path.t(), iodata(), pos_integer() | nil) :: :ok | {:error, term()}
  def write_line(path, line, max_bytes \\ nil)

  def write_line(path, line, max_bytes) when is_binary(path) do
    line = IO.iodata_to_binary(line)

    :global.trans({__MODULE__, path}, fn ->
      with :ok <- ensure_parent(path),
           :ok <- File.write(path, line, [:append]),
           :ok <- FileMode.ensure_private_file(path) do
        enforce_retention(path, line, max_bytes)
      end
    end)
  end

  def write_line(_path, _line, _max_bytes), do: {:error, :invalid_log_path}

  defp ensure_parent(path) do
    FileMode.ensure_private_parent_dir(path)
  end

  defp enforce_retention(_path, _line, nil), do: :ok

  defp enforce_retention(path, last_line, max_bytes)
       when is_integer(max_bytes) and max_bytes > 0 do
    with {:ok, %{size: size}} when size > max_bytes <- File.stat(path),
         {:ok, contents} <- File.read(path) do
      with :ok <- File.write(path, retain_newest_lines(contents, last_line, max_bytes)) do
        FileMode.ensure_private_file(path)
      end
    else
      {:ok, _stat} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp enforce_retention(_path, _line, _max_bytes), do: :ok

  defp retain_newest_lines(contents, last_line, max_bytes) do
    lines =
      contents
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 <> "\n"))

    lines
    |> Enum.reverse()
    |> Enum.reduce_while({[], 0}, fn line, {kept, used} ->
      line_bytes = byte_size(line)

      cond do
        used + line_bytes <= max_bytes ->
          {:cont, {[line | kept], used + line_bytes}}

        kept == [] ->
          marker = oversize_marker(last_line, max_bytes)
          {:halt, {[marker], byte_size(marker)}}

        true ->
          {:halt, {kept, used}}
      end
    end)
    |> elem(0)
    |> IO.iodata_to_binary()
  end

  defp oversize_marker(line, max_bytes) do
    marker =
      Jason.encode!(%{
        "timestamp" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now()),
        "level" => "warn",
        "event" => "log_retention_truncated",
        "message" => "log line exceeded max retained bytes",
        "original_bytes" => byte_size(line),
        "max_file_bytes" => max_bytes
      }) <> "\n"

    if byte_size(marker) <= max_bytes do
      marker
    else
      ""
    end
  end
end
