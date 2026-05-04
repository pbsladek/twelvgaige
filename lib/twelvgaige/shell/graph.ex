defmodule Twelvgaige.Shell.Graph do
  @moduledoc """
  Pure graph extraction for workflow shells.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shell.Workflow.Shot
  alias Twelvgaige.Tool.Catalog

  @type graph_node :: %{
          id: String.t(),
          kind: atom(),
          agent: String.t() | nil,
          dependencies: [String.t()],
          dependents: [String.t()],
          tools: [String.t()],
          safety: boolean(),
          write_capable: boolean()
        }

  @type t :: %{
          workflow_id: String.t(),
          version: String.t(),
          nodes: [graph_node()],
          edges: [%{from: String.t(), to: String.t()}],
          groups: [[String.t()]]
        }

  @spec build(Workflow.t()) :: {:ok, t()} | {:error, Error.t()}
  def build(%Workflow{} = workflow) do
    with :ok <- validate_dependencies(workflow.shots),
         :ok <- validate_acyclic(workflow.shots) do
      dependents = dependents_by_id(workflow.shots)

      {:ok,
       %{
         workflow_id: workflow.id,
         version: workflow.version,
         nodes: Enum.map(workflow.shots, &node(&1, dependents)),
         edges: edges(workflow.shots),
         groups: groups(workflow.shots)
       }}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(graph) do
    %{
      workflow_id: graph.workflow_id,
      version: graph.version,
      nodes: graph.nodes,
      edges: graph.edges,
      groups: graph.groups
    }
  end

  @spec to_mermaid(t()) :: String.t()
  def to_mermaid(graph) do
    node_refs =
      graph.nodes
      |> Enum.with_index()
      |> Map.new(fn {node, index} -> {node.id, "n#{index}"} end)

    nodes =
      graph.nodes
      |> Enum.map(fn node ->
        ~s(  #{Map.fetch!(node_refs, node.id)}["#{mermaid_label(node)}"])
      end)

    edges =
      graph.edges
      |> Enum.map(fn edge ->
        "  #{Map.fetch!(node_refs, edge.from)} --> #{Map.fetch!(node_refs, edge.to)}"
      end)

    classes =
      graph.nodes
      |> Enum.flat_map(fn node ->
        ref = Map.fetch!(node_refs, node.id)

        []
        |> maybe_mermaid_class(node.safety, ref, "safety")
        |> maybe_mermaid_class(node.write_capable, ref, "write")
      end)

    [
      "flowchart TD",
      "  classDef safety fill:#fff7ed,stroke:#f97316,color:#7c2d12",
      "  classDef write fill:#fef2f2,stroke:#dc2626,color:#7f1d1d",
      Enum.join(nodes, "\n"),
      Enum.join(edges, "\n"),
      Enum.join(classes, "\n")
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp validate_dependencies(shots) do
    known = shots |> Enum.map(& &1.id) |> MapSet.new()

    Enum.reduce_while(shots, :ok, fn shot, :ok ->
      case Enum.find(shot.depends_on, &(not MapSet.member?(known, &1))) do
        nil ->
          {:cont, :ok}

        missing ->
          {:halt,
           {:error,
            Error.new(:compile_error, :missing_dependency, "shot depends on unknown shot",
              details: %{shot_id: shot.id, dependency: missing}
            )}}
      end
    end)
  end

  defp validate_acyclic(shots) do
    groups = groups(shots)
    grouped_count = groups |> List.flatten() |> length()

    if grouped_count == length(shots) do
      :ok
    else
      grouped = groups |> List.flatten() |> MapSet.new()

      remaining =
        shots
        |> Enum.map(& &1.id)
        |> Enum.reject(&MapSet.member?(grouped, &1))

      {:error,
       Error.new(:compile_error, :cycle_detected, "workflow dependency graph contains a cycle",
         details: %{remaining: remaining}
       )}
    end
  end

  defp groups(shots), do: do_groups(shots, MapSet.new(), [])

  defp do_groups(shots, complete, groups) do
    ready =
      shots
      |> Enum.reject(&MapSet.member?(complete, &1.id))
      |> Enum.filter(fn shot -> Enum.all?(shot.depends_on, &MapSet.member?(complete, &1)) end)
      |> Enum.map(& &1.id)
      |> Enum.sort()

    cond do
      ready == [] ->
        Enum.reverse(groups)

      true ->
        complete = Enum.reduce(ready, complete, &MapSet.put(&2, &1))
        do_groups(shots, complete, [ready | groups])
    end
  end

  defp node(%Shot{} = shot, dependents) do
    %{
      id: shot.id,
      kind: shot.kind,
      agent: shot.agent,
      dependencies: shot.depends_on,
      dependents: Map.get(dependents, shot.id, []),
      tools: shot.tools,
      safety: shot.kind == :safety,
      write_capable: Enum.any?(shot.tools, &write_capable_tool?/1)
    }
  end

  defp dependents_by_id(shots) do
    initial = Map.new(shots, &{&1.id, []})

    shots
    |> Enum.reduce(initial, fn shot, acc ->
      Enum.reduce(shot.depends_on, acc, fn dependency, acc ->
        Map.update(acc, dependency, [shot.id], &[shot.id | &1])
      end)
    end)
    |> Map.new(fn {id, dependents} -> {id, Enum.sort(dependents)} end)
  end

  defp edges(shots) do
    Enum.flat_map(shots, fn shot ->
      Enum.map(shot.depends_on, &%{from: &1, to: shot.id})
    end)
  end

  defp write_capable_tool?(tool) do
    case Catalog.metadata(tool) do
      {:ok, %{safety_level: :read_only}} -> false
      {:ok, %{safety_level: _level}} -> true
      {:error, _reason} -> false
    end
  end

  defp mermaid_label(node) do
    [node.id, Atom.to_string(node.kind), node.agent]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&escape_mermaid_label/1)
    |> Enum.join("<br/>")
  end

  defp escape_mermaid_label(label) do
    label
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "'")
    |> String.replace("\n", " ")
  end

  defp maybe_mermaid_class(classes, true, ref, class_name),
    do: ["  class #{ref} #{class_name}" | classes]

  defp maybe_mermaid_class(classes, false, _ref, _class_name), do: classes
end
