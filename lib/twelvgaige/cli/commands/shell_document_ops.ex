defmodule Twelvgaige.CLI.Commands.ShellDocumentOps do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.CLI.AuthoringIO
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Shell.Formatter

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  @spec normalize(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def normalize(path, args) do
    with {:ok, opts} <- parse_normalize_opts(args),
         {:ok, shell} <- Twelvgaige.validate_shell(path),
         {:ok, contents} <- Document.encode(shell, opts[:format]) do
      {:ok, contents, 0}
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec convert(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def convert(path, args) do
    with {:ok, opts} <- parse_convert_opts(args),
         {:ok, shell} <- Twelvgaige.validate_shell(path),
         {:ok, contents} <- Document.encode(shell, opts[:to]) do
      case opts[:output] do
        nil -> {:ok, contents, 0}
        output_path -> write_converted(output_path, contents)
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec fmt(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def fmt(path, args) do
    with {:ok, opts} <- parse_fmt_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- Formatter.format(path) do
      cond do
        opts[:check?] ->
          {:ok, format_fmt(result, opts[:format], :check), if(result.changed?, do: 1, else: 0)}

        opts[:write?] ->
          write_formatted(result, opts)

        true ->
          {:ok, format_fmt(result, opts[:format], :dry_run), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_fmt_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp write_formatted(result, opts) do
    if result.changed? do
      with :ok <- AuthoringIO.write_file(result.path, result.candidate),
           {:ok, _shell} <- Twelvgaige.validate_shell(result.path) do
        {:ok, format_fmt(result, opts[:format], :write), 0}
      else
        {:error, error} -> AuthoringIO.format_write_error(error)
      end
    else
      {:ok, format_fmt(result, opts[:format], :write), 0}
    end
  end

  defp write_converted(output_path, contents) do
    with :ok <- File.mkdir_p(Path.dirname(output_path)),
         :ok <- File.write(output_path, contents) do
      {:ok, "converted shell: #{output_path}\n", 0}
    else
      {:error, reason} ->
        error =
          Twelvgaige.Error.new(:input_error, :invalid_shell, "unable to write converted shell",
            details: %{path: output_path, reason: inspect(reason)}
          )

        {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_normalize_opts(args), do: parse_normalize_opts(args, format: :json)
  defp parse_normalize_opts([], opts), do: {:ok, opts}

  defp parse_normalize_opts(["--format", format | rest], opts) do
    case parse_document_format(format) do
      {:ok, format} -> parse_normalize_opts(rest, Keyword.put(opts, :format, format))
      {:error, _error} = error -> error
    end
  end

  defp parse_normalize_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_convert_opts(args), do: parse_convert_opts(args, to: nil, output: nil)

  defp parse_convert_opts([], opts) do
    if is_nil(Keyword.get(opts, :to)) do
      {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--to is required")}
    else
      {:ok, opts}
    end
  end

  defp parse_convert_opts(["--to", format | rest], opts) do
    case parse_document_format(format) do
      {:ok, format} -> parse_convert_opts(rest, Keyword.put(opts, :to, format))
      {:error, _error} = error -> error
    end
  end

  defp parse_convert_opts(["--output", output | rest], opts) do
    parse_convert_opts(rest, Keyword.put(opts, :output, output))
  end

  defp parse_convert_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_fmt_opts(args),
    do: parse_fmt_opts(args, format: :human, root: nil, check?: false, write?: false)

  defp parse_fmt_opts([], opts) do
    if opts[:check?] and opts[:write?] do
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shell fmt accepts either --check or --write, not both"
       )}
    else
      {:ok, opts}
    end
  end

  defp parse_fmt_opts(["--check" | rest], opts),
    do: parse_fmt_opts(rest, Keyword.put(opts, :check?, true))

  defp parse_fmt_opts(["--write" | rest], opts),
    do: parse_fmt_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_fmt_opts(["--dry-run" | rest], opts),
    do: parse_fmt_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_fmt_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_fmt_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_fmt_opts(["--root", root | rest], opts),
    do: parse_fmt_opts(rest, Keyword.put(opts, :root, root))

  defp parse_fmt_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_fmt_error_format(args) do
    args
    |> parse_fmt_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_document_format("json"), do: {:ok, :json}
  defp parse_document_format("yaml"), do: {:ok, :yaml}
  defp parse_document_format("toml"), do: {:ok, :toml}

  defp parse_document_format(_format) do
    {:error,
     Twelvgaige.Error.new(:input_error, :invalid_shell, "format must be json, yaml, or toml")}
  end

  defp format_fmt(result, :json, mode) do
    result
    |> Formatter.to_map()
    |> Map.merge(%{
      mode: Atom.to_string(mode),
      wrote: mode == :write and result.changed?,
      status: if(result.changed?, do: "changed", else: "ok"),
      exit_code: if(mode == :check and result.changed?, do: 1, else: 0)
    })
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_fmt(result, :human, :check) do
    if result.changed? do
      "shell fmt check failed: #{result.path} is not canonical\n"
    else
      "shell fmt check passed: #{result.path}\n"
    end
  end

  defp format_fmt(result, :human, :write) do
    if result.changed? do
      """
      formatted shell: #{result.path}
      kind: #{result.kind}
      id: #{result.id}
      wrote: true
      """
    else
      "shell already formatted: #{result.path}\n"
    end
  end

  defp format_fmt(result, :human, :dry_run) do
    if result.changed? do
      """
      dry run: shell fmt #{result.path}
      kind: #{result.kind}
      id: #{result.id}
      wrote: false

      #{result.diff}
      """
    else
      "shell already formatted: #{result.path}\n"
    end
  end
end
