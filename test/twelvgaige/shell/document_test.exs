defmodule Twelvgaige.Shell.DocumentTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Shell.Digest
  alias Twelvgaige.Shell.Loader
  alias Twelvgaige.Shell.Workflow

  test "encodes workflow shells as round-trippable JSON TOML and YAML" do
    assert {:ok, workflow} = Loader.load("test/fixtures/shells/simple_workflow.yaml")

    for format <- [:json, :toml, :yaml] do
      assert {:ok, contents} = Document.encode(workflow, format)
      path = write_temp_shell!(format, contents)

      assert {:ok, ^workflow} = Loader.load(path)
    end
  end

  test "encodes agent shells as round-trippable JSON TOML and YAML" do
    assert {:ok, agent} = Loader.load("test/fixtures/shells/mock_agent.yaml")

    for format <- [:json, :toml, :yaml] do
      assert {:ok, contents} = Document.encode(agent, format)
      path = write_temp_shell!(format, contents)

      assert {:ok, ^agent} = Loader.load(path)
    end
  end

  test "canonical document omits nil and default-only branches" do
    assert {:ok, workflow} = Loader.load("test/fixtures/shells/simple_workflow.yaml")

    assert %{
             "kind" => "workflow",
             "id" => "simple",
             "name" => "Simple Workflow",
             "version" => "1.0.0",
             "shots" => [%{"id" => "first"}, %{"id" => "second"}]
           } = Document.to_map(workflow)

    refute Map.has_key?(Document.to_map(workflow), "policy")
  end

  test "preserves workflow and shot metadata across JSON TOML and YAML" do
    assert {:ok, workflow} =
             Workflow.from_map(%{
               "kind" => "workflow",
               "id" => "metadata_roundtrip",
               "version" => "1.0.0",
               "metadata" => %{
                 "owner" => "platform",
                 "tags" => ["ci"],
                 "lifecycle" => "draft",
                 "generated_by" => %{
                   "tool" => "twelvgaige",
                   "command" => "shell new",
                   "version" => Twelvgaige.version(),
                   "source" => %{
                     "kind" => "scaffold",
                     "id" => "single-shot",
                     "version" => "1.0.0"
                   }
                 }
               },
               "shots" => [
                 %{
                   "id" => "only",
                   "kind" => "slug",
                   "agent" => "mock_agent",
                   "metadata" => %{"purpose" => "Exercise metadata preservation"}
                 }
               ]
             })

    for format <- [:json, :toml, :yaml] do
      assert {:ok, contents} = Document.encode(workflow, format)
      path = write_temp_shell!(format, contents)

      assert {:ok, loaded} = Loader.load(path)
      assert loaded.metadata.owner == "platform"
      assert loaded.metadata.generated_by["source"]["id"] == "single-shot"
      assert [shot] = loaded.shots
      assert shot.metadata.purpose == "Exercise metadata preservation"
    end
  end

  test "workflow subject digest ignores embedded review and approval records only" do
    assert {:ok, base} =
             Workflow.from_map(%{
               kind: :workflow,
               id: "digest_subject",
               version: "1.0.0",
               metadata: %{owner: "platform", lifecycle: "approved"},
               shots: [%{id: "only", kind: :slug, agent: "agent", prompt: "do work"}]
             })

    digest = Digest.workflow_subject_digest(base)

    assert {:ok, approved} =
             Workflow.from_map(%{
               kind: :workflow,
               id: "digest_subject",
               version: "1.0.0",
               metadata: %{
                 owner: "platform",
                 lifecycle: "approved",
                 approval: %{
                   workflow_digest: digest,
                   approver: "human:sre",
                   approved_at: "2026-05-03T00:00:00Z",
                   scope: "prod"
                 }
               },
               shots: [%{id: "only", kind: :slug, agent: "agent", prompt: "do work"}]
             })

    assert Digest.workflow_subject_digest(approved) == digest
    assert Digest.current_binding?(approved, :approval)

    assert {:ok, changed} =
             Workflow.from_map(%{
               kind: :workflow,
               id: "digest_subject",
               version: "1.0.0",
               metadata: %{
                 owner: "platform",
                 lifecycle: "approved",
                 approval: %{
                   workflow_digest: digest,
                   approver: "human:sre",
                   approved_at: "2026-05-03T00:00:00Z",
                   scope: "prod"
                 }
               },
               shots: [%{id: "only", kind: :slug, agent: "agent", prompt: "changed"}]
             })

    refute Digest.current_binding?(changed, :approval)
  end

  defp write_temp_shell!(format, contents) do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-shell-document-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    path = Path.join(root, "shell.#{format}")
    File.write!(path, contents)
    path
  end
end
