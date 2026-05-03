defmodule Twelvgaige.Shell.DocumentTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Shell.Loader

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
