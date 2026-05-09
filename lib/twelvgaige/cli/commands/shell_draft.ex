defmodule Twelvgaige.CLI.Commands.ShellDraft do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.Authoring.ShellDraft, as: Draft
  alias Twelvgaige.CLI.AuthoringIO
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell
  alias Twelvgaige.Shell.Lint

  import Twelvgaige.CLI.CommandHelpers, only: [format_command_error: 2, root_opts: 1]

  @spec draft([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def draft(args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringIO.ensure_output_within_root(opts[:output], root),
         {:ok, source} <- read_source(opts[:from]),
         {:ok, report} <- Draft.draft(source, draft_opts(opts)) do
      if opts[:write?] do
        write_draft(report, opts)
      else
        {:ok, report.candidate, 0}
      end
    else
      {:error, error} ->
        {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp write_draft(report, opts) do
    case opts[:output] do
      nil ->
        Twelvgaige.Error.new(:input_error, :invalid_shell, "--output is required with --write")
        |> AuthoringIO.format_write_error()

      output_path ->
        with :ok <- AuthoringIO.ensure_can_write(output_path, opts),
             :ok <- AuthoringIO.write_file(output_path, report.candidate),
             {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(output_path),
             {:ok, lint_report} <- Lint.run_path(output_path, strict?: true),
             :ok <- ensure_lint_ok(lint_report) do
          {:ok, "created draft workflow shell: #{output_path}\n", 0}
        else
          {:ok, _other_shell} ->
            error =
              Twelvgaige.Error.new(
                :input_error,
                :invalid_shell,
                "drafted shell did not validate as a workflow",
                details: %{path: output_path}
              )

            AuthoringIO.format_write_error(error)

          {:error, error} ->
            AuthoringIO.format_write_error(error)
        end
    end
  end

  defp ensure_lint_ok(%{status: :ok}), do: :ok

  defp ensure_lint_ok(report) do
    {:error,
     Twelvgaige.Error.new(:compile_error, :invalid_shell, "drafted shell failed strict lint",
       details: %{lint: Lint.to_map(report)}
     )}
  end

  defp parse_opts(args) do
    parse_opts(args,
      from: nil,
      provider: "mock",
      model: "mock-model",
      allow_remote?: false,
      max_input_bytes: 64 * 1024,
      format: :yaml,
      output: nil,
      write?: false,
      force?: false,
      root: nil
    )
  end

  defp parse_opts([], opts) do
    cond do
      is_nil(opts[:from]) ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "shell draft requires --from")}

      opts[:output] && not opts[:write?] ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "shell draft requires --write when --output is provided"
         )}

      true ->
        {:ok, opts}
    end
  end

  defp parse_opts(["--from", from | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :from, from))

  defp parse_opts(["--provider", provider | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :provider, provider))

  defp parse_opts(["--model", model | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :model, model))

  defp parse_opts(["--allow-remote" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :allow_remote?, true))

  defp parse_opts(["--max-input-bytes", value | rest], opts) do
    case parse_positive_integer(value, "--max-input-bytes") do
      {:ok, max_input_bytes} ->
        parse_opts(rest, Keyword.put(opts, :max_input_bytes, max_input_bytes))

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_opts(["--format", format | rest], opts) do
    case parse_document_format(format) do
      {:ok, format} -> parse_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_opts(["--output", output | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :output, output))

  defp parse_opts(["--write" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_opts(["--dry-run" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_opts(["--force" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :force?, true))

  defp parse_opts(["--root", root | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :root, root))

  defp parse_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp draft_opts(opts) do
    [
      provider: opts[:provider],
      model: opts[:model],
      allow_remote?: opts[:allow_remote?],
      max_input_bytes: opts[:max_input_bytes],
      format: opts[:format]
    ]
  end

  defp read_source("-"), do: {:ok, IO.read(:stdio, :eof)}

  defp read_source(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "unable to read draft source",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp parse_document_format("json"), do: {:ok, :json}
  defp parse_document_format("yaml"), do: {:ok, :yaml}
  defp parse_document_format("toml"), do: {:ok, :toml}

  defp parse_document_format(_format) do
    {:error,
     Twelvgaige.Error.new(:input_error, :invalid_shell, "format must be json, yaml, or toml")}
  end

  defp parse_positive_integer(value, label) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 ->
        {:ok, integer}

      _other ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "#{label} must be a positive integer")}
    end
  end
end
