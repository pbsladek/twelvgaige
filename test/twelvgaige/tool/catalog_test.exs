defmodule Twelvgaige.Tool.CatalogTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Catalog

  test "exposes built-in tools" do
    assert Catalog.names() == [
             "git_commit",
             "http_get",
             "http_post",
             "kubectl_apply",
             "kubectl_delete",
             "kubectl_describe",
             "kubectl_events",
             "kubectl_exec",
             "kubectl_get",
             "kubectl_logs",
             "kubectl_rollout_restart",
             "kubectl_scale",
             "patch_plan",
             "shell_diff",
             "shell_graph",
             "shell_impact",
             "shell_inventory",
             "shell_lint",
             "shell_normalize",
             "shell_read",
             "shell_validate",
             "tool_catalog_read"
           ]

    assert {:ok, metadata} = Catalog.metadata("shell_read")
    assert metadata.name == "shell_read"
    assert metadata.safety_level == :read_only
    assert metadata.idempotency.class == :read_only
    refute metadata.idempotency.requires_key?
  end

  test "classifies unknown tools" do
    assert {:error, error} = Catalog.fetch("missing_tool")
    assert error.reason == :unknown_tool
    assert "kubectl_get" in error.details.known_tools
    assert "kubectl_delete" in error.details.known_tools
    assert "shell_read" in error.details.known_tools
    assert "shell_validate" in error.details.known_tools
  end
end
