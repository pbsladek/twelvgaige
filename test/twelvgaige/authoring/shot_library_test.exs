defmodule Twelvgaige.Authoring.ShotLibraryTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Authoring.ShotLibrary

  test "lists built-in templates offline" do
    assert {:ok, templates} = ShotLibrary.list()

    keys = Enum.map(templates, &"#{&1.namespace}/#{&1.id}")
    assert "builtin/analysis.slug" in keys
    assert "builtin/safety.approval_gate" in keys
  end

  test "loads local templates from explicit library paths" do
    root = tmp_dir!()
    shots_dir = Path.join(root, "shots")
    File.mkdir_p!(shots_dir)
    File.write!(Path.join(shots_dir, "team.review.yaml"), local_template_yaml())

    assert {:ok, template} = ShotLibrary.fetch("team/team.review", library_paths: [shots_dir])

    assert template.source == :local
    assert template.path =~ "team.review.yaml"
    assert String.starts_with?(template.digest, "sha256:")
    assert template.shot["agent"] == "reviewer"
  end

  test "expands templates with shot id, overrides, and provenance metadata" do
    assert {:ok, shot} =
             ShotLibrary.expand("builtin/analysis.slug", "analyze",
               depends_on: ["inspect"],
               prompt: "custom prompt"
             )

    assert shot["id"] == "analyze"
    assert shot["prompt"] == "custom prompt"
    assert shot["depends_on"] == ["inspect"]

    assert %{
             "source" => %{
               "kind" => "template",
               "id" => "analysis.slug",
               "namespace" => "builtin",
               "digest" => digest
             }
           } = shot["metadata"]["generated_by"]

    assert String.starts_with?(digest, "sha256:")
  end

  test "writes and verifies a local template lockfile" do
    root = tmp_dir!()
    shots_dir = Path.join(root, "shots")
    lockfile = Path.join(root, "twelvgaige-library.lock")
    File.mkdir_p!(shots_dir)
    File.write!(Path.join(shots_dir, "team.review.yaml"), local_template_yaml())

    assert {:ok, write_report} =
             ShotLibrary.verify(root: root, library_paths: [shots_dir], write_lock?: true)

    assert write_report["status"] == "ok"
    assert File.exists?(lockfile)

    assert {:ok, verify_report} = ShotLibrary.verify(root: root, library_paths: [shots_dir])

    assert verify_report["status"] == "ok"
    assert verify_report["findings"] == []
  end

  test "reports digest mismatches and missing lockfiles clearly" do
    root = tmp_dir!()
    shots_dir = Path.join(root, "shots")
    template_path = Path.join(shots_dir, "team.review.yaml")
    File.mkdir_p!(shots_dir)
    File.write!(template_path, local_template_yaml())

    assert {:ok, missing_report} = ShotLibrary.verify(root: root, library_paths: [shots_dir])

    assert missing_report["status"] == "failed"
    assert [%{"status" => "missing_lockfile"}] = missing_report["findings"]

    assert {:ok, _write_report} =
             ShotLibrary.verify(root: root, library_paths: [shots_dir], write_lock?: true)

    File.write!(
      template_path,
      String.replace(local_template_yaml(), "Review the change.", "Review drift.")
    )

    assert {:ok, mismatch_report} = ShotLibrary.verify(root: root, library_paths: [shots_dir])

    assert mismatch_report["status"] == "failed"

    assert [%{"status" => "digest_mismatch", "template" => "team/team.review"}] =
             mismatch_report["findings"]
  end

  test "updates lockfile after local template drift" do
    root = tmp_dir!()
    shots_dir = Path.join(root, "shots")
    template_path = Path.join(shots_dir, "team.review.yaml")
    File.mkdir_p!(shots_dir)
    File.write!(template_path, local_template_yaml())

    assert {:ok, _write_report} =
             ShotLibrary.verify(root: root, library_paths: [shots_dir], write_lock?: true)

    File.write!(
      template_path,
      String.replace(local_template_yaml(), "Review the change.", "Review drift.")
    )

    assert {:ok, dry_run} = ShotLibrary.update(root: root, library_paths: [shots_dir])

    assert dry_run["mode"] == "dry_run"
    assert dry_run["changed"]
    assert dry_run["diff"] =~ ~s(+  - digest: "sha256:)

    assert [%{"status" => "digest_mismatch", "template" => "team/team.review"}] =
             dry_run["findings"]

    assert {:ok, written} =
             ShotLibrary.update(root: root, library_paths: [shots_dir], write_lock?: true)

    assert written["mode"] == "write_lock"
    assert written["changed"]
    refute Map.has_key?(written, "diff")

    assert {:ok, verify_report} = ShotLibrary.verify(root: root, library_paths: [shots_dir])
    assert verify_report["status"] == "ok"
    assert verify_report["findings"] == []
  end

  test "reports copied shots whose template source is outdated or missing" do
    root = tmp_dir!()
    shots_dir = Path.join(root, "shots")
    workflows_dir = Path.join(root, "workflows")
    template_path = Path.join(shots_dir, "team.review.yaml")
    workflow_path = Path.join(workflows_dir, "review.yaml")
    File.mkdir_p!(shots_dir)
    File.mkdir_p!(workflows_dir)
    File.write!(template_path, local_template_yaml())

    assert {:ok, template} = ShotLibrary.fetch("team/team.review", library_paths: [shots_dir])

    File.write!(workflow_path, workflow_with_template_source(template))

    assert {:ok, report} = ShotLibrary.outdated(root, root: root, library_paths: [shots_dir])
    assert report["status"] == "ok"
    assert report["findings"] == []
    assert report["checked_workflows"] == 1
    assert report["checked_shots"] == 1

    File.write!(
      template_path,
      String.replace(local_template_yaml(), "Review the change.", "Review drift.")
    )

    assert {:ok, report} = ShotLibrary.outdated(root, root: root, library_paths: [shots_dir])
    assert report["status"] == "failed"

    assert [
             %{
               "status" => "digest_mismatch",
               "workflow" => "library_drift",
               "shot" => "review",
               "template" => "team/team.review"
             }
           ] = report["findings"]

    File.rm!(template_path)

    assert {:ok, report} = ShotLibrary.outdated(root, root: root, library_paths: [shots_dir])

    assert [%{"status" => "template_missing", "template" => "team/team.review"}] =
             report["findings"]
  end

  defp local_template_yaml do
    """
    kind: shot_template
    namespace: team
    id: team.review
    version: 1.0.0
    description: Team review shot
    shot:
      kind: slug
      agent: reviewer
      prompt: Review the change.
    """
  end

  defp workflow_with_template_source(template) do
    """
    kind: workflow
    id: library_drift
    version: 1.0.0
    shots:
      - id: review
        kind: slug
        agent: reviewer
        timeout: 1m
        output_schema:
          type: object
          required: [summary]
          properties:
            summary:
              type: string
        metadata:
          generated_by:
            tool: twelvgaige
            command: shot add --template team/team.review
            version: 0.0.1
            source:
              kind: template
              namespace: #{template.namespace}
              id: #{template.id}
              version: #{template.version}
              digest: #{template.digest}
    """
  end

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-shot-library-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
