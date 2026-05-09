defmodule Twelvgaige.CLI.Commands.ShotReplace do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.Authoring.ShotRefactor
  alias Twelvgaige.CLI.Commands.ShotHelpers
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell
  alias Twelvgaige.Shell.Lint, as: ShellLint

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  def set_schema(path, shot_id, schema_path, args) do
    with {:ok, opts} <- parse_schema_set_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         :ok <- AuthoringRoot.ensure_within_root(schema_path, root),
         {:ok, schema} <- read_schema_file(schema_path),
         {:ok, result} <- ShotRefactor.set_schema(path, shot_id, schema) do
      if opts[:write?] do
        write_schema_set(result, opts)
      else
        {:ok, format_schema_set(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_schema_set_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  def replace_agent(path, old_agent, new_agent, args) do
    with {:ok, opts} <- parse_replace_agent_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShotRefactor.replace_agent(path, old_agent, new_agent),
         {:ok, lint_report} <- lint_replaced_agent_candidate(path, result.workflow, new_agent),
         result = Map.put(result, :lint_report, ShellLint.to_map(lint_report)) do
      if opts[:write?] do
        write_replaced_agent(result, opts)
      else
        {:ok, format_replace_agent(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_replace_agent_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  def replace_tool(path, old_tool, new_tool, args) do
    with {:ok, opts} <- parse_replace_tool_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShotRefactor.replace_tool(path, old_tool, new_tool),
         {:ok, lint_report} <- lint_replaced_tool_candidate(path, result.workflow, new_tool),
         result = Map.put(result, :lint_report, ShellLint.to_map(lint_report)) do
      if opts[:write?] do
        write_replaced_tool(result, opts)
      else
        {:ok, format_replace_tool(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_replace_tool_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp write_schema_set(result, opts) do
    ShotHelpers.write_refactored(result, opts, &format_schema_set/3)
  end

  defp write_replaced_agent(result, opts) do
    ShotHelpers.write_refactored(result, opts, &format_replace_agent/3)
  end

  defp write_replaced_tool(result, opts) do
    ShotHelpers.write_refactored(result, opts, &format_replace_tool/3)
  end

  defp parse_schema_set_opts(args),
    do: parse_schema_set_opts(args, format: :human, root: nil, write?: false)

  defp parse_schema_set_opts([], opts), do: {:ok, opts}

  defp parse_schema_set_opts(["--write" | rest], opts) do
    parse_schema_set_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_schema_set_opts(["--dry-run" | rest], opts) do
    parse_schema_set_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_schema_set_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_schema_set_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_schema_set_opts(["--root", root | rest], opts) do
    parse_schema_set_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_schema_set_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_schema_set_error_format(args) do
    args
    |> parse_schema_set_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_replace_agent_opts(args),
    do: parse_replace_agent_opts(args, format: :human, root: nil, write?: false)

  defp parse_replace_agent_opts([], opts), do: {:ok, opts}

  defp parse_replace_agent_opts(["--write" | rest], opts) do
    parse_replace_agent_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_replace_agent_opts(["--dry-run" | rest], opts) do
    parse_replace_agent_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_replace_agent_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_replace_agent_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_replace_agent_opts(["--root", root | rest], opts) do
    parse_replace_agent_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_replace_agent_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_replace_agent_error_format(args) do
    args
    |> parse_replace_agent_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_replace_tool_opts(args),
    do: parse_replace_tool_opts(args, format: :human, root: nil, write?: false)

  defp parse_replace_tool_opts([], opts), do: {:ok, opts}

  defp parse_replace_tool_opts(["--write" | rest], opts) do
    parse_replace_tool_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_replace_tool_opts(["--dry-run" | rest], opts) do
    parse_replace_tool_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_replace_tool_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_replace_tool_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_replace_tool_opts(["--root", root | rest], opts) do
    parse_replace_tool_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_replace_tool_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_replace_tool_error_format(args) do
    args
    |> parse_replace_tool_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp read_schema_file(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, schema} <- Jason.decode(contents) do
      if is_map(schema) do
        {:ok, schema}
      else
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "schema file must contain a JSON object",
           details: %{path: path}
         )}
      end
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "failed to parse schema JSON file",
           details: %{path: path, reason: Exception.message(error)}
         )}

      {:error, reason} ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "unable to read schema file",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp lint_replaced_agent_candidate(path, workflow, new_agent) do
    with {:ok, agents} <- Shell.Loader.load_agents_for_workflow(path),
         :ok <- ensure_replacement_agent_discovered(new_agent, agents) do
      report = ShellLint.run(workflow, path: path, strict?: true, agents: agents)

      if report.status == :ok do
        {:ok, report}
      else
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "replacement agent failed contextual lint",
           details: %{agent: new_agent, findings: ShellLint.to_map(report).findings}
         )}
      end
    else
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

  defp ensure_replacement_agent_discovered(new_agent, agents) do
    if Enum.any?(agents, &(&1.id == new_agent)) do
      :ok
    else
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "replacement agent shell was not discovered",
         details: %{agent: new_agent, discovered_agents: Enum.map(agents, & &1.id)}
       )}
    end
  end

  defp lint_replaced_tool_candidate(path, workflow, new_tool) do
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
             "replacement tool failed contextual lint",
             details: %{tool: new_tool, findings: ShellLint.to_map(report).findings}
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

  defp format_schema_set(result, :json, wrote?) do
    %{
      "path" => result.path,
      "shot_id" => result.shot_id,
      "format" => Atom.to_string(result.format),
      "previous_schema" => result.previous_schema,
      "output_schema" => result.output_schema,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_schema_set(result, :human, true) do
    """
    set output schema: #{result.shot_id}
    workflow: #{result.path}
    schema type: #{Map.get(result.output_schema, "type", "unknown")}
    replaced existing schema: #{not is_nil(result.previous_schema)}
    wrote: true
    """
  end

  defp format_schema_set(result, :human, false) do
    """
    dry run: shot schema set #{result.shot_id}
    workflow: #{result.path}
    schema type: #{Map.get(result.output_schema, "type", "unknown")}
    replaced existing schema: #{not is_nil(result.previous_schema)}
    wrote: false

    #{result.diff}
    """
  end

  defp format_replace_agent(result, :json, wrote?) do
    %{
      "path" => result.path,
      "old_agent" => result.old_agent,
      "new_agent" => result.new_agent,
      "format" => Atom.to_string(result.format),
      "changed_shot_ids" => result.changed_shot_ids,
      "lint_report" => Map.get(result, :lint_report),
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_replace_agent(result, :human, true) do
    """
    replaced agent: #{result.old_agent} -> #{result.new_agent}
    workflow: #{result.path}
    changed shots: #{Enum.join(result.changed_shot_ids, ", ")}
    contextual lint: passed
    wrote: true
    """
  end

  defp format_replace_agent(result, :human, false) do
    """
    dry run: shot replace-agent #{result.old_agent} -> #{result.new_agent}
    workflow: #{result.path}
    changed shots: #{Enum.join(result.changed_shot_ids, ", ")}
    contextual lint: passed
    wrote: false

    #{result.diff}
    """
  end

  defp format_replace_tool(result, :json, wrote?) do
    %{
      "path" => result.path,
      "old_tool" => result.old_tool,
      "new_tool" => result.new_tool,
      "format" => Atom.to_string(result.format),
      "changed_shot_ids" => result.changed_shot_ids,
      "lint_report" => Map.get(result, :lint_report),
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_replace_tool(result, :human, true) do
    """
    replaced tool: #{result.old_tool} -> #{result.new_tool}
    workflow: #{result.path}
    changed shots: #{Enum.join(result.changed_shot_ids, ", ")}
    contextual lint: passed
    wrote: true
    """
  end

  defp format_replace_tool(result, :human, false) do
    """
    dry run: shot replace-tool #{result.old_tool} -> #{result.new_tool}
    workflow: #{result.path}
    changed shots: #{Enum.join(result.changed_shot_ids, ", ")}
    contextual lint: passed
    wrote: false

    #{result.diff}
    """
  end
end
