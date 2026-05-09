defmodule Twelvgaige.CLI.Commands.ShellPatch do
  @moduledoc false

  alias Twelvgaige.Authoring.Patch, as: AuthoringPatch
  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  @spec inspect_file(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def inspect_file(path, args) do
    with {:ok, opts} <- parse_inspect_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, report} <- AuthoringPatch.inspect_file(path, patch_opts(root)) do
      {:ok, format_report(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_inspect_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec verify(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def verify(path, args) do
    with {:ok, opts} <- parse_verify_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, report} <- AuthoringPatch.verify_file(path, patch_verify_opts(opts, root)) do
      {:ok, format_report(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_verify_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec apply(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def apply(path, args) do
    with {:ok, opts} <- parse_apply_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, report} <- AuthoringPatch.apply_file(path, patch_apply_opts(opts, root)) do
      {:ok, format_report(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_apply_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp parse_inspect_opts(args), do: parse_inspect_opts(args, format: :human, root: nil)
  defp parse_inspect_opts([], opts), do: {:ok, opts}

  defp parse_inspect_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_inspect_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_inspect_opts(["--root", root | rest], opts) do
    parse_inspect_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_inspect_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_inspect_error_format(args) do
    args
    |> parse_inspect_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_verify_opts(args),
    do: parse_verify_opts(args, format: :human, root: nil, approval: nil)

  defp parse_verify_opts([], opts), do: {:ok, opts}

  defp parse_verify_opts(["--approval", approval | rest], opts) do
    parse_verify_opts(rest, Keyword.put(opts, :approval, approval))
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

  defp parse_apply_opts(args),
    do:
      parse_apply_opts(args,
        format: :human,
        root: nil,
        approval: nil,
        write?: false
      )

  defp parse_apply_opts([], opts), do: {:ok, opts}

  defp parse_apply_opts(["--approval", approval | rest], opts) do
    parse_apply_opts(rest, Keyword.put(opts, :approval, approval))
  end

  defp parse_apply_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_apply_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_apply_opts(["--root", root | rest], opts) do
    parse_apply_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_apply_opts(["--write" | rest], opts) do
    parse_apply_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_apply_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_apply_error_format(args) do
    args
    |> parse_apply_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp patch_opts(%{root: root}), do: [root: root]

  defp patch_verify_opts(opts, root) do
    patch_opts(root) ++ [approval: opts[:approval]]
  end

  defp patch_apply_opts(opts, root) do
    patch_verify_opts(opts, root) ++ [write?: opts[:write?]]
  end

  defp format_report(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_report(report, :human) do
    files =
      report["files"]
      |> Enum.map(fn file ->
        findings =
          case file["findings"] do
            nil -> ""
            [] -> ""
            findings -> " findings=#{Enum.map_join(findings, ",", & &1["status"])}"
          end

        "  - #{file["path"]} #{file["kind"]} #{file["operation"]} #{file["before_digest"]} -> #{file["after_digest"]}#{findings}"
      end)
      |> Enum.join("\n")

    findings =
      case report["findings"] do
        [] ->
          "  none"

        findings ->
          findings
          |> Enum.map(&"  - #{&1["status"]}: #{&1["message"]}")
          |> Enum.join("\n")
      end

    approval =
      case Map.get(report, "approval") do
        nil -> "not_checked"
        approval -> approval["status"]
      end

    """
    Shell patch #{String.replace_prefix(report["kind"], "twelvgaige.patch.", "")}: #{report["patch_id"] || "unknown"}
    Status: #{String.upcase(report["status"])}
    Mode: #{report["mode"] || "check"}
    Changed: #{report["changed"]}
    Patch digest: #{report["patch_digest"]}
    Declared digest: #{report["declared_patch_digest"] || "missing"}
    Approval: #{approval}
    Files:
    #{files}
    Findings:
    #{findings}
    """
  end
end
