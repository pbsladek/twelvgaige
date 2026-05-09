defmodule Twelvgaige.CLI.Commands.ShotUpdate do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.Authoring.ShotRefactor
  alias Twelvgaige.CLI.Commands.ShotHelpers
  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  def rename(path, old_id, new_id, args) do
    with {:ok, opts} <- parse_rename_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShotRefactor.rename(path, old_id, new_id) do
      if opts[:write?] do
        write_renamed(result, opts)
      else
        {:ok, format_rename(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_rename_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  def remove(path, shot_id, args) do
    with {:ok, opts} <- parse_remove_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <-
           ShotRefactor.remove(path, shot_id, cascade?: opts[:cascade?], yes?: opts[:yes?]) do
      if opts[:write?] do
        write_removed(result, opts)
      else
        {:ok, format_remove(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_remove_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  def move(path, shot_id, args) do
    with {:ok, opts} <- parse_move_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <-
           ShotRefactor.move(path, shot_id, opts[:position], opts[:target_id]) do
      if opts[:write?] do
        write_moved(result, opts)
      else
        {:ok, format_move(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_move_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp write_renamed(result, opts) do
    ShotHelpers.write_refactored(
      result,
      opts,
      &format_rename/3,
      "renamed shell did not validate as a workflow"
    )
  end

  defp write_removed(result, opts) do
    ShotHelpers.write_refactored(result, opts, &format_remove/3)
  end

  defp write_moved(result, opts) do
    ShotHelpers.write_refactored(result, opts, &format_move/3)
  end

  defp parse_rename_opts(args),
    do: parse_rename_opts(args, format: :human, root: nil, write?: false)

  defp parse_rename_opts([], opts), do: {:ok, opts}

  defp parse_rename_opts(["--write" | rest], opts) do
    parse_rename_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_rename_opts(["--dry-run" | rest], opts) do
    parse_rename_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_rename_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_rename_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_rename_opts(["--root", root | rest], opts) do
    parse_rename_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_rename_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_rename_error_format(args) do
    args
    |> parse_rename_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_remove_opts(args),
    do:
      parse_remove_opts(args,
        format: :human,
        root: nil,
        write?: false,
        cascade?: false,
        yes?: false
      )

  defp parse_remove_opts([], opts), do: {:ok, opts}

  defp parse_remove_opts(["--write" | rest], opts) do
    parse_remove_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_remove_opts(["--dry-run" | rest], opts) do
    parse_remove_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_remove_opts(["--cascade" | rest], opts) do
    parse_remove_opts(rest, Keyword.put(opts, :cascade?, true))
  end

  defp parse_remove_opts(["--yes" | rest], opts) do
    parse_remove_opts(rest, Keyword.put(opts, :yes?, true))
  end

  defp parse_remove_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_remove_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_remove_opts(["--root", root | rest], opts) do
    parse_remove_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_remove_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_remove_error_format(args) do
    args
    |> parse_remove_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_move_opts(args),
    do:
      parse_move_opts(args,
        format: :human,
        root: nil,
        write?: false,
        position: nil,
        target_id: nil
      )

  defp parse_move_opts([], opts) do
    if opts[:position] && opts[:target_id] do
      {:ok, opts}
    else
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shot move requires --before or --after"
       )}
    end
  end

  defp parse_move_opts(["--before", target_id | rest], opts),
    do: put_move_target(rest, opts, :before, target_id)

  defp parse_move_opts(["--after", target_id | rest], opts),
    do: put_move_target(rest, opts, :after, target_id)

  defp parse_move_opts(["--write" | rest], opts) do
    parse_move_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_move_opts(["--dry-run" | rest], opts) do
    parse_move_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_move_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_move_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_move_opts(["--root", root | rest], opts) do
    parse_move_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_move_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp put_move_target(rest, opts, position, target_id) do
    if opts[:position] do
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shot move accepts exactly one --before or --after target"
       )}
    else
      opts =
        opts
        |> Keyword.put(:position, position)
        |> Keyword.put(:target_id, target_id)

      parse_move_opts(rest, opts)
    end
  end

  defp parse_move_error_format(args) do
    args
    |> parse_move_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp format_rename(result, :json, wrote?) do
    %{
      "path" => result.path,
      "old_id" => result.old_id,
      "new_id" => result.new_id,
      "format" => Atom.to_string(result.format),
      "updated_dependencies" => result.updated_dependencies,
      "updated_conditions" => result.updated_conditions,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_rename(result, :human, true) do
    """
    renamed shot: #{result.old_id} -> #{result.new_id}
    workflow: #{result.path}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    wrote: true
    """
  end

  defp format_rename(result, :human, false) do
    """
    dry run: shot rename #{result.old_id} -> #{result.new_id}
    workflow: #{result.path}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    wrote: false

    #{result.diff}
    """
  end

  defp format_remove(result, :json, wrote?) do
    %{
      "path" => result.path,
      "shot_id" => result.shot_id,
      "format" => Atom.to_string(result.format),
      "removed_ids" => result.removed_ids,
      "dependent_ids" => result.dependent_ids,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_remove(result, :human, true) do
    """
    removed shot: #{result.shot_id}
    workflow: #{result.path}
    removed ids: #{Enum.join(result.removed_ids, ", ")}
    dependent ids: #{ShotHelpers.empty_or_join(result.dependent_ids)}
    wrote: true
    """
  end

  defp format_remove(result, :human, false) do
    """
    dry run: shot remove #{result.shot_id}
    workflow: #{result.path}
    removed ids: #{Enum.join(result.removed_ids, ", ")}
    dependent ids: #{ShotHelpers.empty_or_join(result.dependent_ids)}
    wrote: false

    #{result.diff}
    """
  end

  defp format_move(result, :json, wrote?) do
    %{
      "path" => result.path,
      "shot_id" => result.shot_id,
      "target_id" => result.target_id,
      "position" => Atom.to_string(result.position),
      "format" => Atom.to_string(result.format),
      "original_index" => result.original_index,
      "new_index" => result.new_index,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_move(result, :human, true) do
    """
    moved shot: #{result.shot_id} #{result.position} #{result.target_id}
    workflow: #{result.path}
    original index: #{result.original_index}
    new index: #{result.new_index}
    wrote: true
    """
  end

  defp format_move(result, :human, false) do
    """
    dry run: shot move #{result.shot_id} #{result.position} #{result.target_id}
    workflow: #{result.path}
    original index: #{result.original_index}
    new index: #{result.new_index}
    wrote: false

    #{result.diff}
    """
  end
end
