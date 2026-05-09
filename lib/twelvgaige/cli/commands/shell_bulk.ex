defmodule Twelvgaige.CLI.Commands.ShellBulk do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.CLI.AuthoringIO
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell.BulkRefactor

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  @spec replace_agent(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t(), non_neg_integer()}
  def replace_agent(path, old_agent, new_agent, args) do
    with {:ok, opts} <- parse_replace_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         :ok <- AuthoringIO.ensure_output_within_root(opts[:output], root),
         {:ok, report} <-
           BulkRefactor.replace_agent(path, old_agent, new_agent,
             write?: opts[:write?],
             yes?: opts[:yes?]
           ) do
      maybe_write_report(report, opts)
    else
      {:error, error} ->
        format = args |> parse_replace_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec replace_tool(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t(), non_neg_integer()}
  def replace_tool(path, old_tool, new_tool, args) do
    with {:ok, opts} <- parse_replace_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         :ok <- AuthoringIO.ensure_output_within_root(opts[:output], root),
         {:ok, report} <-
           BulkRefactor.replace_tool(path, old_tool, new_tool,
             write?: opts[:write?],
             yes?: opts[:yes?]
           ) do
      maybe_write_report(report, opts)
    else
      {:error, error} ->
        format = args |> parse_replace_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp maybe_write_report(report, opts) do
    case opts[:output] do
      nil ->
        {:ok, format_report(report, opts[:format]), report.exit_code}

      output_path ->
        with :ok <- AuthoringIO.ensure_can_write(output_path, opts),
             :ok <-
               AuthoringIO.write_file(
                 output_path,
                 Jason.encode!(BulkRefactor.to_map(report), pretty: true) <> "\n"
               ) do
          {:ok, "wrote #{label(report)} report: #{output_path}\n", report.exit_code}
        else
          {:error, error} -> AuthoringIO.format_write_error(error)
        end
    end
  end

  defp parse_replace_opts(args),
    do:
      parse_replace_opts(args,
        format: :human,
        root: nil,
        output: nil,
        force?: false,
        write?: false,
        yes?: false
      )

  defp parse_replace_opts([], opts), do: {:ok, opts}

  defp parse_replace_opts(["--write" | rest], opts),
    do: parse_replace_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_replace_opts(["--dry-run" | rest], opts),
    do: parse_replace_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_replace_opts(["--yes" | rest], opts),
    do: parse_replace_opts(rest, Keyword.put(opts, :yes?, true))

  defp parse_replace_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_replace_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_replace_opts(["--root", root | rest], opts),
    do: parse_replace_opts(rest, Keyword.put(opts, :root, root))

  defp parse_replace_opts(["--output", output | rest], opts),
    do: parse_replace_opts(rest, Keyword.put(opts, :output, output))

  defp parse_replace_opts(["--force" | rest], opts),
    do: parse_replace_opts(rest, Keyword.put(opts, :force?, true))

  defp parse_replace_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_replace_error_format(args) do
    args
    |> parse_replace_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp format_report(report, :json) do
    report
    |> BulkRefactor.to_map()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_report(report, :human) do
    changes =
      case report.changes do
        [] ->
          "  none"

        changes ->
          changes
          |> Enum.map(fn change ->
            shots = change["changed_shot_ids"] |> Enum.join(",")
            "  - #{change["path"]} shots=#{shots} wrote=#{change["wrote"]}"
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
    Shell #{label(report)}: #{report.path}
    Mode: #{String.upcase(Atom.to_string(report.mode))}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Changed workflows: #{report.summary["changed_workflows"]}
    Changed shots: #{report.summary["changed_shots"]}
    Errors: #{report.summary["error_count"]}
    Changes:
    #{changes}
    Errors:
    #{errors}
    """
  end

  defp label(%{operation: operation}) do
    "bulk " <> (operation |> Atom.to_string() |> String.replace("_", "-"))
  end
end
