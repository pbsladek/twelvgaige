defmodule Twelvgaige.Shell.CacheTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Cache

  test "loads configured workflow and agent shell directories" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflows/inspect.toml")
    agent_path = Path.join(root, "agents/inspector.toml")

    File.mkdir_p!(Path.dirname(workflow_path))
    File.mkdir_p!(Path.dirname(agent_path))
    File.write!(workflow_path, workflow_toml("cached_inspector"))
    File.write!(agent_path, agent_toml("cached_inspector", "cached-model"))

    cache = start_supervised!({Cache, name: nil, paths: [root]})

    assert {:ok, workflow} = Cache.get_workflow("cached_workflow", server: cache)
    assert workflow.id == "cached_workflow"

    assert {:ok, agent} = Cache.get_agent("cached_inspector", server: cache)
    assert agent.model == "cached-model"

    assert {:ok, workflow, [agent]} = Cache.workflow_with_agents("cached_workflow", server: cache)
    assert workflow.id == "cached_workflow"
    assert agent.id == "cached_inspector"

    assert {:ok, [workflow]} = Twelvgaige.list_shells(shell_cache: cache)
    assert workflow.id == "cached_workflow"

    assert {:ok, [agent]} = Twelvgaige.list_agents(shell_cache: cache)
    assert agent.id == "cached_inspector"
  end

  test "rejects duplicate configured shell ids with different definitions" do
    root = tmp_dir!()
    first_path = Path.join(root, "a.yaml")
    second_path = Path.join(root, "nested/b.toml")

    File.mkdir_p!(Path.dirname(second_path))
    File.write!(first_path, agent_yaml("dupe", "model-a"))
    File.write!(second_path, agent_toml("dupe", "model-b"))

    assert {:error, {%Twelvgaige.Error{reason: :invalid_shell} = error, _child}} =
             start_supervised({Cache, name: nil, paths: [root]})

    assert error.details.shell_id == "dupe"
  end

  test "returns definition_not_found for unknown shell ids" do
    cache = start_supervised!({Cache, name: nil, paths: []})

    assert {:error, error} = Cache.get_workflow("missing", server: cache)
    assert error.reason == :definition_not_found
    assert error.details.known_shells == []
  end

  defp tmp_dir! do
    path = Path.join(System.tmp_dir!(), "twelvgaige-cache-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp agent_yaml(agent_id, model) do
    """
    kind: agent
    id: #{agent_id}
    version: 1.0.0
    provider: mock
    model: #{model}
    system_prompt: Prompt for #{agent_id}
    """
  end

  defp workflow_toml(agent_id) do
    """
    kind = "workflow"
    id = "cached_workflow"
    version = "1.0.0"

    [[shots]]
    id = "inspect"
    kind = "slug"
    agent = "#{agent_id}"
    prompt = "inspect"
    """
  end

  defp agent_toml(agent_id, model) do
    """
    kind = "agent"
    id = "#{agent_id}"
    version = "1.0.0"
    provider = "mock"
    model = "#{model}"
    system_prompt = "Prompt for #{agent_id}"
    """
  end
end
