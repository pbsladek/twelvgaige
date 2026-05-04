defmodule Twelvgaige.Shell.MetadataRefactor do
  @moduledoc """
  Raw workflow metadata maintenance for authoring commands.

  This module intentionally does not create digest-bound review or approval
  bindings. Use `Twelvgaige.Shell.Lifecycle` for review/approval semantics.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Shell.Workflow

  @lifecycles ~w(draft reviewed approved scheduled deprecated retired)

  @type result :: %{
          path: Path.t(),
          action: :set | :clear,
          changed_fields: [String.t()],
          cleared_fields: [String.t()],
          format: Document.format(),
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @spec set(Path.t(), keyword(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def set(path, changes, opts \\ [])

  def set(path, changes, opts) when is_binary(path) and is_list(changes) do
    with {:ok, change_map} <- normalize_set_changes(changes),
         {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = Document.to_map(workflow),
         candidate_document <- put_metadata(document, change_map),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- Document.encode(workflow, format),
         {:ok, candidate} <- Document.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         action: :set,
         changed_fields: Map.keys(change_map),
         cleared_fields: [],
         format: format,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shell metadata set requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def set(_path, _changes, _opts), do: invalid("shell metadata set requires a path and changes")

  @spec clear(Path.t(), [atom() | String.t()], keyword()) :: {:ok, result()} | {:error, Error.t()}
  def clear(path, fields, opts \\ [])

  def clear(path, fields, opts) when is_binary(path) and is_list(fields) do
    with {:ok, fields} <- normalize_clear_fields(fields),
         {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = Document.to_map(workflow),
         candidate_document <- clear_metadata(document, fields),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- Document.encode(workflow, format),
         {:ok, candidate} <- Document.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         action: :clear,
         changed_fields: [],
         cleared_fields: fields,
         format: format,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shell metadata clear requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def clear(_path, _fields, _opts), do: invalid("shell metadata clear requires path and fields")

  defp normalize_set_changes(changes) do
    changes
    |> Enum.reduce_while({:ok, %{}}, fn
      {:owner, owner}, {:ok, acc} ->
        case non_empty_string(owner, "--owner must be non-empty") do
          {:ok, owner} -> {:cont, {:ok, Map.put(acc, "owner", owner)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      {:lifecycle, lifecycle}, {:ok, acc} ->
        case normalize_lifecycle(lifecycle) do
          {:ok, lifecycle} -> {:cont, {:ok, Map.put(acc, "lifecycle", lifecycle)}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end

      {_key, nil}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      {key, _value}, {:ok, _acc} ->
        {:halt, invalid("unsupported metadata field", %{field: to_string(key)})}
    end)
    |> case do
      {:ok, changes} when map_size(changes) > 0 ->
        {:ok, changes}

      {:ok, _changes} ->
        invalid("shell metadata set requires at least one field")

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp non_empty_string(value, _message) when is_binary(value) and value != "", do: {:ok, value}
  defp non_empty_string(_value, message), do: invalid(message)

  defp normalize_lifecycle(lifecycle) when lifecycle in @lifecycles, do: {:ok, lifecycle}

  defp normalize_lifecycle(lifecycle) when is_atom(lifecycle),
    do: normalize_lifecycle(to_string(lifecycle))

  defp normalize_lifecycle(_lifecycle) do
    invalid(
      "metadata lifecycle must be draft, reviewed, approved, scheduled, deprecated, or retired"
    )
  end

  defp normalize_clear_fields(fields) do
    fields =
      fields
      |> Enum.map(&to_string/1)
      |> Enum.uniq()

    cond do
      fields == [] ->
        invalid("shell metadata clear requires at least one field")

      Enum.any?(fields, &(&1 not in ["review", "approval"])) ->
        invalid("shell metadata clear supports only review and approval bindings")

      true ->
        {:ok, fields}
    end
  end

  defp put_metadata(document, changes) do
    document
    |> Map.update("metadata", changes, &Map.merge(&1, changes))
    |> compact()
  end

  defp clear_metadata(document, fields) do
    document
    |> Map.update("metadata", %{}, fn metadata ->
      Enum.reduce(fields, metadata, &Map.delete(&2, &1))
    end)
    |> compact()
  end

  defp format_for_path(path) do
    case path |> Path.extname() |> String.downcase() do
      ".json" ->
        {:ok, :json}

      ".toml" ->
        {:ok, :toml}

      ".yaml" ->
        {:ok, :yaml}

      ".yml" ->
        {:ok, :yaml}

      extension ->
        invalid("unsupported shell file extension for metadata update", %{extension: extension})
    end
  end

  defp compact(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = compact(value)

      if value in [nil, %{}, []] do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(value), do: value

  defp unified_diff(path, original, candidate) do
    original_lines = String.split(original, "\n", trim: false)
    candidate_lines = String.split(candidate, "\n", trim: false)
    max = max(length(original_lines), length(candidate_lines))

    body =
      0..(max - 1)
      |> Enum.flat_map(fn index ->
        old = Enum.at(original_lines, index)
        new = Enum.at(candidate_lines, index)

        cond do
          old == new and not is_nil(old) -> [" #{old}"]
          is_nil(old) -> ["+#{new}"]
          is_nil(new) -> ["-#{old}"]
          true -> ["-#{old}", "+#{new}"]
        end
      end)
      |> Enum.reject(&(&1 in [" ", "+", "-"]))
      |> Enum.join("\n")

    """
    --- #{path}
    +++ #{path}
    @@
    #{body}
    """
  end

  defp invalid(message, details \\ %{}) do
    {:error, Error.new(:input_error, :invalid_shell, message, details: details)}
  end
end
