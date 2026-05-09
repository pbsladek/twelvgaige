defmodule Twelvgaige.CLI.Commands.ShellAnalysisOps do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell
  alias Twelvgaige.Shell.Admission
  alias Twelvgaige.Shell.Doctor
  alias Twelvgaige.Shell.Graph
  alias Twelvgaige.Shell.Lint

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  @spec graph(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def graph(path, args) do
    with {:ok, opts} <- parse_graph_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, %Shell.Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         {:ok, graph} <- Graph.build(workflow) do
      {:ok, format_graph(graph, opts[:format]), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "shell graph requires a workflow shell",
            details: %{path: path}
          )

        format = args |> parse_graph_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}

      {:error, error} ->
        format = args |> parse_graph_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec lint(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def lint(path, args) do
    with {:ok, opts} <- parse_lint_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, report} <- Lint.run_target(path, strict?: opts[:strict?]) do
      {:ok, format_lint(report, opts[:format]), report.exit_code}
    else
      {:error, error} ->
        format = args |> parse_lint_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec admit(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def admit(path, args) do
    with {:ok, opts} <- parse_admit_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, %Shell.Workflow{} = workflow} <- Shell.Loader.load(path, root_opts(opts)),
         {:ok, report} <- Admission.report(workflow, policy: opts[:policy]) do
      {:ok, format_admission(path, report, opts[:format]), report.exit_code}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "shell admit requires a workflow shell",
            details: %{path: path}
          )

        format = args |> parse_admit_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}

      {:error, error} ->
        format = args |> parse_admit_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec doctor(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def doctor(path, args) do
    with {:ok, opts} <- parse_doctor_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, %Shell.Workflow{} = workflow} <- Twelvgaige.validate_shell(path) do
      report = Doctor.run(workflow, path: path, strict?: opts[:strict?])
      {:ok, format_doctor(report, opts[:format]), report.exit_code}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "shell doctor requires a workflow shell",
            details: %{path: path}
          )

        format = args |> parse_doctor_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}

      {:error, error} ->
        format = args |> parse_doctor_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp parse_graph_opts(args), do: parse_graph_opts(args, format: :text, root: nil)
  defp parse_graph_opts([], opts), do: {:ok, opts}

  defp parse_graph_opts(["--format", format | rest], opts) do
    case parse_graph_format(format) do
      {:ok, format} -> parse_graph_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_graph_opts(["--root", root | rest], opts),
    do: parse_graph_opts(rest, Keyword.put(opts, :root, root))

  defp parse_graph_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_graph_error_format(args) do
    args
    |> parse_graph_opts()
    |> case do
      {:ok, opts} -> graph_error_format(opts[:format])
      {:error, _error} -> :human
    end
  end

  defp parse_lint_opts(args), do: parse_lint_opts(args, format: :human, root: nil, strict?: false)
  defp parse_lint_opts([], opts), do: {:ok, opts}

  defp parse_lint_opts(["--strict" | rest], opts),
    do: parse_lint_opts(rest, Keyword.put(opts, :strict?, true))

  defp parse_lint_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_lint_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_lint_opts(["--root", root | rest], opts),
    do: parse_lint_opts(rest, Keyword.put(opts, :root, root))

  defp parse_lint_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_lint_error_format(args) do
    args
    |> parse_lint_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_admit_opts(args),
    do: parse_admit_opts(args, format: :human, root: nil, policy: :manual)

  defp parse_admit_opts([], opts), do: {:ok, opts}

  defp parse_admit_opts(["--policy", policy | rest], opts) do
    case Admission.normalize_policy(policy) do
      {:ok, policy} -> parse_admit_opts(rest, Keyword.put(opts, :policy, policy))
      {:error, _reason} = error -> error
    end
  end

  defp parse_admit_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_admit_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_admit_opts(["--root", root | rest], opts),
    do: parse_admit_opts(rest, Keyword.put(opts, :root, root))

  defp parse_admit_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_admit_error_format(args) do
    args
    |> parse_admit_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_doctor_opts(args),
    do: parse_doctor_opts(args, format: :human, root: nil, strict?: false)

  defp parse_doctor_opts([], opts), do: {:ok, opts}

  defp parse_doctor_opts(["--strict" | rest], opts),
    do: parse_doctor_opts(rest, Keyword.put(opts, :strict?, true))

  defp parse_doctor_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_doctor_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_doctor_opts(["--root", root | rest], opts),
    do: parse_doctor_opts(rest, Keyword.put(opts, :root, root))

  defp parse_doctor_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_doctor_error_format(args) do
    args
    |> parse_doctor_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_graph_format("text"), do: {:ok, :text}
  defp parse_graph_format("json"), do: {:ok, :json}
  defp parse_graph_format("mermaid"), do: {:ok, :mermaid}

  defp parse_graph_format(_format) do
    {:error,
     Twelvgaige.Error.new(:input_error, :invalid_shell, "format must be text, json, or mermaid")}
  end

  defp graph_error_format(:json), do: :json
  defp graph_error_format(_format), do: :human

  defp format_graph(graph, :json) do
    graph
    |> Graph.to_map()
    |> Map.merge(%{status: "ok", exit_code: 0, errors: []})
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_graph(graph, :mermaid), do: Graph.to_mermaid(graph)

  defp format_graph(graph, :text) do
    groups =
      graph.groups
      |> Enum.with_index(1)
      |> Enum.map(fn {group, index} -> "  #{index}. " <> Enum.join(group, ", ") end)
      |> Enum.join("\n")

    edges =
      case graph.edges do
        [] ->
          "  none"

        edges ->
          edges
          |> Enum.map(fn edge -> "  - #{edge.from} -> #{edge.to}" end)
          |> Enum.join("\n")
      end

    nodes =
      graph.nodes
      |> Enum.map(fn node ->
        flags =
          []
          |> maybe_flag(node.safety, "safety")
          |> maybe_flag(node.write_capable, "write")
          |> Enum.reverse()

        flags =
          case flags do
            [] -> ""
            flags -> " flags=" <> Enum.join(flags, ",")
          end

        deps =
          case node.dependencies do
            [] -> "root"
            deps -> "depends on " <> Enum.join(deps, ", ")
          end

        "  - #{node.id} [#{node.kind}] #{deps}#{flags}"
      end)
      |> Enum.join("\n")

    """
    Workflow graph: #{graph.workflow_id} #{graph.version}
    Groups:
    #{groups}
    Edges:
    #{edges}
    Shots:
    #{nodes}
    """
  end

  defp maybe_flag(flags, true, flag), do: [flag | flags]
  defp maybe_flag(flags, false, _flag), do: flags

  defp format_lint(report, :json) do
    report
    |> Lint.to_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_lint(%{reports: reports} = report, :human) do
    findings = Enum.flat_map(reports, & &1.findings)
    errors = Map.get(report, :errors, [])

    body =
      cond do
        errors != [] ->
          errors
          |> Enum.map(&"  [error] #{&1.path} - #{get_in(&1, [:error, :message])}")
          |> Enum.join("\n")

        findings == [] ->
          "  No findings."

        true ->
          reports
          |> Enum.flat_map(&format_lint_report_lines/1)
          |> Enum.join("\n")
      end

    """
    Shell lint: #{report.path}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Workflows: #{length(reports)}
    Findings: #{length(findings)}
    #{body}
    """
  end

  defp format_lint(report, :human) do
    lines = format_lint_report_lines(report)

    body =
      case lines do
        [] -> "  No findings."
        lines -> Enum.join(lines, "\n")
      end

    """
    Shell lint: #{report.path}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Findings: #{length(report.findings)}
    #{body}
    """
  end

  defp format_admission(path, report, :json) do
    report
    |> Admission.to_map()
    |> Map.put(:path, path)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_admission(path, report, :human) do
    body =
      case report.findings do
        [] ->
          "  Admitted."

        findings ->
          findings
          |> Enum.map(fn finding ->
            "  [#{finding.severity}] #{finding.id} - #{finding.message}"
          end)
          |> Enum.join("\n")
      end

    """
    Shell admission: #{path}
    Policy: #{report.policy}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Findings: #{length(report.findings)}
    #{body}
    """
  end

  defp format_lint_report_lines(report) do
    Enum.map(report.findings, fn finding ->
      location = lint_location(finding.location)
      "  [#{finding.severity}] #{finding.id}#{location} - #{finding.message}"
    end)
  end

  defp lint_location(%{shot_id: nil}), do: ""
  defp lint_location(%{shot_id: shot_id}), do: " shot=#{shot_id}"
  defp lint_location(_location), do: ""

  defp format_doctor(report, :json) do
    report
    |> Doctor.to_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_doctor(report, :human) do
    body =
      case report.recommendations do
        [] ->
          "  No recommendations."

        recommendations ->
          recommendations
          |> Enum.map(fn recommendation ->
            shot =
              case recommendation.shot_id do
                nil -> ""
                shot_id -> " shot=#{shot_id}"
              end

            "  [#{recommendation.severity}] #{recommendation.id}#{shot} - #{recommendation.action}"
          end)
          |> Enum.join("\n")
      end

    """
    Shell doctor: #{report.path}
    Workflow: #{report.workflow_id} #{report.version}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Recommendations: #{length(report.recommendations)}
    #{body}
    """
  end
end
