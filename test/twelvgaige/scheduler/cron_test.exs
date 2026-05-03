defmodule Twelvgaige.Scheduler.CronTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Scheduler.Cron

  test "parses portable five-field cron expressions" do
    assert {:ok, cron} = Cron.parse("*/15 9-17/2 * 1,6 1-5")

    assert MapSet.equal?(cron.minutes, MapSet.new([0, 15, 30, 45]))
    assert MapSet.equal?(cron.hours, MapSet.new([9, 11, 13, 15, 17]))
    assert MapSet.equal?(cron.months, MapSet.new([1, 6]))
    assert MapSet.equal?(cron.weekdays, MapSet.new(1..5))
    assert cron.day_wildcard?
    refute cron.weekday_wildcard?
  end

  test "accepts both 0 and 7 as Sunday" do
    assert {:ok, zero} = Cron.parse("0 0 * * 0")
    assert {:ok, seven} = Cron.parse("0 0 * * 7")

    assert MapSet.equal?(zero.weekdays, MapSet.new([0]))
    assert MapSet.equal?(seven.weekdays, MapSet.new([0]))
  end

  test "calculates the next delay on minute boundaries" do
    assert {:ok, cron} = Cron.parse("1 * * * *")
    now = DateTime.from_iso8601("2026-05-02T12:00:59.950Z") |> elem(1)

    assert {:ok, 50} = Cron.next_delay_ms(cron, now)
    assert {:ok, next_run} = Cron.next_run_after(cron, now)
    assert DateTime.to_iso8601(next_run) == "2026-05-02T12:01:00.000Z"
  end

  test "uses cron day-of-month and day-of-week OR semantics when both are restricted" do
    assert {:ok, cron} = Cron.parse("0 0 13 * 1")
    now = DateTime.from_iso8601("2026-05-02T00:00:00Z") |> elem(1)

    assert {:ok, next_run} = Cron.next_run_after(cron, now)
    assert DateTime.to_iso8601(next_run) == "2026-05-04T00:00:00.000Z"
  end

  test "rejects invalid cron expressions" do
    assert {:error, error} = Cron.parse("* * * *")
    assert error.message == "cron expression must have exactly five fields"

    assert {:error, error} = Cron.parse("*/0 * * * *")
    assert error.message == "cron minute step must be positive"

    assert {:error, error} = Cron.parse("60 * * * *")
    assert error.message == "cron minute value out of range"
  end
end
