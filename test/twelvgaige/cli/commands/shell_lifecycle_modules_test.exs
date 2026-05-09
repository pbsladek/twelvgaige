defmodule Twelvgaige.CLI.Commands.ShellLifecycleModulesTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Commands.ShellLifecycleActions
  alias Twelvgaige.CLI.Commands.ShellMetadataCommands

  test "lifecycle actions review dry-run leaves file unchanged" do
    path = write_workflow!(lifecycle_workflow_yaml())

    assert {:ok, output, 0} =
             ShellLifecycleActions.lifecycle(:review, path, ["--by", "human:reviewer"])

    assert output =~ "dry run: shell review #{path}"
    assert output =~ "lifecycle: reviewed"
    assert output =~ "wrote: false"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.lifecycle == :draft
  end

  test "lifecycle actions write approval with current digest binding" do
    path = write_workflow!(lifecycle_workflow_yaml())

    assert {:ok, output, 0} =
             ShellLifecycleActions.lifecycle(:approve, path, [
               "--by",
               "human:approver",
               "--scope",
               "prod",
               "--write",
               "--format",
               "json"
             ])

    assert %{"action" => "approve", "lifecycle" => "approved", "wrote" => true} =
             Jason.decode!(output)

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.lifecycle == :approved
    assert Twelvgaige.Shell.Digest.current_binding?(workflow, :approval)
  end

  test "lifecycle actions validate action-specific required options" do
    path = write_workflow!(lifecycle_workflow_yaml())

    assert {:ok, output, 4} =
             ShellLifecycleActions.lifecycle(:deprecate, path, ["--by", "human:owner"])

    assert output =~ "--reason is required"

    assert {:ok, output, 4} =
             ShellLifecycleActions.lifecycle(:approve, path, [
               "--by",
               "human:approver",
               "--format",
               "json"
             ])

    assert output =~ "--scope is required"
  end

  test "metadata commands set and clear metadata with direct module calls" do
    path = write_workflow!(no_owner_workflow_yaml())

    assert {:ok, output, 0} =
             ShellMetadataCommands.metadata_set(path, [
               "--owner",
               "platform",
               "--lifecycle",
               "reviewed",
               "--write",
               "--format",
               "json"
             ])

    assert %{"action" => "set", "changed_fields" => ["lifecycle", "owner"], "wrote" => true} =
             Jason.decode!(output)

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.owner == "platform"
    assert workflow.metadata.lifecycle == :reviewed

    assert {:ok, output, 0} =
             ShellLifecycleActions.lifecycle(:review, path, ["--by", "human:reviewer", "--write"])

    assert output =~ "marked workflow review"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.review

    assert {:ok, output, 0} =
             ShellMetadataCommands.metadata_clear(path, [
               "--review",
               "--write",
               "--format",
               "json"
             ])

    assert %{"action" => "clear", "cleared_fields" => ["review"], "wrote" => true} =
             Jason.decode!(output)

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.review == nil
  end

  test "metadata commands require explicit fields" do
    path = write_workflow!(lifecycle_workflow_yaml())

    assert {:ok, output, 4} = ShellMetadataCommands.metadata_set(path, [])
    assert output =~ "requires --owner or --lifecycle"

    assert {:ok, output, 4} = ShellMetadataCommands.metadata_clear(path, ["--format", "json"])
    assert output =~ "requires --review or --approval"
  end

  defp write_workflow!(contents) do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-shell-lifecycle-modules-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp lifecycle_workflow_yaml do
    """
    kind: workflow
    id: lifecycle_modules
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
    id: lifecycle_modules_no_owner
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: agent
    """
  end
end
