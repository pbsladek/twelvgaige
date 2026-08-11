defmodule Twelvgaige.CLI.CompletionCandidates do
  @moduledoc "Offline, read-only candidates for shell completion."

  alias Exqlite.Sqlite3
  alias Twelvgaige.CLI.CommandSpec
  alias Twelvgaige.Developer.Config
  alias Twelvgaige.Operations.Paths

  def list(:profile, opts), do: Config.profile_names(opts)
  def list(:session, opts), do: record_keys("session", opts)
  def list(:workspace, opts), do: record_keys("workspace_record", opts)
  def list(:command, opts), do: command(opts)
  def list(_kind, _opts), do: {:error, :completion_candidate_kind_invalid}

  defp command(opts) do
    words = Keyword.get(opts, :words, [])
    current = Keyword.get(opts, :current, "")
    path = command_path(words, [])
    children = CommandSpec.children(path)

    candidates =
      cond do
        value_option = value_option(path, List.last(words)) ->
          option_values(value_option, opts)

        children != [] and not complete_command?(path) ->
          children

        String.starts_with?(current, "-") ->
          option_candidates(path, words)

        true ->
          positional_candidates(path, current, opts) ++ option_candidates(path, words)
      end

    {:ok, filter_candidates(candidates, current)}
  end

  defp command_path([], path), do: path

  defp command_path([word | rest], path) do
    cond do
      word in ["--quiet", "--verbose", "--no-color"] ->
        command_path(rest, path)

      word == "--color" ->
        command_path(Enum.drop(rest, 1), path)

      word in CommandSpec.children(path) ->
        command_path(rest, path ++ [word])

      true ->
        path
    end
  end

  defp complete_command?([]), do: false

  defp complete_command?(path) do
    case CommandSpec.resolve(path) do
      {:ok, %CommandSpec{path: ^path}} -> true
      _other -> false
    end
  end

  defp value_option(_path, nil), do: nil

  defp value_option(path, name) do
    with {:ok, %CommandSpec{} = spec} <- CommandSpec.resolve(path),
         {:ok, option} <- CommandSpec.option(spec, name),
         false <- option.type == :boolean do
      option
    else
      _other ->
        case CommandSpec.global_option(name) do
          {:ok, option} when option.type != :boolean -> option
          _other -> nil
        end
    end
  end

  defp option_values(%{type: {:enum, values}}, _opts), do: values

  defp option_values(%{name: "--profile"}, opts) do
    opts |> Config.profile_names() |> successful_candidates()
  end

  defp option_values(_option, _opts), do: []

  defp option_candidates(path, words) do
    case CommandSpec.resolve(path) do
      {:ok, %CommandSpec{} = spec} ->
        seen = MapSet.new(Enum.filter(words, &String.starts_with?(&1, "--")))
        options = spec.options ++ CommandSpec.global_options()

        options
        |> Enum.reject(fn option ->
          (not option.repeatable? and MapSet.member?(seen, option.name)) or
            Enum.any?(option.conflicts, &MapSet.member?(seen, &1))
        end)
        |> Enum.map(& &1.name)

      _other ->
        []
    end
  end

  defp positional_candidates(["session", command], _current, opts)
       when command in ~w(show watch review retry export apply attach takeover cancel revoke) do
    record_keys("session", opts) |> successful_candidates()
  end

  defp positional_candidates(["workspace", command], _current, opts)
       when command in ~w(show path status diff export apply cleanup reconcile) do
    record_keys("workspace_record", opts) |> successful_candidates()
  end

  defp positional_candidates(_path, _current, _opts), do: []

  defp successful_candidates({:ok, candidates}), do: candidates
  defp successful_candidates({:error, _reason}), do: []

  defp filter_candidates(candidates, current) do
    candidates
    |> Enum.uniq()
    |> Enum.filter(&String.starts_with?(&1, current))
    |> Enum.sort()
  end

  defp record_keys(namespace, opts) do
    path = Keyword.get(opts, :operations_database, Paths.operations_database(opts))

    if File.regular?(path) do
      read_keys(path, namespace)
    else
      {:ok, []}
    end
  end

  defp read_keys(path, namespace) do
    with {:ok, connection} <- Sqlite3.open(Path.expand(path), mode: :readonly) do
      try do
        with {:ok, statement} <-
               Sqlite3.prepare(
                 connection,
                 "SELECT record_key FROM records WHERE namespace = ? ORDER BY record_key"
               ) do
          try do
            with :ok <- Sqlite3.bind(statement, [namespace]),
                 {:ok, rows} <- Sqlite3.fetch_all(connection, statement) do
              {:ok, Enum.map(rows, &List.first/1)}
            end
          after
            Sqlite3.release(connection, statement)
          end
        end
      after
        Sqlite3.close(connection)
      end
    else
      {:error, reason} -> {:error, {:completion_database_unavailable, reason}}
    end
  rescue
    _error -> {:error, :completion_database_invalid}
  end
end
