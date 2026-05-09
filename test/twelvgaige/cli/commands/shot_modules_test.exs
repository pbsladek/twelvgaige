defmodule Twelvgaige.CLI.Commands.ShotModulesTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Commands.ShotAdd
  alias Twelvgaige.CLI.Commands.ShotGate
  alias Twelvgaige.CLI.Commands.ShotReplace
  alias Twelvgaige.CLI.Commands.ShotSplitMerge
  alias Twelvgaige.CLI.Commands.ShotUpdate

  test "shot add module renders JSON dry-run output" do
    path = write_workflow!(workflow_yaml())

    assert {:ok, output, 0} =
             ShotAdd.add(path, "verify", [
               "--kind",
               "slug",
               "--agent",
               "mock_agent",
               "--prompt",
               "verify",
               "--depends-on",
               "analyze",
               "--format",
               "json"
             ])

    assert %{
             "shot_id" => "verify",
             "position" => "end",
             "wrote" => false,
             "diff" => diff
           } = Jason.decode!(output)

    assert diff =~ "+    id: \"verify\""
    refute File.read!(path) =~ "id: verify"
  end

  test "shot gate module inserts a dry-run safety gate" do
    path = write_workflow!(dependent_workflow_yaml())

    assert {:ok, output, 0} = ShotGate.gate(path, "verify", ["--id", "approve_verify"])

    assert output =~ "dry run: shot gate verify with approve_verify"
    assert output =~ "gate dependencies: analyze"
    assert output =~ "+    id: \"approve_verify\""
    refute File.read!(path) =~ "approve_verify"
  end

  test "shot update module delegates rename behavior directly" do
    path = write_workflow!(workflow_yaml())

    assert {:ok, output, 0} =
             ShotUpdate.rename(path, "gather", "inspect", ["--format", "json"])

    assert %{
             "old_id" => "gather",
             "new_id" => "inspect",
             "updated_dependencies" => 1,
             "wrote" => false
           } = Jason.decode!(output)

    assert File.read!(path) =~ "id: gather"
  end

  test "shot replace module sets output schema directly" do
    path = write_workflow!(workflow_yaml())

    schema_path =
      write_file!("schema", ".json", ~s|{"type":"object","properties":{"ok":{"type":"boolean"}}}|)

    assert {:ok, output, 0} =
             ShotReplace.set_schema(path, "analyze", schema_path, ["--format", "json"])

    assert %{
             "shot_id" => "analyze",
             "output_schema" => %{"type" => "object"},
             "wrote" => false
           } = Jason.decode!(output)
  end

  test "shot split/merge module runs contextual lint with discovered agents" do
    path =
      write_workflow_with_agents!(split_workflow_yaml(), [
        agent_yaml("mock_agent", ["kubectl_get"])
      ])

    assert {:ok, output, 0} =
             ShotSplitMerge.split(path, "analyze", [
               "--into",
               "identify_cause,summarize_cause"
             ])

    assert output =~ "dry run: shot split analyze into identify_cause, summarize_cause"
    assert output =~ "contextual lint: passed"
  end

  defp write_workflow!(contents), do: write_file!("workflow", ".yaml", contents)

  defp write_file!(prefix, extension, contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-shot-modules-#{prefix}-#{System.unique_integer([:positive])}#{extension}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write_workflow_with_agents!(workflow_contents, agent_contents) do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-shot-modules-#{System.unique_integer([:positive])}"
      )

    workflow_path = Path.join(root, "workflow.yaml")
    agents_dir = Path.join(root, "agents")

    File.mkdir_p!(agents_dir)
    File.write!(workflow_path, workflow_contents)

    Enum.each(agent_contents, fn contents ->
      id = agent_id_from_yaml!(contents)
      File.write!(Path.join(agents_dir, "#{id}.yaml"), contents)
    end)

    on_exit(fn -> File.rm_rf(root) end)
    workflow_path
  end

  defp agent_id_from_yaml!(contents) do
    case Regex.run(~r/^id:\s*([A-Za-z0-9_-]+)\s*$/m, contents) do
      [_line, id] -> id
      nil -> raise "agent fixture is missing id"
    end
  end

  defp workflow_yaml do
    """
    kind: workflow
    id: shot_modules
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: mock_agent
        prompt: gather
      - id: analyze
        kind: slug
        agent: mock_agent
        depends_on: [gather]
        prompt: analyze
    """
  end

  defp dependent_workflow_yaml do
    """
    kind: workflow
    id: shot_modules_gate
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: mock_agent
        prompt: gather
      - id: analyze
        kind: slug
        agent: mock_agent
        depends_on: [gather]
        prompt: analyze
      - id: verify
        kind: slug
        agent: mock_agent
        depends_on: [analyze]
        prompt: verify
    """
  end

  defp split_workflow_yaml do
    """
    kind: workflow
    id: shot_modules_split
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: mock_agent
        prompt: gather
      - id: analyze
        kind: slug
        agent: mock_agent
        depends_on: [gather]
        tools: [kubectl_get]
        prompt: analyze
      - id: verify
        kind: slug
        agent: mock_agent
        depends_on: [analyze]
        prompt: verify
    """
  end

  defp agent_yaml(agent_id, allowed_tools) do
    allowed =
      allowed_tools
      |> Enum.map(&"    - #{&1}")
      |> Enum.join("\n")

    """
    kind: agent
    id: #{agent_id}
    name: #{agent_id}
    version: 1.0.0
    provider: mock
    model: mock-model
    system_prompt: Run #{agent_id}.
    tools:
      allowed:
    #{allowed}
    """
  end
end
