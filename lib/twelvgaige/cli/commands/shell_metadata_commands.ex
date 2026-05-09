defmodule Twelvgaige.CLI.Commands.ShellMetadataCommands do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.CLI.AuthoringIO
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell
  alias Twelvgaige.Shell.MetadataRefactor

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  @spec metadata_set(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def metadata_set(path, args) do
    with {:ok, opts} <- parse_metadata_set_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- MetadataRefactor.set(path, metadata_set_changes(opts)) do
      if opts[:write?] do
        write_metadata(result, opts)
      else
        {:ok, format_metadata(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_metadata_set_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  @spec metadata_clear(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def metadata_clear(path, args) do
    with {:ok, opts} <- parse_metadata_clear_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- MetadataRefactor.clear(path, opts[:fields]) do
      if opts[:write?] do
        write_metadata(result, opts)
      else
        {:ok, format_metadata(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_metadata_clear_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp write_metadata(result, opts) do
    with :ok <- AuthoringIO.write_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_metadata(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "metadata shell did not validate as a workflow",
            details: %{path: result.path}
          )

        AuthoringIO.format_write_error(error)

      {:error, error} ->
        AuthoringIO.format_write_error(error)
    end
  end

  defp metadata_set_changes(opts) do
    [owner: opts[:owner], lifecycle: opts[:lifecycle]]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp parse_metadata_set_opts(args),
    do:
      parse_metadata_set_opts(args,
        owner: nil,
        lifecycle: nil,
        write?: false,
        format: :human,
        root: nil
      )

  defp parse_metadata_set_opts([], opts) do
    if opts[:owner] || opts[:lifecycle] do
      {:ok, opts}
    else
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shell metadata set requires --owner or --lifecycle"
       )}
    end
  end

  defp parse_metadata_set_opts(["--owner", owner | rest], opts),
    do: parse_metadata_set_opts(rest, Keyword.put(opts, :owner, owner))

  defp parse_metadata_set_opts(["--lifecycle", lifecycle | rest], opts),
    do: parse_metadata_set_opts(rest, Keyword.put(opts, :lifecycle, lifecycle))

  defp parse_metadata_set_opts(["--write" | rest], opts),
    do: parse_metadata_set_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_metadata_set_opts(["--dry-run" | rest], opts),
    do: parse_metadata_set_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_metadata_set_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_metadata_set_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_metadata_set_opts(["--root", root | rest], opts),
    do: parse_metadata_set_opts(rest, Keyword.put(opts, :root, root))

  defp parse_metadata_set_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_metadata_set_error_format(args) do
    args
    |> parse_metadata_set_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_metadata_clear_opts(args),
    do:
      parse_metadata_clear_opts(args,
        fields: [],
        write?: false,
        format: :human,
        root: nil
      )

  defp parse_metadata_clear_opts([], opts) do
    if opts[:fields] == [] do
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shell metadata clear requires --review or --approval"
       )}
    else
      {:ok, opts}
    end
  end

  defp parse_metadata_clear_opts(["--review" | rest], opts),
    do: parse_metadata_clear_opts(rest, add_metadata_clear_field(opts, "review"))

  defp parse_metadata_clear_opts(["--approval" | rest], opts),
    do: parse_metadata_clear_opts(rest, add_metadata_clear_field(opts, "approval"))

  defp parse_metadata_clear_opts(["--write" | rest], opts),
    do: parse_metadata_clear_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_metadata_clear_opts(["--dry-run" | rest], opts),
    do: parse_metadata_clear_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_metadata_clear_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_metadata_clear_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_metadata_clear_opts(["--root", root | rest], opts),
    do: parse_metadata_clear_opts(rest, Keyword.put(opts, :root, root))

  defp parse_metadata_clear_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp add_metadata_clear_field(opts, field) do
    Keyword.update!(opts, :fields, &Enum.uniq(&1 ++ [field]))
  end

  defp parse_metadata_clear_error_format(args) do
    args
    |> parse_metadata_clear_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp format_metadata(result, :json, wrote?) do
    %{
      path: result.path,
      action: Atom.to_string(result.action),
      changed_fields: result.changed_fields,
      cleared_fields: result.cleared_fields,
      format: Atom.to_string(result.format),
      wrote: wrote?,
      diff: result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_metadata(%{action: :set} = result, :human, true) do
    """
    updated workflow metadata: #{result.path}
    changed fields: #{Enum.join(result.changed_fields, ", ")}
    wrote: true
    """
  end

  defp format_metadata(%{action: :set} = result, :human, false) do
    """
    dry run: shell metadata set #{result.path}
    changed fields: #{Enum.join(result.changed_fields, ", ")}
    wrote: false

    #{result.diff}
    """
  end

  defp format_metadata(%{action: :clear} = result, :human, true) do
    """
    cleared workflow metadata: #{result.path}
    cleared fields: #{Enum.join(result.cleared_fields, ", ")}
    wrote: true
    """
  end

  defp format_metadata(%{action: :clear} = result, :human, false) do
    """
    dry run: shell metadata clear #{result.path}
    cleared fields: #{Enum.join(result.cleared_fields, ", ")}
    wrote: false

    #{result.diff}
    """
  end
end
