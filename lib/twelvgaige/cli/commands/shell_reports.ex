defmodule Twelvgaige.CLI.Commands.ShellReports do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.CLI.AuthoringIO
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell.Impact
  alias Twelvgaige.Shell.Inventory

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  @spec inventory(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def inventory(path, args) do
    with {:ok, opts} <- parse_inventory_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         :ok <- AuthoringIO.ensure_output_within_root(opts[:output], root),
         {:ok, report} <- Inventory.run(path) do
      AuthoringIO.maybe_write_json_report(
        Inventory.to_map(report),
        opts,
        "inventory",
        fn -> format_inventory(report, opts[:format]) end
      )
    else
      {:error, error} ->
        format = args |> parse_inventory_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec impact(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def impact(path, args) do
    with {:ok, opts} <- parse_impact_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         :ok <- AuthoringIO.ensure_output_within_root(opts[:output], root),
         {:ok, report} <- Impact.run(path, opts[:selector_kind], opts[:selector_value]) do
      AuthoringIO.maybe_write_json_report(
        Impact.to_map(report),
        opts,
        "impact",
        fn -> format_impact(report, opts[:format]) end
      )
    else
      {:error, error} ->
        format = args |> parse_impact_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp parse_inventory_opts(args),
    do: parse_inventory_opts(args, format: :human, root: nil, output: nil, force?: false)

  defp parse_inventory_opts([], opts), do: {:ok, opts}

  defp parse_inventory_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_inventory_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_inventory_opts(["--root", root | rest], opts) do
    parse_inventory_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_inventory_opts(["--output", output | rest], opts) do
    parse_inventory_opts(rest, Keyword.put(opts, :output, output))
  end

  defp parse_inventory_opts(["--force" | rest], opts) do
    parse_inventory_opts(rest, Keyword.put(opts, :force?, true))
  end

  defp parse_inventory_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_inventory_error_format(args) do
    args
    |> parse_inventory_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_impact_opts(args) do
    parse_impact_opts(args,
      format: :human,
      root: nil,
      output: nil,
      force?: false,
      selector_kind: nil,
      selector_value: nil
    )
  end

  defp parse_impact_opts([], opts) do
    if opts[:selector_kind] && opts[:selector_value] do
      {:ok, opts}
    else
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shell impact requires --agent, --tool, or --template"
       )}
    end
  end

  defp parse_impact_opts(["--agent", value | rest], opts),
    do: put_impact_selector(rest, opts, :agent, value)

  defp parse_impact_opts(["--tool", value | rest], opts),
    do: put_impact_selector(rest, opts, :tool, value)

  defp parse_impact_opts(["--template", value | rest], opts),
    do: put_impact_selector(rest, opts, :template, value)

  defp parse_impact_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_impact_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_impact_opts(["--root", root | rest], opts) do
    parse_impact_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_impact_opts(["--output", output | rest], opts) do
    parse_impact_opts(rest, Keyword.put(opts, :output, output))
  end

  defp parse_impact_opts(["--force" | rest], opts) do
    parse_impact_opts(rest, Keyword.put(opts, :force?, true))
  end

  defp parse_impact_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp put_impact_selector(rest, opts, selector_kind, selector_value) do
    if opts[:selector_kind] do
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shell impact accepts exactly one selector"
       )}
    else
      opts =
        opts
        |> Keyword.put(:selector_kind, selector_kind)
        |> Keyword.put(:selector_value, selector_value)

      parse_impact_opts(rest, opts)
    end
  end

  defp parse_impact_error_format(args) do
    args
    |> parse_impact_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp format_inventory(report, :json) do
    report
    |> Inventory.to_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_inventory(report, :human) do
    summary = report.summary

    workflows =
      case report.workflows do
        [] ->
          "  none"

        workflows ->
          workflows
          |> Enum.map(fn workflow ->
            lifecycle = Map.get(workflow, "lifecycle", "none")
            owner = Map.get(workflow, "owner", "none")
            write = if Map.get(workflow, "write_capable", false), do: " write", else: ""

            "  - #{workflow["id"]} #{workflow["version"]} owner=#{owner} lifecycle=#{lifecycle}#{write}"
          end)
          |> Enum.join("\n")
      end

    errors =
      case report.errors do
        [] ->
          "  none"

        errors ->
          errors
          |> Enum.map(&"  - #{&1["path"]}: #{get_in(&1, ["error", "message"])}")
          |> Enum.join("\n")
      end

    """
    Shell inventory: #{report.path}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Workflows: #{summary["workflow_count"]}
    Agents: #{summary["agent_count"]}
    Tools: #{summary["tool_count"]}
    Errors: #{summary["error_count"]}
    Workflow shells:
    #{workflows}
    Invalid shells:
    #{errors}
    """
  end

  defp format_impact(report, :json) do
    report
    |> Impact.to_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_impact(report, :human) do
    matches =
      case report.matches do
        [] ->
          "  none"

        matches ->
          matches
          |> Enum.map(fn match ->
            shots =
              match
              |> Map.get("matching_shots", [])
              |> Enum.map(& &1["id"])
              |> case do
                [] -> ""
                shot_ids -> " shots=" <> Enum.join(shot_ids, ",")
              end

            "  - #{match["id"]} #{match["version"]}#{shots} path=#{match["path"]}"
          end)
          |> Enum.join("\n")
      end

    """
    Shell impact: #{report.path}
    Selector: #{report.selector["kind"]}=#{report.selector["value"]}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Workflows: #{report.summary["workflow_count"]}
    Shots: #{report.summary["shot_count"]}
    Errors: #{report.summary["error_count"]}
    Matches:
    #{matches}
    """
  end
end
