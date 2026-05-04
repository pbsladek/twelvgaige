defmodule Twelvgaige.Shell.FormatterTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Formatter
  alias Twelvgaige.Shell.Loader

  test "formats a workflow shell into canonical document output" do
    path = write_tmp_shell(messy_workflow_yaml(), ".yaml")

    assert {:ok, result} = Formatter.format(path)

    assert result.kind == :workflow
    assert result.id == "fmt_demo"
    assert result.format == :yaml
    assert result.changed?
    assert result.diff =~ "--- #{path}"
    assert result.candidate =~ ~s(kind: "workflow")
    assert {:ok, workflow} = Loader.load(write_tmp_shell(result.candidate, ".yaml"))
    assert workflow.id == "fmt_demo"
  end

  test "detects already canonical shells" do
    original = """
    id: "fmt_demo"
    kind: "workflow"
    shots:
      - agent: "agent"
        id: "inspect"
        kind: "slug"
        timeout: "60000ms"
    version: "1.0.0"
    """

    path = write_tmp_shell(original, ".yaml")

    assert {:ok, result} = Formatter.format(path)
    refute result.changed?
    assert result.candidate == original
  end

  test "formats agent shells too" do
    path =
      write_tmp_shell(
        """
        provider: mock
        kind: agent
        id: agent_fmt
        model: mock-model
        system_prompt: Test
        version: 1.0.0
        """,
        ".yaml"
      )

    assert {:ok, result} = Formatter.format(path)

    assert result.kind == :agent
    assert result.id == "agent_fmt"
    assert result.changed?
  end

  test "rejects unsupported file extensions" do
    assert {:error, error} = Formatter.format("workflow.txt")

    assert error.reason == :invalid_shell
    assert error.message =~ "unsupported shell file extension"
  end

  defp messy_workflow_yaml do
    """
    version: 1.0.0
    shots:
      - timeout: 1m
        agent: agent
        kind: slug
        id: inspect
    kind: workflow
    id: fmt_demo
    """
  end

  defp write_tmp_shell(contents, extension) do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-formatter-test-#{System.unique_integer([:positive])}#{extension}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end
end
