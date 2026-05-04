defmodule Twelvgaige.Authoring.ShellDraftTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Authoring.Scaffold
  alias Twelvgaige.Authoring.ShellDraft
  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Shell.Loader

  test "drafts a validated workflow through the mock provider" do
    assert {:ok, report} = ShellDraft.draft("build a simple review workflow")

    assert report.provider == "mock"
    assert report.model == "mock-model"
    assert report.status == :ok
    assert report.exit_code == 0
    assert report.workflow.id == "drafted_workflow"
    assert report.candidate =~ ~s(kind: "workflow")
  end

  test "rejects hosted providers unless remote drafting is explicit" do
    assert {:error, error} =
             ShellDraft.draft("draft with a hosted provider",
               provider: "openai",
               model: "gpt-test"
             )

    assert error.class == :policy_error
    assert error.reason == :policy_denied
    assert error.message =~ "--allow-remote"
  end

  test "bounds draft input size" do
    assert {:error, error} =
             ShellDraft.draft(String.duplicate("x", 16), max_input_bytes: 4)

    assert error.reason == :llm_context_too_large
    assert error.details.bytes == 16
    assert error.details.max_input_bytes == 4
  end

  test "redacts source text before provider transport" do
    parent = self()

    handler = fn _model, messages, _opts ->
      send(parent, {:draft_messages, messages})
      {:ok, valid_workflow_yaml()}
    end

    assert {:ok, report} =
             ShellDraft.draft("connect with api_key=supersecret and Bearer abc123",
               mock_handler: handler
             )

    assert report.status == :ok
    assert_received {:draft_messages, messages}

    user_message = Enum.find(messages, &(&1.role == "user"))
    refute user_message.content =~ "supersecret"
    refute user_message.content =~ "abc123"
    assert user_message.content =~ "[REDACTED]"
  end

  test "rejects generated write shots without a direct safety gate" do
    assert {:error, error} =
             ShellDraft.draft("draft unsafe remediation",
               response: """
               kind: workflow
               id: unsafe_draft
               version: 1.0.0
               shots:
                 - id: apply_change
                   kind: slug
                   agent: operator
                   timeout: 1m
                   tools: [kubectl_apply]
                   output_schema:
                     type: object
                     required: [summary]
                     properties:
                       summary:
                         type: string
               """
             )

    assert error.reason == :invalid_shell
    assert error.message =~ "strict lint"
    assert get_in(error.details, [:lint, :status]) == "failed"
  end

  test "rejects generated shots that reference unknown tools" do
    assert {:error, error} =
             ShellDraft.draft("draft unknown tool",
               response: """
               kind: workflow
               id: unknown_tool_draft
               version: 1.0.0
               shots:
                 - id: inspect_cluster
                   kind: slug
                   agent: operator
                   timeout: 1m
                   tools: [made_up_tool]
                   output_schema:
                     type: object
                     required: [summary]
                     properties:
                       summary:
                         type: string
               """
             )

    assert error.message =~ "strict lint"

    findings = get_in(error.details, [:lint, :findings])
    assert Enum.any?(findings, &(&1.id == "shot.tool.unknown"))
  end

  test "emits candidates that are loadable but does not execute them" do
    assert {:ok, report} = ShellDraft.draft("create a draft")

    path = write_tmp_shell(report.candidate, ".yaml")
    assert {:ok, workflow} = Loader.load(path)
    assert workflow.id == "drafted_workflow"
  end

  defp valid_workflow_yaml do
    {:ok, expansion} = Scaffold.expand("single-shot", "redacted_draft")
    {:ok, yaml} = Document.encode(expansion.workflow, :yaml)
    yaml
  end

  defp write_tmp_shell(contents, extension) do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-shell-draft-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    path = Path.join(root, "workflow#{extension}")
    File.write!(path, contents)
    path
  end
end
