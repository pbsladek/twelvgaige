defmodule Twelvgaige.Authoring.ReadonlyReviewRoundTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Round.Runner
  alias Twelvgaige.Shell.Workflow

  test "read-only authoring review round emits graph, lint, and patch-plan artifacts" do
    root = tmp_dir!()
    workflow_path = Path.join([root, "workflows", "target.yaml"])
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, target_workflow_yaml())

    {:ok, review_workflow} = Workflow.from_map(review_workflow_map())

    assert {:ok, snapshot} =
             Runner.run(review_workflow, %{},
               mock_handler: authoring_handler(workflow_path),
               max_tool_calls_per_shot: 3,
               tool_opts: [root: root],
               limiter: nil
             )

    assert snapshot.status == :complete

    shots = Map.new(snapshot.shots, &{&1.id, &1.output})

    review_calls = tool_calls(shots, "review_shell")
    assert Map.has_key?(review_calls, "shell_graph")
    assert Map.has_key?(review_calls, "shell_lint")
    assert review_calls["shell_graph"].workflow_id == "target"
    assert review_calls["shell_lint"].status == "ok"

    patch_calls = tool_calls(shots, "draft_patch_plan")
    assert %{"kind" => "twelvgaige.patch_plan"} = patch_calls["patch_plan"]
    assert String.starts_with?(patch_calls["patch_plan"]["base_digest"], "sha256:")
    assert String.starts_with?(patch_calls["patch_plan"]["plan_digest"], "sha256:")
  end

  defp authoring_handler(workflow_path) do
    fn _model, messages, opts ->
      shot_id = opts |> Keyword.fetch!(:limiter_context) |> Map.fetch!(:shot_id)

      if tool_results_present?(messages) do
        final_authoring_response(shot_id)
      else
        authoring_tool_calls(shot_id, workflow_path)
      end
    end
  end

  defp tool_results_present?(messages) do
    Enum.any?(messages, &(Map.get(&1, :role) == "tool" or Map.get(&1, "role") == "tool"))
  end

  defp final_authoring_response("review_shell") do
    ~s|{"summary":"graph and lint artifacts captured","artifact_count":2}|
  end

  defp final_authoring_response("draft_patch_plan") do
    ~s|{"summary":"patch plan artifact captured","artifact_count":1}|
  end

  defp authoring_tool_calls("review_shell", workflow_path) do
    %{
      content: "collecting read-only shell artifacts",
      tool_calls: [
        %{"name" => "shell_validate", "input" => %{"path" => workflow_path}},
        %{"name" => "shell_graph", "input" => %{"path" => workflow_path}},
        %{"name" => "shell_lint", "input" => %{"path" => workflow_path, "strict" => false}}
      ]
    }
  end

  defp authoring_tool_calls("draft_patch_plan", workflow_path) do
    %{
      content: "drafting read-only patch plan",
      tool_calls: [
        %{
          "name" => "patch_plan",
          "input" => %{
            "path" => workflow_path,
            "changes" => [
              %{
                "action" => "update_prompt",
                "target" => "/shots/0/prompt",
                "description" => "Clarify the first shot prompt before a future write phase."
              }
            ]
          }
        }
      ]
    }
  end

  defp tool_calls(shots, shot_id) do
    shots
    |> Map.fetch!(shot_id)
    |> Map.fetch!("tool_calls")
    |> Map.new(&{&1["name"], &1["output"]})
  end

  defp review_workflow_map do
    %{
      kind: :workflow,
      id: "readonly_authoring_review",
      version: "1.0.0",
      shots: [
        %{
          id: "review_shell",
          kind: :slug,
          agent: "shell_architect",
          tools: ["shell_validate", "shell_graph", "shell_lint"],
          prompt: "Build read-only graph and lint artifacts.",
          output_schema: %{
            type: "object",
            required: ["summary", "artifact_count"],
            properties: %{
              summary: %{type: "string"},
              artifact_count: %{type: "integer"}
            }
          }
        },
        %{
          id: "draft_patch_plan",
          kind: :slug,
          agent: "shot_editor",
          depends_on: ["review_shell"],
          tools: ["patch_plan"],
          prompt: "Draft a read-only patch plan artifact.",
          output_schema: %{
            type: "object",
            required: ["summary", "artifact_count"],
            properties: %{
              summary: %{type: "string"},
              artifact_count: %{type: "integer"}
            }
          }
        }
      ]
    }
  end

  defp target_workflow_yaml do
    """
    kind: workflow
    id: target
    name: Target Workflow
    version: 1.0.0
    metadata:
      owner: platform
      lifecycle: draft
      tags: [authoring]
    shots:
      - id: first
        kind: slug
        agent: mock_agent
        prompt: inspect the target shell
    """
  end

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-authoring-round-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    path
  end
end
