defmodule Twelvgaige.Operations.SchedulerDurabilityTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Operations.Store
  alias Twelvgaige.Scheduler

  @workflow %{
    kind: :workflow,
    id: "durable_scheduled_workflow",
    version: "1.0.0",
    shots: [%{id: "only", kind: :slug, agent: "agent", prompt: "hello"}]
  }

  test "automation replay claims, next occurrence, and misfire policy survive restart" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-scheduler-durable-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    store = start_supervised!({Store, name: nil, path: Path.join(root, "ops.sqlite3")})

    clock =
      start_supervised!({Agent, fn -> ~U[2026-08-02 12:00:00Z] end}, id: :scheduler_clock)

    calls = start_supervised!({Agent, fn -> 0 end}, id: :scheduler_calls)

    runner = fn _workflow, _input, _opts ->
      count = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})
      {:ok, "round_#{count}"}
    end

    opts = [
      name: nil,
      operations_store: store,
      now_fun: fn -> Agent.get(clock, & &1) end,
      runner: runner,
      jobs: [
        %{
          id: "durable",
          workflow: @workflow,
          input: %{},
          interval_ms: 60_000,
          initial_delay_ms: 0,
          misfire_policy: :fire_once,
          overlap_policy: :skip
        }
      ]
    ]

    first = start_supervised!({Scheduler, opts})
    assert_eventually(fn -> Agent.get(calls, & &1) == 1 end)

    assert %{jobs: [%{last_occurrence_id: occurrence, next_fire_at: next_at}]} =
             Scheduler.status(first)

    assert is_binary(occurrence)
    assert DateTime.compare(next_at, ~U[2026-08-02 12:01:00Z]) == :eq

    GenServer.stop(first)
    Agent.update(clock, fn now -> DateTime.add(now, 5 * 60, :second) end)
    second = start_supervised!({Scheduler, opts}, id: :restarted_durable_scheduler)

    assert_eventually(fn -> Agent.get(calls, & &1) == 2 end)
    Process.sleep(20)
    assert Agent.get(calls, & &1) == 2

    assert %{jobs: [%{next_fire_at: next_after_recovery}]} = Scheduler.status(second)
    assert DateTime.compare(next_after_recovery, ~U[2026-08-02 12:05:00Z]) == :gt

    assert {:ok, claims} = Store.stats(server: store)
    assert claims.claims == 2
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
    end
  end
end
