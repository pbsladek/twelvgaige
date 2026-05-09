defmodule Twelvgaige.CLI.Commands.ShotAdd do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.Authoring.ShotLibrary
  alias Twelvgaige.Authoring.ShotRefactor
  alias Twelvgaige.CLI.Commands.ShotHelpers
  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  def add(path, shot_id, args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, shot} <- build_shot(shot_id, opts, root),
         {:ok, result} <-
           ShotRefactor.add(path, shot,
             position: Keyword.get(opts, :position, :end),
             target_id: Keyword.get(opts, :target_id)
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
        library_paths: [],
        write?: false,
        template: nil,
        kind: nil,
        agent: nil,
        prompt: nil,
        description: nil,
        depends_on: [],
        tools: [],
        position: :end,
        target_id: nil
      )

  defp parse_opts([], opts) do
    if opts[:kind] || opts[:template] do
      {:ok, opts}
    else
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shot add requires --kind or --template"
       )}
    end
  end

  defp parse_opts(["--kind", kind | rest], opts) when kind in ["slug", "safety"] do
    parse_opts(rest, Keyword.put(opts, :kind, kind))
  end

  defp parse_opts(["--kind", _kind | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--kind must be slug or safety")}
  end

  defp parse_opts(["--agent", agent | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :agent, agent))

  defp parse_opts(["--template", template | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :template, template))

  defp parse_opts(["--prompt", prompt | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :prompt, prompt))

  defp parse_opts(["--description", description | rest], opts) do
    parse_opts(rest, Keyword.put(opts, :description, description))
  end

  defp parse_opts(["--depends-on", depends_on | rest], opts) do
    parse_opts(
      rest,
      Keyword.update!(opts, :depends_on, &(&1 ++ ShotHelpers.csv_values(depends_on)))
    )
  end

  defp parse_opts(["--tool", tool | rest], opts),
    do: parse_opts(rest, Keyword.update!(opts, :tools, &(&1 ++ [tool])))

  defp parse_opts(["--before", target_id | rest], opts),
    do: put_target(rest, opts, :before, target_id)

  defp parse_opts(["--after", target_id | rest], opts),
    do: put_target(rest, opts, :after, target_id)

  defp parse_opts(["--write" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_opts(["--dry-run" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_opts(["--root", root | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :root, root))

  defp parse_opts(["--library-path", path | rest], opts) do
    parse_opts(rest, Keyword.update!(opts, :library_paths, &(&1 ++ [path])))
  end

  defp parse_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp put_target(rest, opts, position, target_id) do
    if opts[:target_id] do
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shot add accepts exactly one --before or --after target"
       )}
    else
      opts =
        opts
        |> Keyword.put(:position, position)
        |> Keyword.put(:target_id, target_id)

      parse_opts(rest, opts)
    end
  end

  defp parse_error_format(args), do: ShotHelpers.parsed_format(args, &parse_opts/1)

  defp build_shot(shot_id, opts, root) do
    if opts[:template] do
      ShotLibrary.expand(opts[:template], shot_id,
        agent: opts[:agent],
        prompt: opts[:prompt],
        description: opts[:description],
        depends_on: opts[:depends_on],
        tools: opts[:tools],
        library_paths: opts[:library_paths],
        root: root[:root]
      )
    else
      shot =
        %{
          "id" => shot_id,
          "kind" => opts[:kind],
          "agent" => opts[:agent],
          "description" => opts[:description],
          "depends_on" => ShotHelpers.non_empty(opts[:depends_on]),
          "tools" => ShotHelpers.non_empty(opts[:tools]),
          "prompt" => opts[:prompt]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {:ok, shot}
    end
  end

  defp format(result, :json, wrote?) do
    %{
      "path" => result.path,
      "shot_id" => result.shot_id,
      "target_id" => result.target_id,
      "position" => Atom.to_string(result.position),
      "format" => Atom.to_string(result.format),
      "new_index" => result.new_index,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format(result, :human, true) do
    """
    added shot: #{result.shot_id}
    workflow: #{result.path}
    position: #{position_text(result)}
    new index: #{result.new_index}
    wrote: true
    """
  end

  defp format(result, :human, false) do
    """
    dry run: shot add #{result.shot_id}
    workflow: #{result.path}
    position: #{position_text(result)}
    new index: #{result.new_index}
    wrote: false

    #{result.diff}
    """
  end

  defp position_text(%{position: :end}), do: "end"

  defp position_text(result), do: "#{result.position} #{result.target_id}"
end
