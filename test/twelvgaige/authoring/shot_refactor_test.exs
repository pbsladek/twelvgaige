defmodule Twelvgaige.Authoring.ShotRefactorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Authoring.ShotRefactor

  test "rename updates the target shot and dependency edges" do
    path = write_workflow!(workflow_yaml())

    assert {:ok, result} = ShotRefactor.rename(path, "gather", "inspect")

    assert result.updated_dependencies == 1
    assert result.candidate =~ ~s|id: "inspect"|
    assert result.candidate =~ "depends_on:"
    assert result.candidate =~ ~s|- "inspect"|
    refute result.candidate =~ ~s|id: "gather"|
  end

  test "rename refuses duplicate target ids" do
    path = write_workflow!(workflow_yaml())

    assert {:error, error} = ShotRefactor.rename(path, "gather", "analyze")

    assert error.reason == :invalid_shell
    assert error.message =~ "already exists"
  end

  test "rename rewrites matching condition references" do
    path =
      write_workflow!("""
      kind: workflow
      id: conditions
      version: 1.0.0
      shots:
        - id: gather
          kind: slug
          agent: mock_agent
          prompt: gather
        - id: analyze
          kind: slug
          agent: mock_agent
          condition: 'steps.gather.status == "complete"'
          prompt: analyze
      """)

    assert {:ok, result} = ShotRefactor.rename(path, "gather", "inspect")

    assert result.updated_conditions == 1
    assert result.candidate =~ ~s|condition: "shots.inspect.status == \\"complete\\""|
  end

  test "remove deletes a leaf shot" do
    path = write_workflow!(workflow_yaml())

    assert {:ok, result} = ShotRefactor.remove(path, "analyze")

    assert result.removed_ids == ["analyze"]
    assert result.dependent_ids == []
    refute result.candidate =~ ~s|id: "analyze"|
    assert result.candidate =~ ~s|id: "gather"|
  end

  test "remove refuses dependent shots without cascade confirmation" do
    path = write_workflow!(cascade_workflow_yaml())

    assert {:error, error} = ShotRefactor.remove(path, "gather")

    assert error.reason == :invalid_shell
    assert error.message =~ "--cascade --yes"
    assert error.details.dependent_ids == ["analyze", "verify"]

    assert {:error, confirm_error} = ShotRefactor.remove(path, "gather", cascade?: true)
    assert confirm_error.message =~ "requires --yes"
  end

  test "remove cascades through transitive dependents when confirmed" do
    path = write_workflow!(cascade_workflow_yaml())

    assert {:ok, result} = ShotRefactor.remove(path, "gather", cascade?: true, yes?: true)

    assert result.removed_ids == ["gather", "analyze", "verify"]
    assert result.dependent_ids == ["analyze", "verify"]
    assert result.candidate =~ ~s|id: "notify"|
    refute result.candidate =~ ~s|id: "gather"|
    refute result.candidate =~ ~s|id: "analyze"|
    refute result.candidate =~ ~s|id: "verify"|
  end

  test "remove refuses condition references left behind after removal" do
    path =
      write_workflow!("""
      kind: workflow
      id: remove_conditions
      version: 1.0.0
      shots:
        - id: gather
          kind: slug
          agent: mock_agent
          prompt: gather
        - id: analyze
          kind: slug
          agent: mock_agent
          condition: 'steps.gather.status == "complete"'
          prompt: analyze
      """)

    assert {:error, error} = ShotRefactor.remove(path, "gather")

    assert error.reason == :invalid_shell
    assert error.message =~ "condition references"
    assert error.details.condition_shots == ["analyze"]
  end

  test "move places a shot before a target without changing dependencies" do
    path = write_workflow!(cascade_workflow_yaml())

    assert {:ok, result} = ShotRefactor.move(path, "notify", :before, "analyze")

    assert result.original_index == 3
    assert result.new_index == 1
    assert Enum.map(result.workflow.shots, & &1.id) == ["gather", "notify", "analyze", "verify"]
    assert [%{depends_on: ["gather"]}] = Enum.filter(result.workflow.shots, &(&1.id == "analyze"))
  end

  test "move places a shot after a target" do
    path = write_workflow!(cascade_workflow_yaml())

    assert {:ok, result} = ShotRefactor.move(path, "gather", :after, "verify")

    assert result.original_index == 0
    assert result.new_index == 2
    assert Enum.map(result.workflow.shots, & &1.id) == ["analyze", "verify", "gather", "notify"]
  end

  test "move refuses missing targets and self moves" do
    path = write_workflow!(cascade_workflow_yaml())

    assert {:error, missing_error} = ShotRefactor.move(path, "gather", :after, "missing")
    assert missing_error.message =~ "target shot id was not found"

    assert {:error, self_error} = ShotRefactor.move(path, "gather", :after, "gather")
    assert self_error.message =~ "target must be different"
  end

  test "add appends a valid slug shot" do
    path = write_workflow!(workflow_yaml())

    shot = %{
      "id" => "verify",
      "kind" => "slug",
      "agent" => "mock_agent",
      "depends_on" => ["analyze"],
      "prompt" => "verify"
    }

    assert {:ok, result} = ShotRefactor.add(path, shot)

    assert result.new_index == 2
    assert Enum.map(result.workflow.shots, & &1.id) == ["gather", "analyze", "verify"]
    assert [%{depends_on: ["analyze"]}] = Enum.filter(result.workflow.shots, &(&1.id == "verify"))
  end

  test "add inserts before a target" do
    path = write_workflow!(workflow_yaml())

    shot = %{"id" => "prepare", "kind" => "slug", "agent" => "mock_agent", "prompt" => "prepare"}

    assert {:ok, result} = ShotRefactor.add(path, shot, position: :before, target_id: "analyze")

    assert result.new_index == 1
    assert Enum.map(result.workflow.shots, & &1.id) == ["gather", "prepare", "analyze"]
  end

  test "add refuses duplicate ids and missing position targets" do
    path = write_workflow!(workflow_yaml())
    shot = %{"id" => "gather", "kind" => "slug", "agent" => "mock_agent", "prompt" => "gather"}

    assert {:error, duplicate_error} = ShotRefactor.add(path, shot)
    assert duplicate_error.message =~ "already exists"

    missing_shot = %{
      "id" => "prepare",
      "kind" => "slug",
      "agent" => "mock_agent",
      "prompt" => "prepare"
    }

    assert {:error, missing_error} =
             ShotRefactor.add(path, missing_shot, position: :after, target_id: "missing")

    assert missing_error.message =~ "target shot id was not found"
  end

  test "gate inserts an unconditional safety shot before a target" do
    path = write_workflow!(cascade_workflow_yaml())

    assert {:ok, result} = ShotRefactor.gate(path, "verify", "approve_verify")

    assert result.original_dependencies == ["analyze"]
    assert result.gate_dependencies == ["analyze"]
    assert result.target_dependencies == ["approve_verify"]

    assert Enum.map(result.workflow.shots, & &1.id) == [
             "gather",
             "analyze",
             "approve_verify",
             "verify",
             "notify"
           ]

    assert [%{kind: :safety, depends_on: ["analyze"]}] =
             Enum.filter(result.workflow.shots, &(&1.id == "approve_verify"))

    assert [%{depends_on: ["approve_verify"]}] =
             Enum.filter(result.workflow.shots, &(&1.id == "verify"))
  end

  test "gate refuses missing targets and duplicate gate ids" do
    path = write_workflow!(cascade_workflow_yaml())

    assert {:error, missing_error} = ShotRefactor.gate(path, "missing", "approve")
    assert missing_error.message =~ "target shot id was not found"

    assert {:error, duplicate_error} = ShotRefactor.gate(path, "verify", "analyze")
    assert duplicate_error.message =~ "already exists"
  end

  test "set_schema writes a supported output schema onto a shot" do
    path = write_workflow!(workflow_yaml())

    schema = %{
      "type" => "object",
      "required" => ["status"],
      "properties" => %{
        "status" => %{"type" => "string"},
        "count" => %{"type" => "integer"}
      },
      "additionalProperties" => false
    }

    assert {:ok, result} = ShotRefactor.set_schema(path, "analyze", schema)

    assert result.previous_schema == nil
    assert result.output_schema == schema
    assert result.candidate =~ "output_schema:"

    assert [%{output_schema: %{root: ^schema}}] =
             Enum.filter(result.workflow.shots, &(&1.id == "analyze"))
  end

  test "set_schema rejects missing shots and unsupported schemas" do
    path = write_workflow!(workflow_yaml())

    assert {:error, missing_error} =
             ShotRefactor.set_schema(path, "missing", %{"type" => "object"})

    assert missing_error.message =~ "shot id was not found"

    assert {:error, schema_error} =
             ShotRefactor.set_schema(path, "analyze", %{"unsupported" => true})

    assert schema_error.reason == :unsupported_schema_keyword
  end

  test "replace_agent updates every shot using the old agent" do
    path = write_workflow!(replace_agent_workflow_yaml())

    assert {:ok, result} = ShotRefactor.replace_agent(path, "old_agent", "new_agent")

    assert result.changed_shot_ids == ["gather", "analyze"]
    assert result.candidate =~ ~s|agent: "new_agent"|
    refute result.candidate =~ ~s|agent: "old_agent"|

    assert Enum.map(result.workflow.shots, & &1.agent) == [
             "new_agent",
             "new_agent",
             "other_agent"
           ]
  end

  test "replace_agent refuses no-op and missing old agents" do
    path = write_workflow!(replace_agent_workflow_yaml())

    assert {:error, same_error} = ShotRefactor.replace_agent(path, "old_agent", "old_agent")
    assert same_error.message =~ "must be different"

    assert {:error, missing_error} = ShotRefactor.replace_agent(path, "missing", "new_agent")
    assert missing_error.message =~ "no shots reference"
  end

  test "replace_tool updates every shot using the old tool" do
    path = write_workflow!(replace_tool_workflow_yaml())

    assert {:ok, result} = ShotRefactor.replace_tool(path, "kubectl_get", "http_get")

    assert result.changed_shot_ids == ["gather", "analyze"]
    assert result.candidate =~ "http_get"
    refute result.candidate =~ "kubectl_get"

    assert Enum.map(result.workflow.shots, & &1.tools) == [
             ["http_get"],
             ["http_get", "kubectl_logs"],
             ["git_status"]
           ]
  end

  test "replace_tool refuses no-op and missing old tools" do
    path = write_workflow!(replace_tool_workflow_yaml())

    assert {:error, same_error} = ShotRefactor.replace_tool(path, "kubectl_get", "kubectl_get")
    assert same_error.message =~ "must be different"

    assert {:error, missing_error} = ShotRefactor.replace_tool(path, "missing", "http_get")
    assert missing_error.message =~ "no shots reference"
  end

  test "split replaces a slug shot with chained draft children" do
    path = write_workflow!(split_workflow_yaml())

    assert {:ok, result} =
             ShotRefactor.split(path, "analyze", ["identify_cause", "summarize_cause"])

    assert result.child_ids == ["identify_cause", "summarize_cause"]
    assert result.final_child_id == "summarize_cause"
    assert result.dependent_ids == ["verify"]
    assert result.updated_dependencies == 1
    assert result.updated_conditions == 1
    assert result.candidate =~ "Draft split 1/2 from analyze"

    assert Enum.map(result.workflow.shots, & &1.id) == [
             "gather",
             "identify_cause",
             "summarize_cause",
             "verify",
             "approval",
             "notify"
           ]

    assert [first_child] = Enum.filter(result.workflow.shots, &(&1.id == "identify_cause"))
    assert first_child.depends_on == ["gather"]
    assert first_child.output_schema == nil

    assert [final_child] = Enum.filter(result.workflow.shots, &(&1.id == "summarize_cause"))
    assert final_child.depends_on == ["identify_cause"]
    assert final_child.output_schema.root["required"] == ["summary"]

    assert [verify] = Enum.filter(result.workflow.shots, &(&1.id == "verify"))
    assert verify.depends_on == ["summarize_cause"]

    assert [notify] = Enum.filter(result.workflow.shots, &(&1.id == "notify"))
    assert notify.condition == "shots.summarize_cause.output.summary == \"ok\""
  end

  test "split rejects ambiguous child ids and unsupported source shots" do
    path = write_workflow!(split_workflow_yaml())

    assert {:error, too_few_error} = ShotRefactor.split(path, "analyze", ["only_child"])
    assert too_few_error.message =~ "at least two child ids"

    assert {:error, duplicate_error} =
             ShotRefactor.split(path, "analyze", ["identify_cause", "identify_cause"])

    assert duplicate_error.message =~ "must be unique"

    assert {:error, existing_error} = ShotRefactor.split(path, "analyze", ["gather", "new_child"])
    assert existing_error.message =~ "already exists"

    assert {:error, safety_error} =
             ShotRefactor.split(path, "approval", ["approve_a", "approve_b"])

    assert safety_error.message =~ "only supports slug"
  end

  test "merge replaces a dependency chain with one draft shot" do
    path = write_workflow!(merge_workflow_yaml())

    assert {:ok, result} =
             ShotRefactor.merge(path, ["analyze", "verify"], "analyze_and_verify")

    assert result.source_ids == ["analyze", "verify"]
    assert result.new_id == "analyze_and_verify"
    assert result.dependent_ids == ["approval", "notify", "other_agent"]
    assert result.updated_dependencies == 3
    assert result.updated_conditions == 1
    assert result.candidate =~ "Merged from source shots"

    assert Enum.map(result.workflow.shots, & &1.id) == [
             "gather",
             "analyze_and_verify",
             "approval",
             "notify",
             "other_agent"
           ]

    assert [merged] = Enum.filter(result.workflow.shots, &(&1.id == "analyze_and_verify"))
    assert merged.depends_on == ["gather"]
    assert merged.agent == "mock_agent"
    assert merged.tools == ["kubectl_get", "http_get"]
    assert merged.output_schema.root["required"] == ["summary"]
    assert merged.prompt =~ "## analyze"
    assert merged.prompt =~ "## verify"

    assert [notify] = Enum.filter(result.workflow.shots, &(&1.id == "notify"))
    assert notify.depends_on == ["analyze_and_verify"]
    assert notify.condition == "shots.analyze_and_verify.output.summary == \"ok\""
  end

  test "merge rejects unsafe or ambiguous source selections" do
    path = write_workflow!(merge_workflow_yaml())

    assert {:error, too_few_error} = ShotRefactor.merge(path, ["analyze"], "merged")
    assert too_few_error.message =~ "at least two"

    assert {:error, duplicate_error} =
             ShotRefactor.merge(path, ["analyze", "analyze"], "merged")

    assert duplicate_error.message =~ "must be unique"

    assert {:error, existing_error} = ShotRefactor.merge(path, ["analyze", "verify"], "gather")
    assert existing_error.message =~ "already exists"

    assert {:error, chain_error} = ShotRefactor.merge(path, ["gather", "notify"], "merged")
    assert chain_error.message =~ "dependency chain"

    assert {:error, agent_error} = ShotRefactor.merge(path, ["verify", "other_agent"], "merged")
    assert agent_error.message =~ "same agent"

    assert {:error, safety_error} = ShotRefactor.merge(path, ["verify", "approval"], "merged")
    assert safety_error.message =~ "only supports slug"
  end

  defp workflow_yaml do
    """
    kind: workflow
    id: rename_demo
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

  defp cascade_workflow_yaml do
    """
    kind: workflow
    id: cascade_demo
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
      - id: notify
        kind: slug
        agent: mock_agent
        prompt: notify
    """
  end

  defp replace_agent_workflow_yaml do
    """
    kind: workflow
    id: replace_agent_demo
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: old_agent
        prompt: gather
      - id: analyze
        kind: slug
        agent: old_agent
        depends_on: [gather]
        prompt: analyze
      - id: notify
        kind: slug
        agent: other_agent
        prompt: notify
    """
  end

  defp replace_tool_workflow_yaml do
    """
    kind: workflow
    id: replace_tool_demo
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: mock_agent
        tools: [kubectl_get]
        prompt: gather
      - id: analyze
        kind: slug
        agent: mock_agent
        depends_on: [gather]
        tools: [kubectl_get, kubectl_logs]
        prompt: analyze
      - id: notify
        kind: slug
        agent: mock_agent
        tools: [git_status]
        prompt: notify
    """
  end

  defp split_workflow_yaml do
    """
    kind: workflow
    id: split_demo
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
        output_schema:
          type: object
          required: [summary]
          properties:
            summary:
              type: string
      - id: verify
        kind: slug
        agent: mock_agent
        depends_on: [analyze]
        prompt: verify
      - id: approval
        kind: safety
        depends_on: [verify]
      - id: notify
        kind: slug
        agent: mock_agent
        condition: shots.analyze.output.summary == "ok"
        prompt: notify
    """
  end

  defp merge_workflow_yaml do
    """
    kind: workflow
    id: merge_demo
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
        tools: [http_get]
        prompt: verify
        output_schema:
          type: object
          required: [summary]
          properties:
            summary:
              type: string
      - id: approval
        kind: safety
        depends_on: [verify]
      - id: notify
        kind: slug
        agent: mock_agent
        depends_on: [verify]
        condition: shots.verify.output.summary == "ok"
        prompt: notify
      - id: other_agent
        kind: slug
        agent: other_agent
        depends_on: [verify]
        prompt: other
    """
  end

  defp write_workflow!(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-shot-refactor-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
