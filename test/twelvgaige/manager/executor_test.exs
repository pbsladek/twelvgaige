defmodule Twelvgaige.Manager.ExecutorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.{ChildRecord, Executor}

  test "rejects unsupported child agents before any execution boundary" do
    child = struct(ChildRecord, task: %{agent: "unsupported"})

    assert {:error, {:manager_executor_agent_unsupported, "unsupported"}} =
             Executor.run(child, [])
  end

  test "dispatches Codex children through the governed executor" do
    child = struct(ChildRecord, task: %{agent: "codex"}, workspace_id: "workspace")

    assert {:error, :workspace_unavailable} =
             Executor.run(child,
               workspace_resolver: fn "workspace" -> {:error, :workspace_unavailable} end
             )
  end
end
