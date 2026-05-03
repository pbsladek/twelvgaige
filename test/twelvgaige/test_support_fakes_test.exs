defmodule Twelvgaige.TestSupportFakesTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.TestSupport.FakeCommandRunner
  alias Twelvgaige.TestSupport.FakeResourceLimiter
  alias Twelvgaige.TestSupport.FakeStore

  test "fake command runner captures argv without running an OS command" do
    start_supervised!(
      {FakeCommandRunner,
       responses: [
         {:ok, %{status: 0, stdout: "ok", stderr: "", duration_ms: 4}}
       ]}
    )

    runner = FakeCommandRunner.runner()

    assert {:ok, result} = runner.("kubectl", ["get", "pods", "-n", "default"], timeout_ms: 10)
    assert result.stdout == "ok"

    assert [
             %{
               binary: "kubectl",
               args: ["get", "pods", "-n", "default"],
               opts: [timeout_ms: 10]
             }
           ] = FakeCommandRunner.calls()
  end

  test "fake store keeps rounds and supports controllable failures" do
    start_supervised!(FakeStore)

    snapshot = %{
      id: "round_fake_store",
      shell_id: "fake",
      shell_version: "1.0.0",
      status: :firing,
      version: 0,
      shots: [%{id: "shot", kind: :slug, status: :pending, attempt: 0}]
    }

    assert :ok = FakeStore.create_round(snapshot, %{round_id: snapshot.id}, [])
    assert {:ok, ^snapshot} = FakeStore.get_round(snapshot.id)
    assert {:ok, [%{shot_id: "shot", status: :pending}]} = FakeStore.list_shot_runs(snapshot.id)

    FakeStore.fail_next(:commit_transition, :store_down)

    assert {:error, :store_down} =
             FakeStore.commit_transition(
               snapshot.id,
               0,
               "tr_fail",
               %{snapshot | status: :complete},
               [],
               []
             )

    assert :ok =
             FakeStore.commit_transition(
               snapshot.id,
               0,
               "tr_ok",
               %{snapshot | status: :complete},
               [%{event_type: :round_completed}],
               []
             )

    assert {:ok, %{status: :complete, version: 1}} = FakeStore.get_round(snapshot.id)

    assert {:ok, [%{seq: 1, event_type: :round_completed}]} =
             FakeStore.list_round_events(snapshot.id)

    assert [:create_round, :commit_transition, :commit_transition] = FakeStore.calls()
  end

  test "fake resource limiter drives acquire, queue, and release paths" do
    start_supervised!(
      {FakeResourceLimiter,
       responses: [
         :ok,
         :queued,
         {:error, {:limit_exceeded, :active_shot}}
       ]}
    )

    assert {:ok, permit} =
             Twelvgaige.ResourceLimiter.acquire(
               :active_shot,
               %{round_id: "round", shot_id: "shot"},
               server: FakeResourceLimiter
             )

    assert permit.resource_kind == :active_shot
    assert permit.round_id == "round"
    assert :ok = Twelvgaige.ResourceLimiter.release(permit)

    assert {:queued, waiter} =
             Twelvgaige.ResourceLimiter.acquire(
               :active_shot,
               %{round_id: "round", shot_id: "queued"},
               server: FakeResourceLimiter
             )

    assert waiter.shot_id == "queued"
    assert :ok = Twelvgaige.ResourceLimiter.cancel_waiter(waiter)

    assert {:error, {:limit_exceeded, :active_shot}} =
             Twelvgaige.ResourceLimiter.acquire(:active_shot, %{}, server: FakeResourceLimiter)

    assert [
             %{resource_kind: :active_shot, context: %{shot_id: "shot"}},
             %{resource_kind: :active_shot, context: %{shot_id: "queued"}},
             %{resource_kind: :active_shot, context: %{}}
           ] = FakeResourceLimiter.requests()
  end
end
