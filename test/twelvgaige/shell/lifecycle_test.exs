defmodule Twelvgaige.Shell.LifecycleTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Digest
  alias Twelvgaige.Shell.Lifecycle

  test "review stamps digest-bound reviewed metadata" do
    path = write_tmp_shell(reviewable_workflow_yaml(), ".yaml")

    assert {:ok, result} =
             Lifecycle.review(path,
               by: "human:reviewer",
               scope: "dev",
               reviewed_at: "2026-05-03T00:00:00Z"
             )

    assert result.action == :review
    assert result.lifecycle == :reviewed
    assert result.actor == "human:reviewer"
    assert result.scope == "dev"
    assert result.digest =~ "sha256:"
    assert result.diff =~ "reviewed_at"
    assert Digest.current_binding?(result.workflow, :review)
  end

  test "approve stamps digest-bound approval metadata" do
    path = write_tmp_shell(reviewable_workflow_yaml(), ".yaml")

    assert {:ok, result} =
             Lifecycle.approve(path,
               by: "human:approver",
               scope: "prod",
               approved_at: "2026-05-03T00:00:00Z",
               expires_at: "2026-06-03T00:00:00Z"
             )

    assert result.action == :approve
    assert result.lifecycle == :approved
    assert result.actor == "human:approver"
    assert result.scope == "prod"
    assert get_in(result.workflow.metadata.approval, ["expires_at"]) == "2026-06-03T00:00:00Z"
    assert Digest.current_binding?(result.workflow, :approval)
  end

  test "approve requires owner and scope" do
    path = write_tmp_shell(no_owner_workflow_yaml(), ".yaml")

    assert {:error, error} = Lifecycle.approve(path, by: "human:approver", scope: "prod")
    assert error.message =~ "metadata.owner"

    assert {:error, error} = Lifecycle.approve(path, by: "human:approver")
    assert error.message =~ "--scope"
  end

  test "deprecate and retire set terminal lifecycle metadata and clear bindings" do
    approved_path = write_tmp_shell(reviewable_workflow_yaml(), ".yaml")

    assert {:ok, approved} =
             Lifecycle.approve(approved_path,
               by: "human:approver",
               scope: "prod",
               approved_at: "2026-05-03T00:00:00Z"
             )

    File.write!(approved_path, approved.candidate)

    assert {:ok, deprecated} =
             Lifecycle.deprecate(approved_path,
               by: "human:owner",
               reason: "replaced by lifecycle_v2"
             )

    assert deprecated.action == :deprecate
    assert deprecated.lifecycle == :deprecated
    assert deprecated.reason == "replaced by lifecycle_v2"
    assert deprecated.workflow.metadata.lifecycle_reason == "replaced by lifecycle_v2"
    refute deprecated.workflow.metadata.approval
    refute Digest.current_binding?(deprecated.workflow, :approval)

    assert {:ok, retired} =
             Lifecycle.retire(approved_path,
               by: "human:owner",
               reason: "kept for audit only"
             )

    assert retired.action == :retire
    assert retired.lifecycle == :retired
    assert retired.workflow.metadata.lifecycle_reason == "kept for audit only"
  end

  test "terminal lifecycle commands require actor and reason" do
    path = write_tmp_shell(reviewable_workflow_yaml(), ".yaml")

    assert {:error, error} = Lifecycle.deprecate(path, by: "human:owner")
    assert error.message =~ "--reason"

    assert {:error, error} = Lifecycle.retire(path, reason: "done")
    assert error.message =~ "--by"
  end

  test "rejects invalid evidence digests through normal metadata validation" do
    path = write_tmp_shell(reviewable_workflow_yaml(), ".yaml")

    assert {:error, error} =
             Lifecycle.review(path,
               by: "human:reviewer",
               evidence_hash: "not-a-digest",
               reviewed_at: "2026-05-03T00:00:00Z"
             )

    assert error.reason == :invalid_shell
    assert error.details.path == ["metadata", "review", "evidence_hash"]
  end

  defp reviewable_workflow_yaml do
    """
    kind: workflow
    id: lifecycle_demo
    version: 1.0.0
    metadata:
      owner: platform
      lifecycle: draft
    shots:
      - id: inspect
        kind: slug
        agent: agent
        timeout: 1m
        output_schema:
          type: object
          required: [summary]
          properties:
            summary:
              type: string
    """
  end

  defp no_owner_workflow_yaml do
    """
    kind: workflow
    id: lifecycle_no_owner
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: agent
    """
  end

  defp write_tmp_shell(contents, extension) do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-lifecycle-test-#{System.unique_integer([:positive])}#{extension}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
