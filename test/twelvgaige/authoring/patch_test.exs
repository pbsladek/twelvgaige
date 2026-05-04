defmodule Twelvgaige.Authoring.PatchTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Authoring.Patch

  test "canonical digest excludes patch_digest" do
    patch = patch_artifact("workflows/review.yaml", workflow_yaml(), workflow_yaml())

    assert Patch.canonical_digest(patch) ==
             Patch.canonical_digest(
               Map.put(patch, "patch_digest", "sha256:" <> String.duplicate("0", 64))
             )
  end

  test "inspects patch artifacts without reading target files" do
    root = tmp_dir!()
    patch_path = Path.join(root, "patch.json")
    patch = patch_artifact("workflows/review.yaml", workflow_yaml(), updated_workflow_yaml())
    File.write!(patch_path, Jason.encode!(put_digest(patch), pretty: true))

    assert {:ok, report} = Patch.inspect_file(patch_path)

    assert report["status"] == "ok"
    assert report["changed"] == false
    assert [%{"path" => "workflows/review.yaml"}] = report["files"]
  end

  test "verifies current file digest approval and candidate validity" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    approval_path = Path.join(root, "approval.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch = patch_artifact("workflows/review.yaml", workflow_yaml(), updated_workflow_yaml())
    patch = put_digest(patch)
    File.write!(patch_path, Jason.encode!(patch, pretty: true))

    File.write!(
      approval_path,
      Jason.encode!(approval(Patch.canonical_digest(patch)), pretty: true)
    )

    assert {:ok, report} = Patch.verify_file(patch_path, root: root, approval: approval_path)

    assert report["status"] == "ok"
    assert report["approval"]["status"] == "valid"
    assert report["findings"] == []
  end

  test "apply without write verifies and leaves files unchanged" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch = patch_artifact("workflows/review.yaml", workflow_yaml(), updated_workflow_yaml())
    File.write!(patch_path, Jason.encode!(put_digest(patch), pretty: true))

    assert {:ok, report} = Patch.apply_file(patch_path, root: root)

    assert report["kind"] == "twelvgaige.patch.apply"
    assert report["mode"] == "dry_run"
    assert report["changed"] == false
    assert report["status"] == "ok"
    assert File.read!(workflow_path) == workflow_yaml()
  end

  test "apply with write requires approval and leaves files unchanged" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch = patch_artifact("workflows/review.yaml", workflow_yaml(), updated_workflow_yaml())
    File.write!(patch_path, Jason.encode!(put_digest(patch), pretty: true))

    assert {:ok, report} = Patch.apply_file(patch_path, root: root, write?: true)

    assert report["kind"] == "twelvgaige.patch.apply"
    assert report["mode"] == "write"
    assert report["write_requested"] == true
    assert report["changed"] == false
    assert report["status"] == "failed"
    assert Enum.any?(report["findings"], &(&1["status"] == "approval_required"))
    assert File.read!(workflow_path) == workflow_yaml()
  end

  test "apply with write and approval atomically replaces target files" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    approval_path = Path.join(root, "approval.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch =
      patch_artifact("workflows/review.yaml", workflow_yaml(), updated_workflow_yaml())
      |> put_digest()

    File.write!(patch_path, Jason.encode!(patch, pretty: true))

    File.write!(
      approval_path,
      Jason.encode!(approval(Patch.canonical_digest(patch)), pretty: true)
    )

    assert {:ok, report} =
             Patch.apply_file(patch_path, root: root, approval: approval_path, write?: true)

    assert report["kind"] == "twelvgaige.patch.apply"
    assert report["mode"] == "write"
    assert report["write_requested"] == true
    assert report["changed"] == true
    assert report["status"] == "ok"
    assert [%{"write_status" => "written", "final_digest" => final_digest}] = report["files"]
    assert final_digest == sha256(updated_workflow_yaml())

    assert [
             %{"command" => "shell validate", "status" => "ok"},
             %{"command" => "shell lint", "status" => "ok"}
           ] =
             report["post_write_validations"]

    assert %{"events" => events, "checkpoint" => checkpoint} = report["audit"]

    assert Enum.map(events, & &1["event_type"]) == [
             "authoring_patch_apply_start",
             "authoring_patch_apply_file_written",
             "authoring_patch_apply_complete"
           ]

    assert :ok = Twelvgaige.Audit.Checkpoint.verify(checkpoint)
    assert File.read!(workflow_path) == updated_workflow_yaml()
  end

  test "apply reports post-write validation failures without hiding written files" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    approval_path = Path.join(root, "approval.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch =
      patch_artifact("workflows/review.yaml", workflow_yaml(), updated_workflow_yaml())
      |> Map.put("validations", [
        %{"command" => "shell validate", "path" => "workflows/review.yaml"},
        %{"command" => "shell validate", "path" => "workflows/missing.yaml"}
      ])
      |> put_digest()

    File.write!(patch_path, Jason.encode!(patch, pretty: true))

    File.write!(
      approval_path,
      Jason.encode!(approval(Patch.canonical_digest(patch)), pretty: true)
    )

    assert {:ok, report} =
             Patch.apply_file(patch_path, root: root, approval: approval_path, write?: true)

    assert report["status"] == "failed"
    assert report["exit_code"] == 1
    assert report["changed"] == true
    assert [%{"write_status" => "written"}] = report["files"]

    assert Enum.any?(
             report["findings"],
             &(&1["status"] == "post_write_validation_target_unknown")
           )

    assert Enum.at(report["post_write_validations"], 1)["status"] == "failed"
    assert List.last(report["audit"]["events"])["event_type"] == "authoring_patch_apply_failed"
    assert File.read!(workflow_path) == updated_workflow_yaml()
  end

  test "reports stale current file digests" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, updated_workflow_yaml())

    patch = patch_artifact("workflows/review.yaml", workflow_yaml(), updated_workflow_yaml())
    File.write!(patch_path, Jason.encode!(put_digest(patch), pretty: true))

    assert {:ok, report} = Patch.verify_file(patch_path, root: root)

    assert report["status"] == "failed"
    file = hd(report["files"])
    assert Enum.any?(file["findings"], &(&1["status"] == "before_digest_mismatch"))
  end

  test "reports approval digest mismatch" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    approval_path = Path.join(root, "approval.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch = patch_artifact("workflows/review.yaml", workflow_yaml(), updated_workflow_yaml())
    File.write!(patch_path, Jason.encode!(put_digest(patch), pretty: true))

    File.write!(
      approval_path,
      Jason.encode!(approval("sha256:" <> String.duplicate("0", 64)), pretty: true)
    )

    assert {:ok, report} = Patch.verify_file(patch_path, root: root, approval: approval_path)

    assert report["status"] == "failed"
    assert Enum.any?(report["findings"], &(&1["status"] == "approval_digest_mismatch"))
  end

  test "denies path traversal" do
    root = tmp_dir!()
    patch_path = Path.join(root, "patch.json")
    patch = patch_artifact("../outside.yaml", workflow_yaml(), updated_workflow_yaml())
    File.write!(patch_path, Jason.encode!(put_digest(patch), pretty: true))

    assert {:ok, report} = Patch.verify_file(patch_path, root: root)

    assert report["status"] == "failed"
    assert Enum.any?(hd(report["files"])["findings"], &(&1["status"] == "path_traversal"))
  end

  defp patch_artifact(path, before, after_contents) do
    %{
      "kind" => "twelvgaige.patch.v1",
      "id" => "patch_test",
      "created_at" => "2026-05-04T00:00:00Z",
      "files" => [
        %{
          "path" => path,
          "kind" => "workflow",
          "operation" => "replace",
          "before_digest" => sha256(before),
          "after_digest" => sha256(after_contents),
          "before_size_bytes" => byte_size(before),
          "after_size_bytes" => byte_size(after_contents),
          "content" => after_contents
        }
      ],
      "validations" => [
        %{"command" => "shell validate", "path" => path},
        %{"command" => "shell lint", "path" => path, "strict" => true}
      ],
      "summary" => %{"changed_files" => 1}
    }
  end

  defp put_digest(patch), do: Map.put(patch, "patch_digest", Patch.canonical_digest(patch))

  defp approval(patch_digest) do
    %{
      "kind" => "twelvgaige.patch_approval.v1",
      "id" => "approval_test",
      "patch_digest" => patch_digest,
      "approved_by" => "human:reviewer",
      "approved_at" => "2026-05-04T00:00:00Z",
      "scope" => "repo",
      "expires_at" => "2099-01-01T00:00:00Z"
    }
  end

  defp workflow_yaml do
    """
    kind: workflow
    id: patch_review
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

  defp updated_workflow_yaml do
    String.replace(workflow_yaml(), "Review input.", "Review updated input.")
  end

  defp sha256(contents) do
    "sha256:" <> (:crypto.hash(:sha256, contents) |> Base.encode16(case: :lower))
  end

  defp tmp_dir! do
    path = Path.join(System.tmp_dir!(), "twelvgaige-patch-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
