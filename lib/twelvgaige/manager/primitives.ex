defmodule Twelvgaige.Manager.Primitives do
  @moduledoc "Bounded, deterministic orchestration primitives over typed child results."

  alias Twelvgaige.Handoff

  def map(items, max_fanout, mapper)
      when is_list(items) and is_integer(max_fanout) and max_fanout > 0 and is_function(mapper, 2) do
    if length(items) > max_fanout,
      do: {:error, {:manager_fanout_exceeded, length(items), max_fanout}},
      else:
        {:ok,
         items |> Enum.with_index() |> Enum.map(fn {item, index} -> mapper.(item, index) end)}
  end

  def reduce(results, initial, reducer) when is_list(results) and is_function(reducer, 2) do
    ordered = Enum.sort_by(results, &result_id/1)
    {:ok, Enum.reduce(ordered, initial, reducer)}
  end

  def quorum(results, opts \\ []) when is_list(results) and results != [] do
    threshold = Keyword.get(opts, :threshold, div(length(results), 2) + 1)

    groups =
      results
      |> Enum.group_by(&canonical_result/1)
      |> Enum.map(fn {canonical, members} -> {canonical, members} end)
      |> Enum.sort_by(fn {canonical, members} -> {-length(members), canonical} end)

    case groups do
      [{_canonical, winners} | _] when length(winners) >= threshold ->
        {:ok,
         %{
           result: hd(winners),
           votes: length(winners),
           threshold: threshold,
           disagreement: length(groups) > 1
         }}

      _other ->
        {:error,
         {:manager_quorum_not_met,
          Enum.map(groups, fn {_canonical, members} -> length(members) end)}}
    end
  end

  def verify(%Handoff{} = handoff, worker_principal, verifier_principal, verifier)
      when is_function(verifier, 1) do
    if worker_principal == verifier_principal do
      {:error, :manager_verifier_not_independent}
    else
      case verifier.(handoff) do
        {:ok, evidence} ->
          {:ok, %{status: :verified, evidence: evidence, verifier: verifier_principal}}

        {:error, reason} ->
          {:error, {:manager_verification_failed, reason}}
      end
    end
  end

  def run_workflow(workflow_id, registry, input, runner) when is_function(runner, 2) do
    case fetch_workflow(registry, workflow_id) do
      {:ok, workflow} -> runner.(workflow, input)
      :error -> {:error, {:manager_workflow_unregistered, workflow_id}}
    end
  end

  defp fetch_workflow(%MapSet{} = registry, id),
    do: if(MapSet.member?(registry, id), do: {:ok, id}, else: :error)

  defp fetch_workflow(registry, id) when is_map(registry), do: Map.fetch(registry, id)

  defp fetch_workflow(registry, id) when is_list(registry),
    do: if(id in registry, do: {:ok, id}, else: :error)

  defp result_id(%{id: id}), do: to_string(id)
  defp result_id(%{"id" => id}), do: to_string(id)
  defp result_id(result), do: canonical_result(result)

  defp canonical_result(result),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(canonical(result)))
      |> Base.encode16(case: :lower)

  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {key, val} -> {to_string(key), canonical(val)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
