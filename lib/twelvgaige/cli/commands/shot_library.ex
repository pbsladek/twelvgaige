defmodule Twelvgaige.CLI.Commands.ShotLibrary do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.Authoring.ShotLibrary
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell.Document, as: ShellDocument

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  @spec list([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def list(args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, templates} <- ShotLibrary.list(shot_library_opts(opts, root)) do
      {:ok, format_list(templates, opts[:format]), 0}
    else
      {:error, error} ->
        format = args |> parse_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec show(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def show(template_id, args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, template} <- ShotLibrary.fetch(template_id, shot_library_opts(opts, root)) do
      {:ok, format_template(template, opts[:format]), 0}
    else
      {:error, error} ->
        format = args |> parse_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec verify([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def verify(args) do
    with {:ok, opts} <- parse_verify_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- ensure_output_within_root(opts[:lockfile], root),
         {:ok, report} <- ShotLibrary.verify(verify_opts(opts, root)) do
      {:ok, format_verify(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_verify_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec update([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def update(args) do
    with {:ok, opts} <- parse_verify_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- ensure_output_within_root(opts[:lockfile], root),
         {:ok, report} <- ShotLibrary.update(verify_opts(opts, root)) do
      {:ok, format_update(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_verify_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec outdated(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def outdated(path, args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, report} <- ShotLibrary.outdated(path, shot_library_opts(opts, root)) do
      {:ok, format_outdated(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp parse_opts(args), do: parse_opts(args, format: :human, root: nil, library_paths: [])
  defp parse_opts([], opts), do: {:ok, opts}

  defp parse_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_opts(["--root", root | rest], opts) do
    parse_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_opts(["--library-path", path | rest], opts) do
    parse_opts(rest, Keyword.update!(opts, :library_paths, &(&1 ++ [path])))
  end

  defp parse_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_error_format(args) do
    args
    |> parse_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_verify_opts(args) do
    parse_verify_opts(args,
      format: :human,
      root: nil,
      library_paths: [],
      lockfile: nil,
      write_lock?: false
    )
  end

  defp parse_verify_opts([], opts), do: {:ok, opts}

  defp parse_verify_opts(["--write-lock" | rest], opts) do
    parse_verify_opts(rest, Keyword.put(opts, :write_lock?, true))
  end

  defp parse_verify_opts(["--lockfile", lockfile | rest], opts) do
    parse_verify_opts(rest, Keyword.put(opts, :lockfile, lockfile))
  end

  defp parse_verify_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_verify_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_verify_opts(["--root", root | rest], opts) do
    parse_verify_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_verify_opts(["--library-path", path | rest], opts) do
    parse_verify_opts(rest, Keyword.update!(opts, :library_paths, &(&1 ++ [path])))
  end

  defp parse_verify_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_verify_error_format(args) do
    args
    |> parse_verify_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp shot_library_opts(opts, root) do
    [library_paths: opts[:library_paths], root: root[:root]]
  end

  defp verify_opts(opts, root) do
    [
      library_paths: opts[:library_paths],
      root: root[:root],
      lockfile: opts[:lockfile],
      write_lock?: opts[:write_lock?]
    ]
  end

  defp ensure_output_within_root(nil, _root), do: :ok
  defp ensure_output_within_root(path, root), do: AuthoringRoot.ensure_within_root(path, root)

  defp format_list(templates, :json) do
    templates
    |> Enum.map(&ShotLibrary.to_map/1)
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_list(templates, :human) do
    rows =
      case templates do
        [] ->
          "  none"

        templates ->
          templates
          |> Enum.map(fn template ->
            source = Atom.to_string(template.source)
            description = template.description || ""

            "  - #{template.namespace}/#{template.id} #{template.version} #{source} #{description}"
          end)
          |> Enum.join("\n")
      end

    "Shot templates:\n#{rows}\n"
  end

  defp format_template(template, :json) do
    template
    |> ShotLibrary.to_map()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_template(template, :human) do
    {:ok, shot} = ShellDocument.encode(template.shot, :yaml)

    """
    Shot template: #{template.namespace}/#{template.id}
    Version: #{template.version}
    Source: #{template.source}
    Digest: #{template.digest}
    Description: #{template.description || ""}

    #{shot}
    """
  end

  defp format_verify(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_verify(report, :human) do
    findings = format_template_findings(report["findings"])

    """
    Shot library verify: #{report["lockfile"]}
    Status: #{String.upcase(report["status"])}
    Mode: #{report["mode"]}
    Checked: #{report["checked"]}
    Findings:
    #{findings}
    """
  end

  defp format_update(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_update(report, :human) do
    findings = format_template_findings(report["findings"])

    diff =
      case Map.get(report, "diff") do
        nil -> ""
        "" -> ""
        diff -> "\n#{diff}"
      end

    """
    Shot library update: #{report["lockfile"]}
    Status: #{String.upcase(report["status"])}
    Mode: #{report["mode"]}
    Checked: #{report["checked"]}
    Changed: #{report["changed"]}
    Findings:
    #{findings}
    #{diff}
    """
  end

  defp format_outdated(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_outdated(report, :human) do
    findings =
      case report["findings"] do
        [] ->
          "  none"

        findings ->
          findings
          |> Enum.map(fn finding ->
            status = Map.get(finding, "status")
            workflow = Map.get(finding, "workflow")
            shot = Map.get(finding, "shot")
            template = Map.get(finding, "template", "unknown")
            message = Map.get(finding, "message")
            "  - #{status} #{workflow}.#{shot} #{template}: #{message}"
          end)
          |> Enum.join("\n")
      end

    errors =
      case report["errors"] do
        [] ->
          "  none"

        errors ->
          errors
          |> Enum.map(&"  - #{&1["path"]}: #{get_in(&1, ["error", "message"])}")
          |> Enum.join("\n")
      end

    """
    Shot library outdated: #{report["path"]}
    Status: #{String.upcase(report["status"])}
    Workflows: #{report["checked_workflows"]}
    Template shots: #{report["checked_shots"]}
    Findings:
    #{findings}
    Errors:
    #{errors}
    """
  end

  defp format_template_findings([]), do: "  none"

  defp format_template_findings(findings) do
    findings
    |> Enum.map(fn finding ->
      template = Map.get(finding, "template", "lockfile")
      status = Map.get(finding, "status")
      message = Map.get(finding, "message")
      "  - #{status} #{template}: #{message}"
    end)
    |> Enum.join("\n")
  end
end
