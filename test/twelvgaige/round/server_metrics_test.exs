defmodule Twelvgaige.Round.ServerMetricsTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Metrics
  alias Twelvgaige.Round.ServerMetrics
  alias Twelvgaige.Round.Snapshot

  test "records round, shot, and safety metrics through injectable collector" do
    {:ok, metrics} = Metrics.start_link(name: nil)

    snapshot =
      Snapshot.new(
        id: "round_1",
        shell_id: "shell",
        shell_version: "1.0.0",
        status: :complete
      )

    started = ServerMetrics.monotonic_ms()

    assert :ok = ServerMetrics.record_round({:ok, snapshot}, "shell", started, metrics: metrics)
    assert :ok = ServerMetrics.record_shot(%{kind: :slug}, {:ok, %{}}, started, metrics: metrics)
    assert :ok = ServerMetrics.record_safety_decision(:approved, metrics: metrics)

    snapshot = Metrics.snapshot(metrics)

    counter_names =
      snapshot.counters
      |> Enum.map(& &1.name)
      |> MapSet.new()

    histogram_names =
      snapshot.histograms
      |> Enum.map(& &1.name)
      |> MapSet.new()

    assert MapSet.subset?(
             MapSet.new([
               "twelvgaige_rounds_total",
               "twelvgaige_shot_attempts_total",
               "twelvgaige_safety_decisions_total"
             ]),
             counter_names
           )

    assert MapSet.subset?(
             MapSet.new([
               "twelvgaige_round_duration_seconds",
               "twelvgaige_shot_duration_seconds"
             ]),
             histogram_names
           )
  end
end
