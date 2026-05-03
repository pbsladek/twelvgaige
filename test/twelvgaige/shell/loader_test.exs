defmodule Twelvgaige.Shell.LoaderTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Loader

  test "loads workflow YAML shell files" do
    assert {:ok, workflow} = Loader.load("test/fixtures/shells/simple_workflow.yaml")

    assert workflow.id == "simple"
    assert workflow.version == "1.0.0"
    assert Enum.map(workflow.shots, & &1.id) == ["first", "second"]
  end

  test "loads workflow JSON shell files through the same shell structs" do
    assert {:ok, yaml_workflow} = Loader.load("test/fixtures/shells/simple_workflow.yaml")
    assert {:ok, json_workflow} = Loader.load("test/fixtures/shells/simple_workflow.json")

    assert json_workflow == yaml_workflow
  end

  test "loads workflow TOML shell files through the same shell structs" do
    assert {:ok, yaml_workflow} = Loader.load("test/fixtures/shells/simple_workflow.yaml")
    assert {:ok, toml_workflow} = Loader.load("test/fixtures/shells/simple_workflow.toml")

    assert toml_workflow == yaml_workflow
  end

  test "loads agent YAML shell files" do
    assert {:ok, agent} = Loader.load("test/fixtures/shells/mock_agent.yaml")

    assert agent.id == "mock_agent"
    assert agent.provider == "mock"
    assert agent.model == "mock-model"
  end

  test "loads agent JSON shell files through the same shell structs" do
    assert {:ok, yaml_agent} = Loader.load("test/fixtures/shells/mock_agent.yaml")
    assert {:ok, json_agent} = Loader.load("test/fixtures/shells/mock_agent.json")

    assert json_agent == yaml_agent
  end

  test "loads agent TOML shell files through the same shell structs" do
    assert {:ok, yaml_agent} = Loader.load("test/fixtures/shells/mock_agent.yaml")
    assert {:ok, toml_agent} = Loader.load("test/fixtures/shells/mock_agent.toml")

    assert toml_agent == yaml_agent
  end

  test "loads explicit agent shells for a workflow path" do
    assert {:ok, [agent]} =
             Loader.load_agents_for_workflow("test/fixtures/shells/simple_workflow.yaml",
               agent_shells: ["test/fixtures/shells/mock_agent.yaml"]
             )

    assert agent.id == "mock_agent"
  end

  test "loads explicit JSON agent shells for a JSON workflow path" do
    assert {:ok, [agent]} =
             Loader.load_agents_for_workflow("test/fixtures/shells/simple_workflow.json",
               agent_shells: ["test/fixtures/shells/mock_agent.json"]
             )

    assert agent.id == "mock_agent"
  end

  test "loads explicit TOML agent shells for a TOML workflow path" do
    assert {:ok, [agent]} =
             Loader.load_agents_for_workflow("test/fixtures/shells/simple_workflow.toml",
               agent_shells: ["test/fixtures/shells/mock_agent.toml"]
             )

    assert agent.id == "mock_agent"
  end

  test "discovers agent shells from an agents directory next to the workflow" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    agents_dir = Path.join(root, "agents")
    agent_path = Path.join(agents_dir, "inspector.yaml")

    File.mkdir_p!(agents_dir)
    File.write!(workflow_path, workflow_yaml("inspector"))
    File.write!(agent_path, agent_yaml("inspector", "discovered-model"))

    assert {:ok, [agent]} = Loader.load_agents_for_workflow(workflow_path)
    assert agent.id == "inspector"
    assert agent.model == "discovered-model"
  end

  test "does not discover workflow-relative agents for untrusted roots by default" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    agents_dir = Path.join(root, "agents")
    agent_path = Path.join(agents_dir, "inspector.yaml")

    File.mkdir_p!(agents_dir)
    File.write!(workflow_path, workflow_yaml("inspector"))
    File.write!(agent_path, agent_yaml("inspector", "discovered-model"))

    assert {:ok, []} = Loader.load_agents_for_workflow(workflow_path, trusted_root?: false)
  end

  test "loads explicit agent shells even when workflow root is untrusted" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    agent_path = Path.join(root, "inspector.yaml")

    File.write!(workflow_path, workflow_yaml("inspector"))
    File.write!(agent_path, agent_yaml("inspector", "explicit-model"))

    assert {:ok, [agent]} =
             Loader.load_agents_for_workflow(workflow_path,
               trusted_root?: false,
               agent_shells: [agent_path]
             )

    assert agent.id == "inspector"
    assert agent.model == "explicit-model"
  end

  test "can explicitly allow discovery for an untrusted root" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    agents_dir = Path.join(root, "agents")
    agent_path = Path.join(agents_dir, "inspector.yaml")

    File.mkdir_p!(agents_dir)
    File.write!(workflow_path, workflow_yaml("inspector"))
    File.write!(agent_path, agent_yaml("inspector", "allowed-model"))

    assert {:ok, [agent]} =
             Loader.load_agents_for_workflow(workflow_path,
               trusted_root?: false,
               allow_untrusted_agent_discovery?: true
             )

    assert agent.model == "allowed-model"
  end

  test "discovers JSON agent shells from an agents directory next to the workflow" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.json")
    agents_dir = Path.join(root, "agents")
    agent_path = Path.join(agents_dir, "inspector.json")

    File.mkdir_p!(agents_dir)
    File.write!(workflow_path, workflow_json("inspector"))
    File.write!(agent_path, agent_json("inspector", "discovered-json-model"))

    assert {:ok, [agent]} = Loader.load_agents_for_workflow(workflow_path)
    assert agent.id == "inspector"
    assert agent.model == "discovered-json-model"
  end

  test "discovers TOML agent shells from an agents directory next to the workflow" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.toml")
    agents_dir = Path.join(root, "agents")
    agent_path = Path.join(agents_dir, "inspector.toml")

    File.mkdir_p!(agents_dir)
    File.write!(workflow_path, workflow_toml("inspector"))
    File.write!(agent_path, agent_toml("inspector", "discovered-toml-model"))

    assert {:ok, [agent]} = Loader.load_agents_for_workflow(workflow_path)
    assert agent.id == "inspector"
    assert agent.model == "discovered-toml-model"
  end

  test "discovers mixed YAML JSON and TOML agent shells" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.toml")
    agents_dir = Path.join(root, "agents")

    File.mkdir_p!(agents_dir)
    File.write!(workflow_path, workflow_toml("yaml_agent"))
    File.write!(Path.join(agents_dir, "a.yaml"), agent_yaml("yaml_agent", "model-yaml"))
    File.write!(Path.join(agents_dir, "b.json"), agent_json("json_agent", "model-json"))
    File.write!(Path.join(agents_dir, "c.toml"), agent_toml("toml_agent", "model-toml"))

    assert {:ok, agents} = Loader.load_agents_for_workflow(workflow_path)
    assert Enum.map(agents, & &1.id) == ["json_agent", "toml_agent", "yaml_agent"]
  end

  test "rejects duplicate discovered agent ids with different definitions across formats" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    agents_dir = Path.join(root, "agents")

    File.mkdir_p!(agents_dir)
    File.write!(workflow_path, workflow_yaml("inspector"))
    File.write!(Path.join(agents_dir, "a.yaml"), agent_yaml("inspector", "model-a"))
    File.write!(Path.join(agents_dir, "b.json"), agent_json("inspector", "model-b"))
    File.write!(Path.join(agents_dir, "c.toml"), agent_toml("inspector", "model-c"))

    assert {:error, error} = Loader.load_agents_for_workflow(workflow_path)
    assert error.reason == :invalid_shell
    assert error.details.agent_id == "inspector"
  end

  test "rejects unsupported shell file extensions" do
    assert {:error, error} = Loader.load("workflow.star")

    assert error.reason == :invalid_shell
    assert error.details.extension == ".star"
    assert ".json" in error.details.supported_extensions
    assert ".toml" in error.details.supported_extensions
  end

  test "rejects malformed JSON shell files" do
    path = Path.join(tmp_dir!(), "workflow.json")
    File.write!(path, ~s({"kind": "workflow",))

    assert {:error, error} = Loader.load(path)
    assert error.reason == :invalid_shell
    assert error.details.format == "json"
  end

  test "rejects JSON shell files whose top-level document is not a map" do
    path = Path.join(tmp_dir!(), "workflow.json")
    File.write!(path, ~s([{"kind": "workflow"}]))

    assert {:error, error} = Loader.load(path)
    assert error.reason == :invalid_shell
    assert error.details.format == "json"
  end

  test "rejects malformed TOML shell files" do
    path = Path.join(tmp_dir!(), "workflow.toml")
    File.write!(path, ~s(kind = "workflow"\nkind = "workflow"\n))

    assert {:error, error} = Loader.load(path)
    assert error.reason == :invalid_shell
    assert error.details.format == "toml"
  end

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-loader-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end

  defp workflow_yaml(agent_id) do
    """
    kind: workflow
    id: discovered_workflow
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: #{agent_id}
        prompt: inspect
    """
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

  defp workflow_json(agent_id) do
    Jason.encode!(%{
      "kind" => "workflow",
      "id" => "discovered_workflow",
      "version" => "1.0.0",
      "shots" => [
        %{
          "id" => "inspect",
          "kind" => "slug",
          "agent" => agent_id,
          "prompt" => "inspect"
        }
      ]
    })
  end

  defp agent_json(agent_id, model) do
    Jason.encode!(%{
      "kind" => "agent",
      "id" => agent_id,
      "version" => "1.0.0",
      "provider" => "mock",
      "model" => model,
      "system_prompt" => "Prompt for #{agent_id}"
    })
  end

  defp workflow_toml(agent_id) do
    """
    kind = "workflow"
    id = "discovered_workflow"
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
