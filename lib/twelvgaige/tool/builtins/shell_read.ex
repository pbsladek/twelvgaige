defmodule Twelvgaige.Tool.Builtins.ShellRead do
  @moduledoc """
  Read a bounded amount of text from a file below an allowed root.

  This is intentionally not a shell command runner. It is a narrow read-only
  file tool so the first tool substrate has predictable safety semantics.
  """

  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Error
  alias Twelvgaige.Tool.Idempotency

  @default_max_bytes 64 * 1024
  @hard_max_bytes 1_048_576

  @impl true
  def name, do: "shell_read"

  @impl true
  def description, do: "Read a bounded file from the configured working tree root."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "required" => ["path"],
      "properties" => %{
        "path" => %{"type" => "string"},
        "max_bytes" => %{"type" => "integer"}
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def safety_level, do: :read_only

  @impl true
  def idempotency, do: Idempotency.read_only()

  @impl true
  def execute(input, opts) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    with {:ok, path} <- fetch_path(input),
         {:ok, max_bytes} <- max_bytes(input, opts),
         {:ok, expanded_path, expanded_root} <- resolve_path(root, path),
         :ok <- ensure_within_root(expanded_path, expanded_root),
         :ok <- ensure_no_symlink_components(expanded_path, expanded_root),
         :ok <- ensure_regular_file(expanded_path),
         {:ok, body} <- read_bounded(expanded_path, max_bytes) do
      truncated = byte_size(body) > max_bytes
      content = if truncated, do: binary_part(body, 0, max_bytes), else: body

      {:ok,
       %{
         "path" => Path.relative_to(expanded_path, expanded_root),
         "bytes" => byte_size(content),
         "truncated" => truncated,
         "content" => content
       }}
    end
  end

  defp fetch_path(input) do
    case Map.get(input, "path") || Map.get(input, :path) do
      path when is_binary(path) -> {:ok, path}
      _value -> tool_error(:tool_input_invalid, "path must be a string")
    end
  end

  defp max_bytes(input, opts) do
    max_bytes =
      Map.get(input, "max_bytes") ||
        Map.get(input, :max_bytes) ||
        Keyword.get(opts, :default_max_bytes, @default_max_bytes)

    hard_max_bytes = Keyword.get(opts, :hard_max_bytes, @hard_max_bytes)

    cond do
      not is_integer(max_bytes) or max_bytes <= 0 ->
        tool_error(:tool_input_invalid, "max_bytes must be a positive integer")

      max_bytes > hard_max_bytes ->
        {:ok, hard_max_bytes}

      true ->
        {:ok, max_bytes}
    end
  end

  defp resolve_path(root, path) do
    expanded_root = Path.expand(root)
    {:ok, Path.expand(path, expanded_root), expanded_root}
  end

  defp ensure_within_root(expanded_path, expanded_root) do
    relative = Path.relative_to(expanded_path, expanded_root)

    if expanded_path == expanded_root or within_relative_path?(relative) do
      :ok
    else
      tool_error(:tool_denied, "path is outside the allowed root",
        path: expanded_path,
        root: expanded_root
      )
    end
  end

  defp within_relative_path?(relative) do
    relative != ".." and
      not String.starts_with?(relative, "../") and
      Path.type(relative) == :relative
  end

  defp ensure_no_symlink_components(expanded_path, expanded_root) do
    relative = Path.relative_to(expanded_path, expanded_root)

    relative
    |> Path.split()
    |> Enum.reduce_while({:ok, expanded_root}, fn segment, {:ok, acc} ->
      current = Path.join(acc, segment)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} ->
          {:halt,
           tool_error(:tool_denied, "symlink paths are denied",
             path: current,
             root: expanded_root
           )}

        {:ok, _stat} ->
          {:cont, {:ok, current}}

        {:error, reason} ->
          {:halt,
           tool_error(:tool_non_retryable, "could not inspect file path",
             path: current,
             reason: reason
           )}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp ensure_regular_file(expanded_path) do
    if File.regular?(expanded_path) do
      :ok
    else
      tool_error(:tool_non_retryable, "path is not a regular file", path: expanded_path)
    end
  end

  defp read_bounded(expanded_path, max_bytes) do
    case File.open(expanded_path, [:read, :binary], fn io -> IO.binread(io, max_bytes + 1) end) do
      {:ok, :eof} ->
        {:ok, ""}

      {:ok, body} when is_binary(body) ->
        {:ok, body}

      {:error, reason} ->
        tool_error(:tool_non_retryable, "could not read file", %{reason: reason})
    end
  end

  defp tool_error(reason, message, details \\ %{}) do
    {:error,
     Error.new(:tool_error, reason, message,
       retryable: reason in [:tool_retryable, :tool_timeout],
       safety_required: reason in [:tool_denied],
       details: details
     )}
  end
end
