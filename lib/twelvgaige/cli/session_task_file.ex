defmodule Twelvgaige.CLI.SessionTaskFile do
  @moduledoc "Loads closed-schema Markdown and YAML inputs for `session start`."

  alias Twelvgaige.Shell.Format.YAML

  @max_bytes 1_048_576
  @top_level_fields ~w(
    version task objective runtime repository repo base_ref auth_profile sandbox network
    allow_unrestricted_network allowed_paths write timeout timeout_ms budget
  )
  @budget_fields ~w(tokens cost_micros time_ms tool_calls)

  @spec load(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def load(path, opts \\ [])

  def load(path, opts) when is_binary(path) do
    path = Path.expand(path)
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)

    with {:ok, stat} <- File.stat(path),
         :ok <- regular_file(stat),
         :ok <- within_limit(stat.size, max_bytes),
         {:ok, contents} <- File.read(path) do
      parse(path, contents)
    else
      {:error, :enoent} -> {:error, {:session_task_file_not_found, path}}
      {:error, reason} -> {:error, reason}
    end
  end

  def load(_path, _opts), do: {:error, :session_task_file_invalid}

  defp parse(path, contents) do
    case path |> Path.extname() |> String.downcase() do
      extension when extension in [".md", ".markdown"] -> parse_markdown(contents)
      extension when extension in [".yaml", ".yml"] -> parse_yaml(path, contents)
      extension -> {:error, {:session_task_file_extension_unsupported, extension}}
    end
  end

  defp parse_markdown(contents) do
    case String.trim(contents) do
      "" -> {:error, :session_task_file_empty}
      objective -> {:ok, %{task: objective}}
    end
  end

  defp parse_yaml(path, contents) do
    with {:ok, document} <- YAML.parse(contents, path),
         :ok <- known_fields(document, @top_level_fields, :session_task_file_unknown_fields),
         :ok <- version(document),
         {:ok, objective} <- one_alias(document, "task", "objective"),
         {:ok, repository} <- one_alias(document, "repository", "repo"),
         {:ok, timeout_ms} <- timeout(document),
         {:ok, budget} <- budget(Map.get(document, "budget")),
         {:ok, values} <- yaml_values(document, objective, repository, timeout_ms, budget, path) do
      {:ok, values}
    else
      {:error, %Twelvgaige.Error{} = error} ->
        {:error, {:session_task_file_yaml_invalid, error.message}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp yaml_values(document, objective, repository, timeout_ms, budget, path) do
    values =
      %{}
      |> put_present(:task, objective)
      |> put_present(:runtime, Map.get(document, "runtime"))
      |> put_present(:repository, resolve_repository(repository, path))
      |> put_present(:base_ref, Map.get(document, "base_ref"))
      |> put_present(:auth_profile, Map.get(document, "auth_profile"))
      |> put_present(:sandbox, Map.get(document, "sandbox"))
      |> put_present(:network, Map.get(document, "network"))
      |> put_present(
        :allow_unrestricted_network?,
        Map.get(document, "allow_unrestricted_network")
      )
      |> put_present(:allowed_paths, Map.get(document, "allowed_paths"))
      |> put_present(:write?, Map.get(document, "write"))
      |> put_present(:timeout_ms, timeout_ms)
      |> Map.merge(budget)
      |> inherit_budget_time(timeout_ms)

    with :ok <- optional_string(values, [:task, :runtime, :repository, :base_ref, :auth_profile]),
         :ok <- optional_enum(values, :sandbox, ["podman", "apple-container"]),
         :ok <- optional_enum(values, :network, ["none", "broker-only", "unrestricted"]),
         :ok <- optional_boolean(values, :allow_unrestricted_network?),
         :ok <- optional_boolean(values, :write?),
         :ok <- allowed_paths(values),
         :ok <- non_negative_integers(values) do
      {:ok, values}
    end
  end

  defp known_fields(map, allowed, error) when is_map(map) do
    unknown = map |> Map.keys() |> Enum.reject(&Enum.member?(allowed, &1)) |> Enum.sort()
    if unknown == [], do: :ok, else: {:error, {error, unknown}}
  end

  defp version(document) do
    case Map.get(document, "version", 1) do
      1 -> :ok
      value -> {:error, {:session_task_file_version_unsupported, value}}
    end
  end

  defp one_alias(document, primary, alias_name) do
    case {Map.get(document, primary), Map.get(document, alias_name)} do
      {nil, nil} -> {:ok, nil}
      {value, nil} -> {:ok, value}
      {nil, value} -> {:ok, value}
      {_primary, _alias} -> {:error, {:session_task_file_conflicting_fields, primary, alias_name}}
    end
  end

  defp timeout(document) do
    case {Map.get(document, "timeout"), Map.get(document, "timeout_ms")} do
      {nil, nil} ->
        {:ok, nil}

      {value, nil} ->
        parse_duration(value)

      {nil, value} when is_integer(value) and value > 0 ->
        {:ok, value}

      {nil, _value} ->
        {:error, :session_task_file_timeout_invalid}

      {_duration, _milliseconds} ->
        {:error, {:session_task_file_conflicting_fields, "timeout", "timeout_ms"}}
    end
  end

  defp parse_duration(value) when is_binary(value) do
    case Regex.run(~r/^(\d+)(ms|s|m|h)$/, value, capture: :all_but_first) do
      [amount, unit] ->
        multiplier = %{"ms" => 1, "s" => 1_000, "m" => 60_000, "h" => 3_600_000}[unit]
        milliseconds = String.to_integer(amount) * multiplier

        if milliseconds > 0,
          do: {:ok, milliseconds},
          else: {:error, :session_task_file_timeout_invalid}

      _other ->
        {:error, :session_task_file_timeout_invalid}
    end
  end

  defp parse_duration(_value), do: {:error, :session_task_file_timeout_invalid}

  defp budget(nil), do: {:ok, %{}}

  defp budget(value) when is_map(value) do
    with :ok <- known_fields(value, @budget_fields, :session_task_file_budget_unknown_fields) do
      {:ok,
       %{}
       |> put_present(:budget_tokens, Map.get(value, "tokens"))
       |> put_present(:budget_cost_micros, Map.get(value, "cost_micros"))
       |> put_present(:budget_time_ms, Map.get(value, "time_ms"))
       |> put_present(:budget_tool_calls, Map.get(value, "tool_calls"))}
    end
  end

  defp budget(_value), do: {:error, :session_task_file_budget_invalid}

  defp optional_string(values, keys) do
    invalid =
      Enum.find(keys, fn key -> Map.has_key?(values, key) and not present?(values[key]) end)

    if invalid, do: {:error, {:session_task_file_field_invalid, invalid}}, else: :ok
  end

  defp optional_enum(values, key, allowed) do
    case Map.fetch(values, key) do
      :error ->
        :ok

      {:ok, value} ->
        if value in allowed,
          do: :ok,
          else: {:error, {:session_task_file_field_invalid, key}}
    end
  end

  defp optional_boolean(values, key) do
    case Map.fetch(values, key) do
      :error -> :ok
      {:ok, value} when is_boolean(value) -> :ok
      {:ok, _value} -> {:error, {:session_task_file_field_invalid, key}}
    end
  end

  defp allowed_paths(values) do
    case Map.fetch(values, :allowed_paths) do
      :error ->
        :ok

      {:ok, paths} when is_list(paths) ->
        if Enum.all?(paths, &present?/1),
          do: :ok,
          else: {:error, {:session_task_file_field_invalid, :allowed_paths}}

      {:ok, _value} ->
        {:error, {:session_task_file_field_invalid, :allowed_paths}}
    end
  end

  defp non_negative_integers(values) do
    keys = [:budget_tokens, :budget_cost_micros, :budget_time_ms, :budget_tool_calls]

    invalid =
      Enum.find(keys, fn key ->
        Map.has_key?(values, key) and (not is_integer(values[key]) or values[key] < 0)
      end)

    if invalid, do: {:error, {:session_task_file_field_invalid, invalid}}, else: :ok
  end

  defp resolve_repository(nil, _path), do: nil

  defp resolve_repository(repository, path) when is_binary(repository) do
    if Path.type(repository) == :absolute,
      do: Path.expand(repository),
      else: path |> Path.dirname() |> Path.join(repository) |> Path.expand()
  end

  defp resolve_repository(repository, _path), do: repository

  defp inherit_budget_time(values, nil), do: values

  defp inherit_budget_time(values, timeout_ms),
    do: Map.put_new(values, :budget_time_ms, timeout_ms)

  defp regular_file(%File.Stat{type: :regular}), do: :ok
  defp regular_file(_stat), do: {:error, :session_task_file_not_regular}

  defp within_limit(size, max_bytes) when size <= max_bytes, do: :ok
  defp within_limit(_size, _max_bytes), do: {:error, :session_task_file_too_large}

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
