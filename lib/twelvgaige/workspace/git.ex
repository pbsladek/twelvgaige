defmodule Twelvgaige.Workspace.Git do
  @moduledoc "Git operations for isolated delegated workspaces."

  @spec resolve_commit(Path.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_commit(repository, ref, opts \\ []) do
    case run(["-C", repository, "rev-parse", "--verify", "#{ref}^{commit}"], opts) do
      {:ok, output} -> {:ok, String.trim(output)}
      {:error, reason} -> {:error, {:git_ref_unresolved, reason}}
    end
  end

  @spec create_worktree(Path.t(), Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_worktree(repository, destination, commit, opts \\ []) do
    with :ok <- ensure_absent(destination),
         {:ok, _output} <-
           run(["-C", repository, "worktree", "add", "--detach", destination, commit], opts) do
      :ok
    end
  end

  @spec remove_worktree(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def remove_worktree(repository, destination, opts \\ []) do
    case run(["-C", repository, "worktree", "remove", "--force", destination], opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec create_snapshot(Path.t(), Path.t(), String.t(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def create_snapshot(repository, destination, commit, allowed_paths, opts \\ []) do
    with :ok <- ensure_absent(destination),
         :ok <- File.mkdir_p(destination),
         {:ok, archive} <- archive(repository, commit, allowed_paths, opts),
         :ok <- extract_tar(archive, destination),
         :ok <- initialize_snapshot_repository(destination, commit, opts) do
      :ok
    end
  end

  @spec diff(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def diff(path, opts \\ []), do: run(["-C", path, "diff", "--binary", "HEAD"], opts)

  @spec status(Path.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def status(path, opts \\ []), do: run(["-C", path, "status", "--porcelain=v1"], opts)

  defp archive(repository, commit, allowed_paths, opts) do
    args = ["-C", repository, "archive", "--format=tar", commit]
    args = if allowed_paths == [], do: args, else: args ++ ["--"] ++ allowed_paths
    run(args, Keyword.put(opts, :binary, true))
  end

  defp extract_tar(archive, destination) do
    case :erl_tar.extract({:binary, archive}, [{:cwd, String.to_charlist(destination)}]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:snapshot_extract_failed, reason}}
    end
  end

  defp initialize_snapshot_repository(destination, source_commit, opts) do
    commands = [
      ["-C", destination, "init", "--quiet"],
      ["-C", destination, "config", "user.name", "Twelvgaige Snapshot"],
      ["-C", destination, "config", "user.email", "snapshot@localhost"],
      ["-C", destination, "add", "--all"],
      ["-C", destination, "commit", "--quiet", "-m", "snapshot #{source_commit}"]
    ]

    Enum.reduce_while(commands, :ok, fn args, :ok ->
      case run(args, opts) do
        {:ok, _output} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:snapshot_git_init_failed, reason}}}
      end
    end)
  end

  defp ensure_absent(path) do
    if File.exists?(path), do: {:error, :workspace_path_exists}, else: :ok
  end

  defp run(args, opts) do
    runner = Keyword.get(opts, :command_runner, &System.cmd/3)

    case runner.("git", args, stderr_to_stdout: true) do
      {:ok, output} -> {:ok, output}
      {:error, _reason} = error -> error
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, %{status: status, output: output}}
    end
  rescue
    error -> {:error, Exception.message(error)}
  end
end
