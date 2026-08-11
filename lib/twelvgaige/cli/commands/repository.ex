defmodule Twelvgaige.CLI.Commands.Repository do
  @moduledoc false

  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}
  alias Twelvgaige.Workspace.RepositoryInspection

  def inspect(args, deps \\ []) do
    with {:ok, opts} <- parse(args, repository: ".", base_ref: "HEAD", format: :human),
         {:ok, inspection} <-
           inspector(deps).(
             Path.expand(opts[:repository]),
             base_ref: opts[:base_ref]
           ) do
      {:ok, format(inspection, opts[:format]), 0}
    else
      {:error, reason} ->
        format = if("json" in args, do: :json, else: :human)
        {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
    end
  end

  defp inspector(deps),
    do: Keyword.get(deps, :repository_inspector, &RepositoryInspection.inspect/2)

  defp parse([], opts), do: {:ok, opts}

  defp parse(["--repo", repository | rest], opts),
    do: parse(rest, Keyword.put(opts, :repository, repository))

  defp parse(["--base-ref", base_ref | rest], opts),
    do: parse(rest, Keyword.put(opts, :base_ref, base_ref))

  defp parse(["--format", value | rest], opts) when value in ["human", "json"],
    do: parse(rest, Keyword.put(opts, :format, String.to_existing_atom(value)))

  defp parse(["--format", value | _rest], _opts), do: {:error, {:invalid_format, value}}
  defp parse([unknown | _rest], _opts), do: {:error, {:unknown_option, unknown}}

  defp format(inspection, :json),
    do: inspection |> RepositoryInspection.to_map() |> CommandHelpers.encode_line()

  defp format(inspection, :human) do
    dirty = inspection.dirtiness

    """
    Repository: #{inspection.root}
    Git: #{inspection.git_version} (minimum 2.39.0)
    Base: #{inspection.base_commit}#{branch_suffix(inspection.branch)}
    Object format: #{inspection.object_format}
    Source modes: #{inspection.source_modes |> Enum.map(&source_mode/1) |> Enum.join(", ")}
    State: staged=#{dirty.staged}, unstaged=#{dirty.unstaged}, untracked=#{dirty.untracked}, ignored=#{dirty.ignored}, unmerged=#{dirty.unmerged}
    Source token: #{inspection.source_state_token}
    Unsupported: #{list(inspection.unsupported_features)}
    Warnings: #{list(inspection.warnings)}
    """
  end

  defp branch_suffix(nil), do: ""
  defp branch_suffix(branch), do: " (#{branch})"
  defp source_mode(:working_tree), do: "working-tree"
  defp source_mode(mode), do: Atom.to_string(mode)
  defp list([]), do: "none"
  defp list(values), do: Enum.map_join(values, ", ", &Kernel.inspect/1)
end
