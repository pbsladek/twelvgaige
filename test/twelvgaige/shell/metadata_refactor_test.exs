defmodule Twelvgaige.Shell.MetadataRefactorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.MetadataRefactor

  test "set updates workflow owner and lifecycle without writing" do
    path = write_workflow!(workflow_yaml())

    assert {:ok, result} =
             MetadataRefactor.set(path, owner: "platform", lifecycle: "reviewed")

    assert result.action == :set
    assert result.changed_fields == ["lifecycle", "owner"]
    assert result.candidate =~ "owner:"
    assert result.candidate =~ "platform"
    assert result.candidate =~ "reviewed"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.owner == nil
    assert workflow.metadata.lifecycle == nil

    assert result.workflow.metadata.owner == "platform"
    assert result.workflow.metadata.lifecycle == :reviewed
  end

  test "clear removes digest-bound review and approval bindings" do
    path = write_workflow!(workflow_with_bindings_yaml())

    assert {:ok, result} = MetadataRefactor.clear(path, [:review, :approval])

    assert result.action == :clear
    assert result.cleared_fields == ["review", "approval"]
    refute result.candidate =~ "reviewer:"
    refute result.candidate =~ "approver:"
    assert result.workflow.metadata.review == nil
    assert result.workflow.metadata.approval == nil
  end

  test "set and clear reject missing or unsupported fields" do
    path = write_workflow!(workflow_yaml())

    assert {:error, missing_error} = MetadataRefactor.set(path, [])
    assert missing_error.message =~ "at least one field"

    assert {:error, lifecycle_error} = MetadataRefactor.set(path, lifecycle: "live")
    assert lifecycle_error.message =~ "metadata lifecycle"

    assert {:error, clear_error} = MetadataRefactor.clear(path, [:source])
    assert clear_error.message =~ "supports only review and approval"
  end

  defp workflow_yaml do
    """
    kind: workflow
    id: metadata_refactor
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: mock_agent
        prompt: inspect
    """
  end

  defp workflow_with_bindings_yaml do
    """
    kind: workflow
    id: metadata_refactor_bindings
    version: 1.0.0
    metadata:
      owner: platform
      lifecycle: approved
      review:
        workflow_digest: sha256:1111111111111111111111111111111111111111111111111111111111111111
        reviewer: human:reviewer
        reviewed_at: "2026-01-01T00:00:00Z"
      approval:
        workflow_digest: sha256:2222222222222222222222222222222222222222222222222222222222222222
        approver: human:approver
        approved_at: "2026-01-01T00:00:00Z"
        scope: prod
    shots:
      - id: inspect
        kind: slug
        agent: mock_agent
        prompt: inspect
    """
  end

  defp write_workflow!(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-metadata-refactor-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
