defmodule Twelvgaige.Manager.NativeSubagentsTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.NativeSubagents

  test "native subagents remain in the parent's workspace, sandbox, auth, deadline, and budget" do
    deadline = DateTime.add(DateTime.utc_now(), 300)

    parent = %{
      session_id: "session",
      workspace_id: "workspace",
      sandbox_resource_id: "sandbox",
      auth_profile_id: "api",
      capabilities: ["filesystem.write", "mcp.write"],
      budget: budget(100),
      deadline: deadline
    }

    proposal = %{
      runtime_id: "codex-subagent-1",
      workspace_id: "workspace",
      sandbox_resource_id: "sandbox",
      auth_profile_id: "api",
      capabilities: ["filesystem.write"],
      budget: budget(20),
      usage: budget(2),
      deadline: DateTime.add(deadline, -10)
    }

    assert {:ok, native} = NativeSubagents.admit(parent, proposal)
    assert native.parent_session_id == "session"
    assert native.workspace_id == parent.workspace_id

    assert {:ok, native} = NativeSubagents.observe_usage(native, budget(17))
    assert native.usage.tokens == 19

    assert {:error, {:manager_native_subagent_budget_exceeded, exceeded}} =
             NativeSubagents.observe_usage(native, budget(2))

    assert :tokens in exceeded

    expanded = %{proposal | auth_profile_id: "admin", capabilities: ["shell.root"]}

    assert {:error, {:twelvgaige_child_required, reasons}} =
             NativeSubagents.admit(parent, expanded)

    assert :auth_profile_id in reasons
    assert :capabilities in reasons

    assert {:error, {:twelvgaige_child_required, overuse_reasons}} =
             NativeSubagents.admit(parent, %{proposal | usage: budget(21)})

    assert :usage in overuse_reasons
  end

  defp budget(amount),
    do: %{tokens: amount, cost_micros: amount, time_ms: amount, tool_calls: amount}
end
