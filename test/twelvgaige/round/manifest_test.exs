defmodule Twelvgaige.Round.ManifestTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Round.Manifest
  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Workflow

  @workflow_map %{
    kind: :workflow,
    id: "manifest_workflow",
    version: "1.0.0",
    shots: [
      %{id: "only", kind: :slug, agent: "agent", prompt: "hello"}
    ]
  }

  test "builds an immutable workflow manifest with a stable hash" do
    workflow = workflow!(@workflow_map)

    manifest =
      Manifest.new(
        round_id: "round_1",
        workflow: workflow,
        effective_resource_profile: :minimal,
        source: %{type: :path, path: "/tmp/workflow.yaml"}
      )

    assert manifest.schema_version == 2
    assert manifest.encoding_version == 1
    assert manifest.round_id == "round_1"
    assert manifest.shell_id == "manifest_workflow"
    assert manifest.shell_version == "1.0.0"
    assert manifest.workflow_hash == Manifest.workflow_hash(workflow)
    assert manifest.effective_resource_profile == :minimal
    assert {:ok, ^workflow} = Manifest.workflow(manifest)
  end

  test "records source file provenance with content hash and format" do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-manifest-#{System.unique_integer([:positive])}.yaml"
      )

    File.write!(path, "kind: workflow\n")

    on_exit(fn -> File.rm(path) end)

    source = Manifest.source_for(path)

    assert source.type == :path
    assert source.path == Path.expand(path)
    assert source.format == "yaml"
    expected_hash = :sha256 |> :crypto.hash("kind: workflow\n") |> Base.encode16(case: :lower)
    assert source.content_hash == expected_hash
  end

  test "records agent shell hashes and source provenance" do
    workflow = workflow!(@workflow_map)

    {:ok, agent} =
      Agent.from_map(%{
        kind: :agent,
        id: "agent",
        version: "1.0.0",
        provider: "mock",
        model: "mock-model",
        system_prompt: "test"
      })

    agent_path =
      Path.join(System.tmp_dir!(), "twelvgaige-agent-#{System.unique_integer([:positive])}.json")

    File.write!(agent_path, Jason.encode!(%{"kind" => "agent", "id" => "agent"}))

    on_exit(fn -> File.rm(agent_path) end)

    manifest =
      Manifest.new(
        round_id: "round_1",
        workflow: workflow,
        agents: [agent],
        agent_paths: [agent_path]
      )

    assert manifest.agent_hashes == Manifest.agent_hashes([agent])
    assert manifest.agent_hashes["agent"]
    assert {:ok, %{"agent" => ^agent}} = Manifest.agents(manifest)
    assert {:ok, %{model: "mock-model"}} = Manifest.loadout(manifest, "only")

    assert [%{type: :path, path: expanded, format: "json", content_hash: hash}] =
             manifest.agent_sources

    assert expanded == Path.expand(agent_path)
    assert is_binary(hash)
  end

  test "normalizes legacy map manifests and validates hash when present" do
    workflow = workflow!(@workflow_map)

    manifest = %{
      "round_id" => "round_1",
      "workflow" => @workflow_map,
      "workflow_hash" => Manifest.workflow_hash(workflow)
    }

    assert {:ok, %Workflow{id: "manifest_workflow"}} = Manifest.workflow(manifest)
  end

  test "rejects stored workflow hash mismatches" do
    manifest =
      Manifest.new(
        round_id: "round_1",
        workflow: workflow!(@workflow_map),
        workflow_hash: "bad-hash"
      )

    assert {:error, :manifest_hash_mismatch} = Manifest.workflow(manifest)
  end

  test "rejects stored agent hash mismatches" do
    workflow = workflow!(@workflow_map)

    {:ok, agent} =
      Agent.from_map(%{
        kind: :agent,
        id: "agent",
        version: "1.0.0",
        provider: "mock",
        model: "mock-model",
        system_prompt: "test"
      })

    manifest = Manifest.new(round_id: "round_1", workflow: workflow, agents: [agent])
    tampered = put_in(manifest.agent_snapshots["agent"].model, "tampered")

    assert {:error, :manifest_agent_hash_mismatch} = Manifest.agents(tampered)
    assert {:error, :manifest_agent_hash_mismatch} = Manifest.verify(tampered)
  end

  defp workflow!(map) do
    {:ok, workflow} = Workflow.from_map(map)
    workflow
  end
end
