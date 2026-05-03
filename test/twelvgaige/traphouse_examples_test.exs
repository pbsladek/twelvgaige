defmodule Twelvgaige.TraphouseExamplesTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Cache
  alias Twelvgaige.Shell.Loader

  @workflow_paths [
    "traphouse/workflows/simple.yaml",
    "traphouse/workflows/simple.json",
    "traphouse/workflows/simple.toml"
  ]

  @agent_paths [
    "traphouse/workflows/agents/mock_agent.yaml",
    "traphouse/workflows/agents/mock_agent.json",
    "traphouse/workflows/agents/mock_agent.toml"
  ]

  test "traphouse workflow examples are equivalent across supported formats" do
    workflows =
      Enum.map(@workflow_paths, fn path ->
        assert {:ok, workflow} = Loader.load(path)
        workflow
      end)

    assert Enum.uniq(workflows) |> length() == 1
  end

  test "traphouse agent examples are equivalent across supported formats" do
    agents =
      Enum.map(@agent_paths, fn path ->
        assert {:ok, agent} = Loader.load(path)
        agent
      end)

    assert Enum.uniq(agents) |> length() == 1
  end

  test "traphouse workflow examples run with adjacent agent discovery" do
    for path <- @workflow_paths do
      assert {:ok, snapshot} = Twelvgaige.run_round_sync(path, %{})

      assert snapshot.status == :complete

      assert Enum.map(snapshot.shots, &{&1.id, &1.status}) == [
               {"first", :complete},
               {"second", :complete}
             ]
    end
  end

  test "shell cache accepts duplicate equivalent examples across formats" do
    cache = start_supervised!({Cache, name: nil, paths: ["traphouse/workflows"]})

    assert {:ok, workflow} = Cache.get_workflow("simple", server: cache)
    assert workflow.id == "simple"

    assert {:ok, agent} = Cache.get_agent("mock_agent", server: cache)
    assert agent.id == "mock_agent"
  end
end
