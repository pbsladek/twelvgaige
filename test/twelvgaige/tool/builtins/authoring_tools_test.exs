defmodule Twelvgaige.Tool.Builtins.AuthoringToolsTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Executor
  alias Twelvgaige.Tool.Builtins.Authoring.Common

  @authoring_tools ~w(
    shell_validate
    shell_graph
    shell_lint
    shell_inventory
    shell_impact
    shell_normalize
    shell_diff
    tool_catalog_read
    patch_plan
  )

  test "authoring tools are read-only and executable through the tool executor" do
    root = write_collection!()
    workflow_path = "workflows/simple.yaml"
    changed_path = "workflows/changed.yaml"

    cases = [
      {"shell_validate", %{"path" => workflow_path}, &assert_validated/1},
      {"shell_graph", %{"path" => workflow_path}, &assert_graph/1},
      {"shell_lint", %{"path" => workflow_path, "strict" => true}, &assert_lint/1},
      {"shell_inventory", %{"path" => "."}, &assert_inventory/1},
      {"shell_impact",
       %{"path" => ".", "selector_kind" => "agent", "selector_value" => "mock_agent"},
       &assert_impact/1},
      {"shell_normalize", %{"path" => workflow_path, "format" => "map"}, &assert_normalized/1},
      {"shell_diff", %{"left_path" => workflow_path, "right_path" => changed_path},
       &assert_diff/1},
      {"tool_catalog_read", %{"name" => "shell_graph"}, &assert_tool_catalog/1},
      {"patch_plan",
       %{
         "path" => workflow_path,
         "changes" => [
           %{
             "action" => "update_prompt",
             "target" => "first",
             "description" => "Clarify first shot"
           }
         ]
       }, &assert_patch_plan/1}
    ]

    for {tool, input, assertion} <- cases do
      assert {:ok, output} =
               Executor.execute(tool, input,
                 allowed_tools: @authoring_tools,
                 max_safety: :read_only,
                 limiter: nil,
                 tool_opts: [root: root],
                 max_output_bytes: 512 * 1024
               )

      assertion.(output)
    end
  end

  test "authoring tools deny paths outside the configured root" do
    root = write_collection!()
    outside = Path.join(System.tmp_dir!(), "twelvgaige-authoring-outside.yaml")
    File.write!(outside, workflow_yaml("outside"))
    on_exit(fn -> File.rm(outside) end)

    assert {:error, error} =
             Executor.execute("shell_validate", %{"path" => outside},
               allowed_tools: ["shell_validate"],
               max_safety: :read_only,
               limiter: nil,
               tool_opts: [root: root]
             )

    assert error.reason == :tool_denied
  end

  test "authoring tools deny symlink escapes below the configured root" do
    root = write_collection!()
    outside_root = tmp_dir!("twelvgaige-authoring-outside")
    outside = Path.join(outside_root, "outside.yaml")
    File.write!(outside, workflow_yaml("outside"))

    link = Path.join(root, "workflows/linked.yaml")
    File.ln_s!(outside, link)

    assert {:error, error} =
             Executor.execute("shell_validate", %{"path" => "workflows/linked.yaml"},
               allowed_tools: ["shell_validate"],
               max_safety: :read_only,
               limiter: nil,
               tool_opts: [root: root]
             )

    assert error.reason == :tool_denied
  end

  test "authoring common lookups preserve false and avoid creating atoms" do
    assert Common.optional_boolean(%{"strict" => false}, "strict", true) == false

    field = "field_#{System.unique_integer([:positive, :monotonic])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
    assert {:ok, "value"} = Common.fetch_string(%{field => "value"}, field)
    assert_raise ArgumentError, fn -> String.to_existing_atom(field) end
  end

  defp assert_validated(output) do
    assert output["kind"] == "workflow"
    assert output["id"] == "simple"
  end

  defp assert_graph(output) do
    assert output.workflow_id == "simple"
    assert output.groups == [["first"], ["second"]]
  end

  defp assert_lint(output) do
    assert output.status == "ok"
    assert Enum.any?(output.findings, &(&1.id == "metadata.owner.missing"))
  end

  defp assert_inventory(output) do
    assert output.status == "ok"
    assert output.summary["workflow_count"] == 2
    assert output.summary["agent_count"] == 1
  end

  defp assert_impact(output) do
    assert output.selector == %{"kind" => "agent", "value" => "mock_agent"}
    assert output.summary["workflow_count"] == 2
  end

  defp assert_normalized(output) do
    assert output["format"] == "map"
    assert output["document"]["id"] == "simple"
  end

  defp assert_diff(output) do
    refute output["equal"]
    assert "id" in output["changed_top_level_keys"]
  end

  defp assert_tool_catalog(output) do
    assert output["tool"]["name"] == "shell_graph"
    assert output["tool"]["safety_level"] == "read_only"
  end

  defp assert_patch_plan(output) do
    assert output["kind"] == "twelvgaige.patch_plan"
    assert output["base_digest"] =~ "sha256:"
    assert output["plan_digest"] =~ "sha256:"
  end

  defp write_collection! do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-authoring-tools-#{System.unique_integer([:positive, :monotonic])}"
      )

    workflow_dir = Path.join(root, "workflows")
    agent_dir = Path.join(workflow_dir, "agents")
    File.mkdir_p!(agent_dir)
    File.write!(Path.join(workflow_dir, "simple.yaml"), workflow_yaml("simple"))
    File.write!(Path.join(workflow_dir, "changed.yaml"), workflow_yaml("changed"))
    File.write!(Path.join(agent_dir, "mock_agent.yaml"), agent_yaml())
    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp workflow_yaml(id) do
    """
    kind: workflow
    id: #{id}
    version: 1.0.0
    shots:
      - id: first
        kind: slug
        agent: mock_agent
        timeout: 1s
        output_schema:
          type: object
          properties:
            ok:
              type: boolean
      - id: second
        kind: slug
        agent: mock_agent
        depends_on: [first]
        timeout: 1s
        output_schema:
          type: object
          properties:
            ok:
              type: boolean
    """
  end

  defp agent_yaml do
    """
    kind: agent
    id: mock_agent
    version: 1.0.0
    provider: mock
    model: mock-model
    system_prompt: Test authoring tool agent.
    """
  end
end
