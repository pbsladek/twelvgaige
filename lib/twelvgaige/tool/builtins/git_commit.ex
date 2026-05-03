defmodule Twelvgaige.Tool.Builtins.GitCommit do
  @moduledoc """
  Commit explicit files in a trusted local Git work tree.

  This tool deliberately does not accept arbitrary git flags. It stages and
  commits only regular files below the configured root.
  """

  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor
  alias Twelvgaige.Tool.CommandRunner
  alias Twelvgaige.Tool.Idempotency

  @default_max_bytes 64 * 1024
  @hard_max_bytes 1_048_576
  @default_timeout_ms 30_000

  @impl true
  def name, do: "git_commit"

  @impl true
  def description, do: "Stage and commit explicit files under the configured Git work tree root."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "required" => ["paths", "message", "confirm"],
      "properties" => %{
        "paths" => %{"type" => "array", "items" => %{"type" => "string"}},
        "message" => %{"type" => "string"},
        "confirm" => %{"type" => "boolean"},
        "max_bytes" => %{"type" => "integer"}
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def safety_level, do: :destructive

  @impl true
  def idempotency do
    Idempotency.non_idempotent(
      reconciliation_strategy: :manual,
      side_effect_phase: :unknown
    )
  end

  @impl true
  def execute(input, opts) do
    root = opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

    with :ok <- require_confirm(input),
         {:ok, message} <- message(input),
         {:ok, max_bytes} <- max_bytes(input, opts),
         {:ok, paths} <- paths(input, root),
         {:ok, status} <- run_git(root, ["status", "--porcelain", "--"] ++ paths, opts),
         {:ok, _add} <- run_git(root, ["add", "--"] ++ paths, opts),
         {:ok, commit} <- run_git(root, ["commit", "-m", message, "--"] ++ paths, opts),
         {status_excerpt, status_truncated} <- bounded_excerpt(status.stdout, max_bytes),
         {commit_excerpt, commit_truncated} <- bounded_excerpt(commit.stdout, max_bytes) do
      {:ok,
       %{
         "root" => root,
         "paths" => paths,
         "message" => message,
         "status_excerpt" => status_excerpt,
         "commit_excerpt" => commit_excerpt,
         "truncated" => status_truncated or commit_truncated,
         "output_bytes" => byte_size(status_excerpt) + byte_size(commit_excerpt),
         "duration_ms" => status.duration_ms + commit.duration_ms,
         "exit_status" => commit.status
       }}
    end
  end

  defp require_confirm(input) do
    if value(input, "confirm") == true do
      :ok
    else
      {:error,
       Error.new(:policy_error, :policy_denied, "git_commit requires explicit confirm=true",
         safety_required: true,
         details: %{tool: name(), required: "confirm=true"}
       )}
    end
  end

  defp message(input) do
    case value(input, "message") do
      message when is_binary(message) ->
        message = String.trim(message)

        if message == "" do
          tool_error(:tool_input_invalid, "message must be non-empty")
        else
          {:ok, message}
        end

      _value ->
        tool_error(:tool_input_invalid, "message must be a string")
    end
  end

  defp paths(input, root) do
    with {:ok, paths} <- path_values(input),
         {:ok, paths} <- resolve_paths(paths, root) do
      {:ok, Enum.uniq(paths)}
    end
  end

  defp path_values(input) do
    case value(input, "paths") do
      paths when is_list(paths) and paths != [] ->
        if Enum.all?(paths, &(is_binary(&1) and String.trim(&1) != "")) do
          {:ok, paths}
        else
          tool_error(:tool_input_invalid, "paths must be non-empty strings")
        end

      _value ->
        tool_error(:tool_input_invalid, "paths must be a non-empty array")
    end
  end

  defp resolve_paths(paths, root) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      expanded_root = Path.expand(root)
      expanded_path = Path.expand(path, expanded_root)

      with :ok <- ensure_within_root(expanded_path, expanded_root),
           :ok <- ensure_no_symlink_components(expanded_path, expanded_root),
           :ok <- ensure_regular_file(expanded_path) do
        relative_path =
          expanded_path
          |> Path.relative_to(expanded_root)
          |> Path.split()
          |> Path.join()

        {:cont, {:ok, [relative_path | acc]}}
      else
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, Enum.reverse(paths)}
      {:error, _error} = error -> error
    end
  end

  defp ensure_within_root(expanded_path, expanded_root) do
    relative = Path.relative_to(expanded_path, expanded_root)

    if expanded_path != expanded_root and within_relative_path?(relative) do
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

  defp max_bytes(input, opts) do
    max_bytes =
      value(input, "max_bytes") ||
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

  defp run_git(root, args, opts) do
    runner = Keyword.get(opts, :command_runner, &CommandRunner.run/3)

    runner_opts =
      opts
      |> command_runner_opts()
      |> Keyword.put(:timeout_ms, Keyword.get(opts, :timeout_ms, @default_timeout_ms))
      |> Keyword.put(:cwd, root)

    case runner.("git", ["-C", root] ++ args, runner_opts) do
      {:ok, %{status: 0} = result} ->
        {:ok, normalize_result(result)}

      {:ok, %{status: status} = result} ->
        {:error,
         Error.new(:tool_error, :tool_non_retryable, "git exited with non-zero status",
           details: %{
             exit_status: status,
             stdout: Redactor.redact_text(Map.get(result, :stdout, "")),
             stderr: Redactor.redact_text(Map.get(result, :stderr, ""))
           }
         )}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        tool_error(:tool_retryable, "git command failed", reason: inspect(reason))
    end
  end

  defp normalize_result(result) do
    %{
      status: Map.fetch!(result, :status),
      stdout: Map.get(result, :stdout, ""),
      stderr: Map.get(result, :stderr, ""),
      duration_ms: Map.get(result, :duration_ms, 0)
    }
  end

  defp command_runner_opts(opts) do
    Keyword.take(opts, [
      :binary_path,
      :binary_paths,
      :require_absolute_binary?,
      :scrub_env?,
      :env_allowlist,
      :env,
      :max_output_bytes
    ])
  end

  defp bounded_excerpt(text, max_bytes) do
    redacted = Redactor.redact_text(text)

    if byte_size(redacted) > max_bytes do
      {binary_part(redacted, 0, max_bytes), true}
    else
      {redacted, false}
    end
  end

  defp value(map, key) do
    case Enum.find(map, fn {map_key, _value} -> key_string(map_key) == key end) do
      {_map_key, value} -> value
      nil -> nil
    end
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: inspect(key)

  defp tool_error(reason, message, details \\ %{}) do
    {:error,
     Error.new(:tool_error, reason, message,
       retryable: reason in [:tool_retryable, :tool_timeout],
       safety_required: reason in [:tool_denied],
       details: Map.new(details)
     )}
  end
end
