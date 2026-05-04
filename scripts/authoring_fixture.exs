defmodule Twelvgaige.AuthoringFixture do
  @moduledoc false

  alias Twelvgaige.Authoring.Patch

  def main([base_dir]) do
    root = Path.join(base_dir, "traphouse")
    patch_path = Path.join(base_dir, "patch.json")
    approval_path = Path.join(base_dir, "approval.json")
    workflow_rel = "workflows/simple.yaml"
    workflow_path = Path.join(root, workflow_rel)

    File.rm_rf!(base_dir)
    File.mkdir_p!(base_dir)
    File.cp_r!("docs/traphouse", root)

    before = File.read!(workflow_path)
    after_contents = String.replace(before, "first prompt", "first prompt reviewed")

    patch =
      %{
        "kind" => "twelvgaige.patch.v1",
        "id" => "authoring_smoke_patch",
        "created_at" => "2026-05-04T00:00:00Z",
        "files" => [
          %{
            "path" => workflow_rel,
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
          %{"command" => "shell validate", "path" => workflow_rel},
          %{"command" => "shell lint", "path" => workflow_rel, "strict" => true}
        ],
        "summary" => %{"changed_files" => 1, "purpose" => "authoring smoke fixture"}
      }
      |> then(&Map.put(&1, "patch_digest", Patch.canonical_digest(&1)))

    approval = %{
      "kind" => "twelvgaige.patch_approval.v1",
      "id" => "authoring_smoke_approval",
      "patch_digest" => patch["patch_digest"],
      "approved_by" => "human:ci",
      "approved_at" => "2026-05-04T00:00:00Z",
      "scope" => "ci",
      "expires_at" => "2099-01-01T00:00:00Z"
    }

    File.write!(patch_path, Jason.encode!(patch, pretty: true))
    File.write!(approval_path, Jason.encode!(approval, pretty: true))
    IO.puts("authoring fixture: #{base_dir}")
  end

  def main(_args) do
    IO.puts(:stderr, "usage: mix run scripts/authoring_fixture.exs <tmp-dir>")
    System.halt(2)
  end

  defp sha256(contents) do
    "sha256:" <> (:crypto.hash(:sha256, contents) |> Base.encode16(case: :lower))
  end
end

Twelvgaige.AuthoringFixture.main(System.argv())
