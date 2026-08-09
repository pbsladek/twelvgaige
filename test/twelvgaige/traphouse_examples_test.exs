defmodule Twelvgaige.TraphouseExamplesTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Cache
  alias Twelvgaige.Shell.Loader

  @workflow_paths [
    "docs/traphouse/workflows/simple.yaml",
    "docs/traphouse/workflows/simple.json",
    "docs/traphouse/workflows/simple.toml"
  ]

  @agent_paths [
    "docs/traphouse/workflows/agents/local_agent.yaml",
    "docs/traphouse/workflows/agents/local_agent.json",
    "docs/traphouse/workflows/agents/local_agent.toml"
  ]

  @safety_path "docs/traphouse/workflows/safety.yaml"

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
      assert {:ok, snapshot} = Twelvgaige.run_round_sync(path, %{}, ollama_fixture_opts())

      assert snapshot.status == :complete

      assert Enum.map(snapshot.shots, &{&1.id, &1.status}) == [
               {"first", :complete},
               {"second", :complete}
             ]
    end
  end

  test "traphouse safety workflow example runs with local approval" do
    assert {:ok, workflow} = Loader.load(@safety_path)
    assert workflow.id == "safety_simple"

    assert {:ok, snapshot} =
             Twelvgaige.run_round_sync(
               @safety_path,
               %{},
               Keyword.put(ollama_fixture_opts(), :approve_all_safety?, true)
             )

    assert snapshot.status == :complete

    assert snapshot.shots |> Enum.map(&{&1.id, &1.status}) |> Enum.sort() == [
             {"after", :complete},
             {"approval", :complete}
           ]
  end

  test "shell cache accepts duplicate equivalent examples across formats" do
    cache = start_supervised!({Cache, name: nil, paths: ["docs/traphouse/workflows"]})

    assert {:ok, workflow} = Cache.get_workflow("simple", server: cache)
    assert workflow.id == "simple"

    assert {:ok, agent} = Cache.get_agent("local_agent", server: cache)
    assert agent.id == "local_agent"
  end

  defp ollama_fixture_opts do
    [
      transport: fn _request ->
        {:ok,
         %{
           status: 200,
           headers: [],
           body: %{
             "message" => %{"content" => "local fixture response"},
             "done_reason" => "stop",
             "prompt_eval_count" => 1,
             "eval_count" => 1
           }
         }}
      end
    ]
  end
end
