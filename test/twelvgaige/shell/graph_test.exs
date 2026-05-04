defmodule Twelvgaige.Shell.GraphTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Graph
  alias Twelvgaige.Shell.Loader
  alias Twelvgaige.Shell.Workflow

  test "builds deterministic dependency groups and reverse edges" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "graph_test",
        version: "1.0.0",
        shots: [
          %{id: "inspect", kind: :slug, agent: "agent", tools: ["kubectl_get"]},
          %{id: "analyze", kind: :slug, agent: "agent", depends_on: ["inspect"]},
          %{id: "approve", kind: :safety, depends_on: ["analyze"]},
          %{
            id: "apply",
            kind: :slug,
            agent: "agent",
            depends_on: ["approve"],
            tools: ["kubectl_apply"]
          }
        ]
      })

    assert {:ok, graph} = Graph.build(workflow)

    assert graph.workflow_id == "graph_test"
    assert graph.groups == [["inspect"], ["analyze"], ["approve"], ["apply"]]

    assert graph.edges == [
             %{from: "inspect", to: "analyze"},
             %{from: "analyze", to: "approve"},
             %{from: "approve", to: "apply"}
           ]

    assert [
             %{id: "inspect", dependents: ["analyze"], safety: false, write_capable: false},
             %{id: "analyze", dependents: ["approve"], safety: false, write_capable: false},
             %{id: "approve", dependents: ["apply"], safety: true, write_capable: false},
             %{id: "apply", dependents: [], safety: false, write_capable: true}
           ] = graph.nodes
  end

  test "produces equivalent graphs for YAML, JSON, and TOML workflow shells" do
    for path <- [
          "test/fixtures/shells/simple_workflow.yaml",
          "test/fixtures/shells/simple_workflow.json",
          "test/fixtures/shells/simple_workflow.toml"
        ] do
      assert {:ok, workflow} = Loader.load(path)
      assert {:ok, graph} = Graph.build(workflow)

      assert Graph.to_map(graph) == %{
               workflow_id: "simple",
               version: "1.0.0",
               nodes: [
                 %{
                   id: "first",
                   kind: :slug,
                   agent: "mock_agent",
                   dependencies: [],
                   dependents: ["second"],
                   tools: [],
                   safety: false,
                   write_capable: false
                 },
                 %{
                   id: "second",
                   kind: :slug,
                   agent: "mock_agent",
                   dependencies: ["first"],
                   dependents: [],
                   tools: [],
                   safety: false,
                   write_capable: false
                 }
               ],
               edges: [%{from: "first", to: "second"}],
               groups: [["first"], ["second"]]
             }
    end
  end

  test "renders mermaid diagrams with safety and write classes" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "mermaid_test",
        version: "1.0.0",
        shots: [
          %{id: "inspect", kind: :slug, agent: "agent", tools: ["kubectl_get"]},
          %{id: "approve", kind: :safety, depends_on: ["inspect"]},
          %{
            id: "apply",
            kind: :slug,
            agent: "agent",
            depends_on: ["approve"],
            tools: ["kubectl_apply"]
          }
        ]
      })

    assert {:ok, graph} = Graph.build(workflow)

    assert Graph.to_mermaid(graph) == """
           flowchart TD
             classDef safety fill:#fff7ed,stroke:#f97316,color:#7c2d12
             classDef write fill:#fef2f2,stroke:#dc2626,color:#7f1d1d
             n0["inspect<br/>slug<br/>agent"]
             n1["approve<br/>safety"]
             n2["apply<br/>slug<br/>agent"]
             n0 --> n1
             n1 --> n2
             class n1 safety
             class n2 write
           """
  end

  test "ignores authoring metadata when deriving runtime graph shape" do
    {:ok, without_metadata} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "metadata_ignored",
        version: "1.0.0",
        shots: [%{id: "inspect", kind: :slug, agent: "agent"}]
      })

    {:ok, with_metadata} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "metadata_ignored",
        version: "1.0.0",
        metadata: %{owner: "platform", lifecycle: "draft"},
        shots: [
          %{
            id: "inspect",
            kind: :slug,
            agent: "agent",
            metadata: %{purpose: "Metadata must not alter graph execution"}
          }
        ]
      })

    assert {:ok, left} = Graph.build(without_metadata)
    assert {:ok, right} = Graph.build(with_metadata)
    assert Graph.to_map(left) == Graph.to_map(right)
  end

  test "rejects missing dependencies" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "missing_dep",
        version: "1.0.0",
        shots: [%{id: "a", kind: :slug, agent: "agent", depends_on: ["missing"]}]
      })

    assert {:error, error} = Graph.build(workflow)
    assert error.reason == :missing_dependency
    assert error.details == %{shot_id: "a", dependency: "missing"}
  end

  test "rejects cycles" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "cycle",
        version: "1.0.0",
        shots: [
          %{id: "a", kind: :slug, agent: "agent", depends_on: ["b"]},
          %{id: "b", kind: :slug, agent: "agent", depends_on: ["a"]}
        ]
      })

    assert {:error, error} = Graph.build(workflow)
    assert error.reason == :cycle_detected
    assert Enum.sort(error.details.remaining) == ["a", "b"]
  end
end
