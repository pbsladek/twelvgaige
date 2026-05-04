defmodule Twelvgaige.Shell.Digest do
  @moduledoc """
  Canonical shell digests for authoring review and approval bindings.

  Workflow subject digests intentionally strip embedded `review` and `approval`
  records before hashing. That lets a workflow carry its own binding records
  without making the digest self-referential.
  """

  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Shell.Workflow

  @spec workflow_subject_digest(Workflow.t()) :: String.t()
  def workflow_subject_digest(%Workflow{} = workflow) do
    workflow
    |> Document.to_map()
    |> strip_binding_records()
    |> digest_map()
  end

  @spec digest_shell(Twelvgaige.Shell.t()) :: String.t()
  def digest_shell(shell) do
    shell
    |> Document.to_map()
    |> digest_map()
  end

  @spec current_binding?(Workflow.t(), :review | :approval) :: boolean()
  def current_binding?(%Workflow{} = workflow, key) when key in [:review, :approval] do
    case binding_digest(workflow, key) do
      nil -> false
      digest -> digest == workflow_subject_digest(workflow)
    end
  end

  @spec binding_digest(Workflow.t(), :review | :approval) :: String.t() | nil
  def binding_digest(%Workflow{} = workflow, key) when key in [:review, :approval] do
    workflow.metadata
    |> Map.get(key)
    |> case do
      %{} = binding -> Map.get(binding, "workflow_digest")
      _other -> nil
    end
  end

  defp digest_map(map) do
    encoded = canonical_json(map)
    digest = :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)
    "sha256:#{digest}"
  end

  defp strip_binding_records(%{} = map) do
    map
    |> update_in_metadata(&Map.drop(&1, ["review", "approval"]))
    |> update_in_shots(fn shot ->
      update_in_metadata(shot, &Map.drop(&1, ["review", "approval"]))
    end)
  end

  defp update_in_metadata(%{"metadata" => %{} = metadata} = map, fun) do
    metadata = metadata |> fun.() |> compact()

    if metadata == %{} do
      Map.delete(map, "metadata")
    else
      Map.put(map, "metadata", metadata)
    end
  end

  defp update_in_metadata(map, _fun), do: map

  defp update_in_shots(%{"shots" => shots} = map, fun) when is_list(shots) do
    Map.put(map, "shots", Enum.map(shots, fun))
  end

  defp update_in_shots(map, _fun), do: map

  defp canonical_json(value) when is_map(value) do
    pairs =
      value
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_json(value)
      end)

    "{" <> Enum.join(pairs, ",") <> "}"
  end

  defp canonical_json(value) when is_list(value) do
    "[" <> (value |> Enum.map(&canonical_json/1) |> Enum.join(",")) <> "]"
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp compact(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = compact(value)

      if value == nil or value == %{} do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(value), do: value
end
