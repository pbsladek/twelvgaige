defmodule Twelvgaige.SchedulerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Scheduler

  @workflow %{
    kind: :workflow,
    id: "scheduled_workflow",
    version: "1.0.0",
    shots: [
      %{id: "only", kind: :slug, agent: "agent", prompt: "hello"}
    ]
  }

  test "fires configured interval jobs through the runner" do
    parent = self()

    runner = fn workflow, input, opts ->
      send(parent, {:scheduled_round, workflow, input, opts})
      {:ok, "round_1"}
    end

    scheduler =
      start_supervised!(
        {Scheduler,
         name: nil,
         runner: runner,
         breech: :test_breech,
         jobs: [
           %{
             id: "job_1",
             workflow: @workflow,
             input: %{"cluster" => "dev"},
             interval_ms: 50,
             initial_delay_ms: 0,
             opts: [provider: :mock]
           }
         ]}
      )

    assert_receive {:scheduled_round, @workflow, %{"cluster" => "dev"}, opts}, 100
    assert opts[:provider] == :mock
    assert opts[:server] == :test_breech
    assert opts[:admission_policy] == :scheduled
    assert opts[:scheduler?]

    assert %{status: "running", jobs: [job]} = Scheduler.status(scheduler)
    assert job.id == "job_1"
    assert job.schedule == "interval"
    assert job.interval_ms == 50
    assert job.cron == nil
    assert job.fired >= 1
    assert job.last_error == nil
  end

  test "fires cron jobs through the runner at the next matching minute" do
    parent = self()

    runner = fn workflow, input, opts ->
      send(parent, {:cron_round, workflow, input, opts})
      {:ok, "round_cron"}
    end

    scheduler =
      start_supervised!(
        {Scheduler,
         name: nil,
         runner: runner,
         breech: :cron_breech,
         now_fun: fn -> DateTime.from_iso8601("2026-05-02T12:00:59.950Z") |> elem(1) end,
         jobs: [
           %{
             id: "job_cron",
             workflow: @workflow,
             input: %{"cluster" => "prod"},
             cron: "1 * * * *"
           }
         ]}
      )

    assert_receive {:cron_round, @workflow, %{"cluster" => "prod"}, opts}, 150
    assert opts[:server] == :cron_breech
    assert opts[:admission_policy] == :scheduled
    assert opts[:scheduler?]

    assert %{status: "running", jobs: [job]} = Scheduler.status(scheduler)
    assert job.id == "job_cron"
    assert job.schedule == "cron"
    assert job.interval_ms == nil
    assert job.cron == "1 * * * *"
    assert job.fired >= 1
  end

  test "records runner errors and continues scheduling" do
    parent = self()

    runner = fn _workflow, _input, _opts ->
      send(parent, :attempted)
      {:error, :boom}
    end

    scheduler =
      start_supervised!(
        {Scheduler,
         name: nil,
         runner: runner,
         jobs: [
           %{
             id: "job_error",
             workflow: @workflow,
             input: %{},
             interval_ms: 50,
             initial_delay_ms: 0
           }
         ]}
      )

    assert_receive :attempted, 100

    assert %{jobs: [%{id: "job_error", fired: 0, last_error: ":boom"}]} =
             Scheduler.status(scheduler)
  end

  test "rejects invalid jobs at startup" do
    assert {:error, {%Twelvgaige.Error{reason: :invalid_shell}, _child}} =
             start_supervised(
               {Scheduler,
                name: nil,
                jobs: [
                  %{id: "bad", workflow: @workflow, input: %{}, interval_ms: 0}
                ]}
             )
  end

  test "rejects jobs with both interval and cron schedules" do
    assert {:error, {%Twelvgaige.Error{message: message}, _child}} =
             start_supervised(
               {Scheduler,
                name: nil,
                jobs: [
                  %{
                    id: "bad",
                    workflow: @workflow,
                    input: %{},
                    interval_ms: 1000,
                    cron: "* * * * *"
                  }
                ]}
             )

    assert message == "scheduler job must set either interval_ms or cron, not both"
  end
end
