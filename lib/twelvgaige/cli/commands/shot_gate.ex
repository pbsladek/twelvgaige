defmodule Twelvgaige.CLI.Commands.ShotGate do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.Authoring.ShotRefactor
  alias Twelvgaige.CLI.Commands.ShotHelpers
  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  def gate(path, target_id, args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <-
           ShotRefactor.gate(path, target_id, opts[:gate_id],
             description: opts[:description],
             prompt: opts[:prompt]
           ) do
      if opts[:write?] do
        ShotHelpers.write_refactored(result, opts, &format/3)
      else
        {:ok, format(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        {:ok, format_command_error(error, parse_error_format(args)), ExitCode.for_error(error)}
    end
  end

  defp parse_opts(args),
    do:
      parse_opts(args,
        format: :human,
        root: nil,
        write?: false,
        gate_id: nil,
        description: nil,
        prompt: nil
      )

  defp parse_opts([], opts) do
    case opts[:gate_id] do
      gate_id when is_binary(gate_id) and gate_id != "" ->
        {:ok, opts}

      _missing ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "shot gate requires --id")}
    end
  end

  defp parse_opts(["--id", gate_id | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :gate_id, gate_id))

  defp parse_opts(["--description", description | rest], opts) do
    parse_opts(rest, Keyword.put(opts, :description, description))
  end

  defp parse_opts(["--prompt", prompt | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :prompt, prompt))

  defp parse_opts(["--write" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_opts(["--dry-run" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_opts(["--root", root | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :root, root))

  defp parse_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_error_format(args), do: ShotHelpers.parsed_format(args, &parse_opts/1)

  defp format(result, :json, wrote?) do
    %{
      "path" => result.path,
      "gate_id" => result.gate_id,
      "target_id" => result.target_id,
      "format" => Atom.to_string(result.format),
      "original_dependencies" => result.original_dependencies,
      "gate_dependencies" => result.gate_dependencies,
      "target_dependencies" => result.target_dependencies,
      "gate_index" => result.gate_index,
      "target_index" => result.target_index,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format(result, :human, true) do
    """
    inserted safety gate: #{result.gate_id}
    workflow: #{result.path}
    target shot: #{result.target_id}
    gate dependencies: #{ShotHelpers.empty_or_join(result.gate_dependencies)}
    target dependencies: #{Enum.join(result.target_dependencies, ", ")}
    wrote: true
    """
  end

  defp format(result, :human, false) do
    """
    dry run: shot gate #{result.target_id} with #{result.gate_id}
    workflow: #{result.path}
    gate dependencies: #{ShotHelpers.empty_or_join(result.gate_dependencies)}
    target dependencies: #{Enum.join(result.target_dependencies, ", ")}
    wrote: false

    #{result.diff}
    """
  end
end
