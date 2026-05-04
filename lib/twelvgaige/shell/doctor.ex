defmodule Twelvgaige.Shell.Doctor do
  @moduledoc """
  Read-only workflow diagnostics with repair-oriented recommendations.

  Doctor is advisory. It does not mutate shell files and does not require the
  daemon. It combines graph and lint data into concrete next actions for humans
  and CI reports.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Graph
  alias Twelvgaige.Shell.Lint
  alias Twelvgaige.Shell.Workflow

  @type recommendation :: %{
          id: String.t(),
          severity: :info | :warning | :error,
          class: :workflow | :shot,
          shot_id: String.t() | nil,
          message: String.t(),
          action: String.t(),
          source: String.t(),
          details: map()
        }

  @type report :: %{
          path: Path.t(),
          workflow_id: String.t(),
          version: String.t(),
          status: :ok | :attention | :failed,
          exit_code: 0 | 1,
          lint: Lint.report(),
          graph: Graph.t() | nil,
          recommendations: [recommendation()],
          errors: [map()]
        }

  @spec run(Workflow.t(), keyword()) :: report()
  def run(%Workflow{} = workflow, opts \\ []) do
    path = Keyword.get(opts, :path, "<memory>")
    strict? = Keyword.get(opts, :strict?, false)
    lint = Lint.run(workflow, path: path, strict?: strict?)
    graph_result = Graph.build(workflow)

    graph_recommendations =
      case graph_result do
        {:ok, graph} -> graph_recommendations(graph)
        {:error, _error} -> []
      end

    recommendations =
      lint.findings
      |> Enum.map(&recommendation_for_finding/1)
      |> Kernel.++(graph_recommendations)
      |> Enum.sort_by(&{severity_rank(&1.severity), &1.id, &1.shot_id || ""})

    errors =
      case graph_result do
        {:ok, _graph} -> []
        {:error, %Error{} = error} -> [Error.to_map(error)]
      end

    status = status(lint, recommendations, errors)

    %{
      path: path,
      workflow_id: workflow.id,
      version: workflow.version,
      status: status,
      exit_code: if(status == :failed, do: 1, else: 0),
      lint: lint,
      graph: graph_value(graph_result),
      recommendations: recommendations,
      errors: errors
    }
  end

  @spec to_map(report()) :: map()
  def to_map(report) do
    %{
      path: report.path,
      workflow_id: report.workflow_id,
      version: report.version,
      status: Atom.to_string(report.status),
      exit_code: report.exit_code,
      lint: Lint.to_map(report.lint),
      graph: graph_map(report.graph),
      recommendations: Enum.map(report.recommendations, &recommendation_to_map/1),
      errors: report.errors
    }
  end

  defp recommendation_for_finding(%{id: id} = finding) do
    {message, action} = finding_guidance(finding)

    %{
      id: id,
      severity: finding.severity,
      class: finding.class,
      shot_id: Map.get(finding.location, :shot_id),
      message: message,
      action: action,
      source: "lint",
      details: finding.details
    }
  end

  defp finding_guidance(%{id: "metadata.owner.missing"}) do
    {
      "workflow metadata owner is missing",
      "Add metadata.owner so review, inventory, and escalation reports have an accountable team."
    }
  end

  defp finding_guidance(%{id: "metadata.generated.unreviewed"}) do
    {
      "generated workflow has not been reviewed",
      "Review the generated shell, then bind approval metadata or move lifecycle out of draft."
    }
  end

  defp finding_guidance(%{id: "approval.digest.missing"}) do
    {
      "approved or scheduled workflow is missing a current approval digest",
      "Re-run the approval flow so metadata.approval.workflow_digest matches the canonical workflow."
    }
  end

  defp finding_guidance(%{id: "approval.digest.stale"}) do
    {
      "approval digest is stale",
      "Treat the shell as changed after approval and require a fresh review before scheduling."
    }
  end

  defp finding_guidance(%{id: "shot.id.generic", location: %{shot_id: shot_id}}) do
    {
      "shot id is too generic",
      "Rename #{shot_id} to describe the operation or evidence it produces."
    }
  end

  defp finding_guidance(%{id: "shot.output_schema.missing", location: %{shot_id: shot_id}}) do
    {
      "slug shot is missing an output schema",
      "Add output_schema to #{shot_id} so downstream shots receive bounded structured data."
    }
  end

  defp finding_guidance(%{id: "shot.timeout.missing", location: %{shot_id: shot_id}}) do
    {
      "slug shot is missing an explicit timeout",
      "Add timeout to #{shot_id} so stuck LLM or tool calls cannot hold the round indefinitely."
    }
  end

  defp finding_guidance(%{id: "shot.safety.write_without_gate", location: %{shot_id: shot_id}}) do
    {
      "write-capable shot is missing a direct safety dependency",
      "Add a safety shot and make #{shot_id} depend on it before any write-capable tool can run."
    }
  end

  defp finding_guidance(%{id: "shot.tool.unknown", location: %{shot_id: shot_id}}) do
    {
      "shot references unknown tools",
      "Replace unknown tools in #{shot_id} with catalog tools or implement and register the tool first."
    }
  end

  defp finding_guidance(%{id: "workflow.graph.invalid"}) do
    {
      "workflow graph is invalid",
      "Fix missing dependencies or cycles before running, refactoring, or scheduling the workflow."
    }
  end

  defp finding_guidance(finding), do: {finding.message, "Review and resolve this lint finding."}

  defp graph_recommendations(graph) do
    root_count = graph.groups |> List.first([]) |> length()

    []
    |> maybe_parallel_recommendation(graph, root_count)
    |> maybe_empty_edges_recommendation(graph)
  end

  defp maybe_parallel_recommendation(recommendations, graph, root_count) when root_count > 4 do
    [
      %{
        id: "graph.roots.high_parallelism",
        severity: :info,
        class: :workflow,
        shot_id: nil,
        message: "workflow has many root shots",
        action:
          "Review resource profile and provider concurrency before running #{root_count} root shots in parallel.",
        source: "graph",
        details: %{root_count: root_count, groups: graph.groups}
      }
      | recommendations
    ]
  end

  defp maybe_parallel_recommendation(recommendations, _graph, _root_count), do: recommendations

  defp maybe_empty_edges_recommendation(recommendations, %{edges: [], nodes: nodes})
       when length(nodes) > 1 do
    [
      %{
        id: "graph.dependencies.none",
        severity: :info,
        class: :workflow,
        shot_id: nil,
        message: "workflow has multiple independent shots",
        action:
          "Confirm these shots are intentionally parallel; add depends_on edges when outputs must flow between shots.",
        source: "graph",
        details: %{shot_count: length(nodes)}
      }
      | recommendations
    ]
  end

  defp maybe_empty_edges_recommendation(recommendations, _graph), do: recommendations

  defp status(_lint, _recommendations, [_error | _rest]), do: :failed
  defp status(%{status: :failed}, _recommendations, []), do: :failed
  defp status(_lint, [], []), do: :ok
  defp status(_lint, _recommendations, []), do: :attention

  defp graph_value({:ok, graph}), do: graph
  defp graph_value({:error, _error}), do: nil

  defp graph_map(nil), do: nil
  defp graph_map(graph), do: Graph.to_map(graph)

  defp recommendation_to_map(recommendation) do
    %{
      id: recommendation.id,
      severity: Atom.to_string(recommendation.severity),
      class: Atom.to_string(recommendation.class),
      shot_id: recommendation.shot_id,
      message: recommendation.message,
      action: recommendation.action,
      source: recommendation.source,
      details: recommendation.details
    }
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1
  defp severity_rank(:info), do: 2
end
