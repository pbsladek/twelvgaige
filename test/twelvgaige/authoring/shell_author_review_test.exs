defmodule Twelvgaige.Authoring.ShellAuthorReviewTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Authoring.ShellAuthorReview

  test "creates a deterministic read-only patch plan through the mock provider" do
    path = write_tmp_shell(workflow_yaml())

    assert {:ok, report} = ShellAuthorReview.review(path)

    assert report.status == :ok
    assert report.exit_code == 0
    assert report.disclosure["writes_files"] == false
    assert report.disclosure["source_paths"] == [path]
    assert report.patch_plan["kind"] == "twelvgaige.patch_plan"
    assert report.patch_plan["plan_digest"] =~ "sha256:"
    assert [%{"action" => "review"}] = report.patch_plan["changes"]
  end

  test "rejects hosted providers without explicit remote consent" do
    path = write_tmp_shell(workflow_yaml())

    assert {:error, error} =
             ShellAuthorReview.review(path, provider: "openai", model: "gpt-test")

    assert error.class == :policy_error
    assert error.reason == :policy_denied
    assert error.message =~ "--allow-remote"
  end

  test "redacts shell source before provider transport" do
    path =
      write_tmp_shell(String.replace(workflow_yaml(), "Review input.", "api_key=supersecret"))

    parent = self()

    handler = fn _model, messages, _opts ->
      send(parent, {:author_review_messages, messages})
      {:ok, Jason.encode!(%{"changes" => [%{"action" => "review", "description" => "ok"}]})}
    end

    assert {:ok, report} = ShellAuthorReview.review(path, mock_handler: handler)

    assert report.disclosure["redacted_bytes"] <= report.disclosure["source_bytes"]
    assert_received {:author_review_messages, messages}

    user_message = Enum.find(messages, &(&1.role == "user"))
    refute user_message.content =~ "supersecret"
    assert user_message.content =~ "[REDACTED]"
  end

  test "bounds author review input size" do
    path = write_tmp_shell(workflow_yaml())

    assert {:error, error} = ShellAuthorReview.review(path, max_input_bytes: 4)

    assert error.reason == :llm_context_too_large
  end

  defp workflow_yaml do
    """
    kind: workflow
    id: author_review_test
    version: 1.0.0
    shots:
      - id: review
        kind: slug
        agent: reviewer
        timeout: 1m
        prompt: Review input.
        output_schema:
          type: object
          required: [summary]
          properties:
            summary:
              type: string
    """
  end

  defp write_tmp_shell(contents) do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-shell-author-review-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    path = Path.join(root, "workflow.yaml")
    File.write!(path, contents)
    path
  end
end
