defmodule Twelvgaige.Manager.Store.OperationsTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.{Budget, ChildRecord, PlanRecord}
  alias Twelvgaige.Manager.Store.Operations
  alias Twelvgaige.Operations.Store

  test "persists atomic submissions and compare-and-swap updates without whole-file rewrites" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige-manager-ops-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    path = Path.join(root, "ops.sqlite3")
    store = start_supervised!({Store, name: nil, path: path})
    now = ~U[2026-08-02 00:00:00Z]

    plan = %PlanRecord{
      id: "plan_ops",
      compiled_plan: %{digest: "digest"},
      reserved_budget: Budget.zero(),
      allocated_budget: Budget.zero(),
      created_at: now
    }

    child = %ChildRecord{
      id: "child_ops",
      plan_id: "plan_ops",
      task_id: "task",
      attempt: 1,
      round_id: "round",
      shot_id: "shot",
      parent_session_id: "session",
      task: %{},
      budget: Budget.zero(),
      created_at: now
    }

    assert :ok = Operations.put_submission(plan, [child], server: store)
    assert :already_present = Operations.put_submission(plan, [child], server: store)
    assert {:ok, ^plan} = Operations.get_plan("plan_ops", server: store)
    assert {:ok, [^child]} = Operations.list_children("plan_ops", server: store)

    assert {:ok, %{status: :running, version: 1}} =
             Operations.update_plan("plan_ops", 0, %{status: :running}, server: store)

    assert {:error, :manager_version_conflict} =
             Operations.update_plan("plan_ops", 0, %{status: :failed}, server: store)

    event = %{id: "event_ops", type: :started}
    assert :ok = Operations.append_event("plan_ops", event, server: store)
    assert :already_present = Operations.append_event("plan_ops", event, server: store)
    assert {:ok, [^event]} = Operations.list_events("plan_ops", server: store)

    GenServer.stop(store)
    restarted = start_supervised!({Store, name: nil, path: path}, id: :restarted_manager_ops)

    assert {:ok, %{status: :running, version: 1}} =
             Operations.get_plan("plan_ops", server: restarted)
  end
end
