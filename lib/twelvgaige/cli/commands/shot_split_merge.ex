defmodule Twelvgaige.CLI.Commands.ShotSplitMerge do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.Authoring.ShotRefactor
  alias Twelvgaige.CLI.Commands.ShotHelpers
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell
  alias Twelvgaige.Shell.Lint, as: ShellLint

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  def split(path, shot_id, args) do
    with {:ok, opts} <- parse_split_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShotRefactor.split(path, shot_id, opts[:child_ids]),
         {:ok, lint_report} <- lint_candidate(path, result.workflow),
         result = Map.put(result, :lint_report, ShellLint.to_map(lint_report)) do
      if opts[:write?] do
        ShotHelpers.write_refactored(result, opts, &format_split/3)
      else
        {:ok, format_split(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        {:ok, format_command_error(error, parse_split_error_format(args)),
         ExitCode.for_error(error)}
    end
  end

  def merge(path, args) do
    with {:ok, opts} <- parse_merge_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShotRefactor.merge(path, opts[:source_ids], opts[:new_id]),
         {:ok, lint_report} <- lint_candidate(path, result.workflow),
         result = Map.put(result, :lint_report, ShellLint.to_map(lint_report)) do
      if opts[:write?] do
        ShotHelpers.write_refactored(result, opts, &format_merge/3)
      else
        {:ok, format_merge(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        {:ok, format_command_error(error, parse_merge_error_format(args)),
         ExitCode.for_error(error)}
    end
  end

  defp parse_split_opts(args),
    do: parse_split_opts(args, format: :human, root: nil, write?: false, child_ids: nil)

  defp parse_split_opts([], opts) do
    case opts[:child_ids] do
      child_ids when is_list(child_ids) and child_ids != [] ->
        {:ok, opts}

      _missing ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "shot split requires --into")}
    end
  end

  defp parse_split_opts(["--into", child_ids | rest], opts) do
    parse_split_opts(rest, Keyword.put(opts, :child_ids, ShotHelpers.csv_values(child_ids)))
  end

  defp parse_split_opts(["--write" | rest], opts),
    do: parse_split_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_split_opts(["--dry-run" | rest], opts),
    do: parse_split_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_split_opts(["--root", root | rest], opts),
    do: parse_split_opts(rest, Keyword.put(opts, :root, root))

  defp parse_split_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_split_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_split_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_split_error_format(args), do: ShotHelpers.parsed_format(args, &parse_split_opts/1)

  defp parse_merge_opts(args),
    do:
      parse_merge_opts(args,
        format: :human,
        root: nil,
        write?: false,
        source_ids: [],
        new_id: nil
      )

  defp parse_merge_opts([], opts) do
    cond do
      length(opts[:source_ids]) < 2 ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "shot merge requires at least two source shot ids"
         )}

      is_nil(opts[:new_id]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "shot merge requires --id")}

      true ->
        {:ok, opts}
    end
  end

  defp parse_merge_opts(["--id", new_id | rest], opts),
    do: parse_merge_opts(rest, Keyword.put(opts, :new_id, new_id))

  defp parse_merge_opts(["--write" | rest], opts),
    do: parse_merge_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_merge_opts(["--dry-run" | rest], opts),
    do: parse_merge_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_merge_opts(["--root", root | rest], opts),
    do: parse_merge_opts(rest, Keyword.put(opts, :root, root))

  defp parse_merge_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_merge_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_merge_opts(["--" <> _ = unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_merge_opts([source_id | rest], opts) do
    parse_merge_opts(rest, Keyword.update!(opts, :source_ids, &(&1 ++ [source_id])))
  end

  defp parse_merge_error_format(args), do: ShotHelpers.parsed_format(args, &parse_merge_opts/1)

  defp lint_candidate(path, workflow) do
    case Shell.Loader.load_agents_for_workflow(path) do
      {:ok, agents} ->
        report = ShellLint.run(workflow, path: path, strict?: true, agents: agents)

        if report.status == :ok do
          {:ok, report}
        else
          {:error,
           Twelvgaige.Error.new(
             :input_error,
             :invalid_shell,
             "split workflow failed contextual lint",
             details: %{findings: ShellLint.to_map(report).findings}
           )}
        end

      {:error, %Twelvgaige.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "agent shell discovery failed",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp format_split(result, :json, wrote?) do
    %{
      "path" => result.path,
      "shot_id" => result.shot_id,
      "child_ids" => result.child_ids,
      "final_child_id" => result.final_child_id,
      "format" => Atom.to_string(result.format),
      "dependent_ids" => result.dependent_ids,
      "updated_dependencies" => result.updated_dependencies,
      "updated_conditions" => result.updated_conditions,
      "lint_report" => Map.get(result, :lint_report),
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_split(result, :human, true) do
    """
    split shot: #{result.shot_id}
    workflow: #{result.path}
    child shots: #{Enum.join(result.child_ids, ", ")}
    final child: #{result.final_child_id}
    rewired dependents: #{ShotHelpers.empty_or_join(result.dependent_ids)}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    contextual lint: passed
    wrote: true
    """
  end

  defp format_split(result, :human, false) do
    """
    dry run: shot split #{result.shot_id} into #{Enum.join(result.child_ids, ", ")}
    workflow: #{result.path}
    final child: #{result.final_child_id}
    rewired dependents: #{ShotHelpers.empty_or_join(result.dependent_ids)}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    contextual lint: passed
    wrote: false

    #{result.diff}
    """
  end

  defp format_merge(result, :json, wrote?) do
    %{
      "path" => result.path,
      "source_ids" => result.source_ids,
      "new_id" => result.new_id,
      "format" => Atom.to_string(result.format),
      "dependent_ids" => result.dependent_ids,
      "updated_dependencies" => result.updated_dependencies,
      "updated_conditions" => result.updated_conditions,
      "lint_report" => Map.get(result, :lint_report),
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_merge(result, :human, true) do
    """
    merged shots: #{Enum.join(result.source_ids, ", ")} -> #{result.new_id}
    workflow: #{result.path}
    rewired dependents: #{ShotHelpers.empty_or_join(result.dependent_ids)}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    contextual lint: passed
    wrote: true
    """
  end

  defp format_merge(result, :human, false) do
    """
    dry run: shot merge #{Enum.join(result.source_ids, ", ")} -> #{result.new_id}
    workflow: #{result.path}
    rewired dependents: #{ShotHelpers.empty_or_join(result.dependent_ids)}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    contextual lint: passed
    wrote: false

    #{result.diff}
    """
  end
end
