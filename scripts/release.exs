defmodule Twelvgaige.ReleaseScript do
  @moduledoc false

  @mix_file "mix.exs"

  def main(args) do
    with {:ok, opts} <- parse_args(args),
         :ok <- require_git_repo(),
         {:ok, current} <- current_version(),
         {:ok, next} <- next_version(current, opts),
         :ok <- validate_version(next),
         :ok <- ensure_release_version(current, next, opts),
         :ok <- ensure_clean_worktree(opts),
         :ok <- ensure_tag_absent(next),
         :ok <- maybe_print_plan(current, next, opts),
         :ok <- maybe_apply(current, next, opts) do
      :ok
    else
      {:error, message} ->
        IO.puts(:stderr, "release error: #{message}")
        System.halt(1)
    end
  end

  defp parse_args(args), do: parse_args(args, %{bump: "patch", push?: false, dry_run?: false})

  defp parse_args([], opts), do: {:ok, opts}

  defp parse_args(["--bump", bump | rest], opts),
    do: parse_args(rest, %{opts | bump: bump})

  defp parse_args(["--version", version | rest], opts),
    do: parse_args(rest, opts |> Map.delete(:bump) |> Map.put(:version, version))

  defp parse_args(["--push" | rest], opts),
    do: parse_args(rest, %{opts | push?: true})

  defp parse_args(["--dry-run" | rest], opts),
    do: parse_args(rest, %{opts | dry_run?: true})

  defp parse_args(["--help" | _rest], _opts) do
    IO.puts("""
    Usage:
      elixir scripts/release.exs [--bump patch|minor|major] [--version X.Y.Z] [--dry-run] [--push]

    Examples:
      elixir scripts/release.exs --bump patch --dry-run
      elixir scripts/release.exs --bump minor
      elixir scripts/release.exs --version 1.0.0 --push
    """)

    System.halt(0)
  end

  defp parse_args([unknown | _rest], _opts), do: {:error, "unknown argument #{inspect(unknown)}"}

  defp require_git_repo do
    case git(["rev-parse", "--is-inside-work-tree"], trim?: true) do
      {:ok, "true"} -> :ok
      _other -> {:error, "must run from inside a git repository"}
    end
  end

  defp current_version do
    with {:ok, source} <- File.read(@mix_file),
         [_, version] <- Regex.run(~r/version:\s*"(\d+\.\d+\.\d+)"/, source) do
      {:ok, version}
    else
      {:error, reason} -> {:error, "could not read #{@mix_file}: #{inspect(reason)}"}
      _other -> {:error, "could not find semantic version in #{@mix_file}"}
    end
  end

  defp next_version(_current, %{version: version}), do: {:ok, version}

  defp next_version(current, %{bump: bump}) do
    with {:ok, [major, minor, patch]} <- parse_version(current) do
      case bump do
        "patch" -> {:ok, Enum.join([major, minor, patch + 1], ".")}
        "minor" -> {:ok, Enum.join([major, minor + 1, 0], ".")}
        "major" -> {:ok, Enum.join([major + 1, 0, 0], ".")}
        other -> {:error, "unsupported bump #{inspect(other)}; expected patch, minor, or major"}
      end
    end
  end

  defp parse_version(version) do
    parts =
      version
      |> String.split(".")
      |> Enum.map(&Integer.parse/1)

    case parts do
      [{major, ""}, {minor, ""}, {patch, ""}] -> {:ok, [major, minor, patch]}
      _other -> {:error, "invalid semantic version #{inspect(version)}"}
    end
  end

  defp validate_version(version) do
    case parse_version(version) do
      {:ok, _parts} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp ensure_release_version(current, next, %{version: _version}) do
    with {:ok, current_parts} <- parse_version(current),
         {:ok, next_parts} <- parse_version(next) do
      case Version.compare(Enum.join(next_parts, "."), Enum.join(current_parts, ".")) do
        :lt -> {:error, "next version #{next} must not be less than current version #{current}"}
        _eq_or_gt -> :ok
      end
    end
  end

  defp ensure_release_version(current, next, _opts) do
    with {:ok, current_parts} <- parse_version(current),
         {:ok, next_parts} <- parse_version(next) do
      if Version.compare(Enum.join(next_parts, "."), Enum.join(current_parts, ".")) == :gt do
        :ok
      else
        {:error, "next version #{next} must be greater than current version #{current}"}
      end
    end
  end

  defp ensure_clean_worktree(%{dry_run?: true}), do: :ok

  defp ensure_clean_worktree(_opts) do
    case git(["status", "--porcelain"], trim?: true) do
      {:ok, ""} ->
        :ok

      {:ok, output} ->
        {:error,
         "worktree must be clean before releasing. Commit or stash changes first.\n\n#{output}"}

      {:error, message} ->
        {:error, message}
    end
  end

  defp ensure_tag_absent(version) do
    tag = tag_name(version)

    case git(["rev-parse", "--verify", "--quiet", "refs/tags/#{tag}"], trim?: true) do
      {:ok, _sha} -> {:error, "tag #{tag} already exists"}
      {:error, _message} -> :ok
    end
  end

  defp maybe_print_plan(current, next, opts) do
    tag = tag_name(next)

    IO.puts("""
    Release plan:
      current version: #{current}
      next version:    #{next}
      tag:             #{tag}
      push:            #{opts.push?}
      dry run:         #{opts.dry_run?}
    """)

    :ok
  end

  defp maybe_apply(_current, _next, %{dry_run?: true}), do: :ok

  defp maybe_apply(current, next, opts) do
    tag = tag_name(next)

    with :ok <- maybe_commit_version(current, next, tag),
         :ok <- run_git(["tag", "-a", tag, "-m", "Release #{tag}"]),
         :ok <- maybe_push(tag, opts) do
      IO.puts("created release #{tag}")
      :ok
    end
  end

  defp maybe_commit_version(version, version, _tag), do: :ok

  defp maybe_commit_version(current, next, tag) do
    with :ok <- update_mix_version(current, next),
         :ok <- run_git(["add", @mix_file]),
         :ok <- run_git(["commit", "-m", "Release #{tag}"]) do
      :ok
    end
  end

  defp update_mix_version(current, next) do
    with {:ok, source} <- File.read(@mix_file) do
      updated = String.replace(source, ~s(version: "#{current}"), ~s(version: "#{next}"))
      File.write(@mix_file, updated)
    else
      {:error, reason} -> {:error, "could not update #{@mix_file}: #{inspect(reason)}"}
    end
  end

  defp maybe_push(_tag, %{push?: false}), do: :ok

  defp maybe_push(tag, %{push?: true}) do
    with {:ok, branch} <- current_branch(),
         :ok <- run_git(["push", "origin", "HEAD:#{branch}"]),
         :ok <- run_git(["push", "origin", tag]) do
      :ok
    end
  end

  defp current_branch do
    case git(["branch", "--show-current"], trim?: true) do
      {:ok, ""} -> {:error, "cannot push from detached HEAD"}
      {:ok, branch} -> {:ok, branch}
      {:error, message} -> {:error, message}
    end
  end

  defp tag_name(version), do: "v#{version}"

  defp run_git(args) do
    case git(args, trim?: false) do
      {:ok, _output} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  defp git(args, opts) do
    {output, status} = System.cmd("git", args, stderr_to_stdout: true)
    output = if opts[:trim?], do: String.trim(output), else: output

    if status == 0 do
      {:ok, output}
    else
      {:error, "git #{Enum.join(args, " ")} failed:\n#{output}"}
    end
  end
end

Twelvgaige.ReleaseScript.main(System.argv())
