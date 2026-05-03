defmodule Twelvgaige.MetricsTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Metrics
  alias Twelvgaige.ResourceLimiter
  alias Twelvgaige.Round.Runner
  alias Twelvgaige.Shell.Workflow

  defp start_metrics do
    start_supervised!({Metrics, name: nil})
  end

  test "records counters and histograms with sanitized low-cardinality labels" do
    metrics = start_metrics()

    assert :ok =
             Metrics.counter("twelvgaige_rounds_total", %{status: :complete}, 2, metrics: metrics)

    assert :ok =
             Metrics.observe(
               "twelvgaige_round_duration_seconds",
               0.2,
               %{status: :complete},
               metrics: metrics,
               buckets: [0.1, 0.5]
             )

    assert eventually(fn ->
             snapshot = Metrics.snapshot(metrics)

             Enum.any?(
               snapshot.counters,
               &(&1.name == "twelvgaige_rounds_total" and &1.value == 2)
             ) and
               Enum.any?(
                 snapshot.histograms,
                 &(&1.name == "twelvgaige_round_duration_seconds" and &1.count == 1 and
                     &1.bucket_counts[0.5] == 1)
               )
           end)

    json_safe = metrics |> Metrics.snapshot() |> Metrics.to_map()
    assert Jason.encode!(json_safe) =~ "twelvgaige_rounds_total"
  end

  test "rejects high-cardinality metric labels" do
    assert {:error, {:high_cardinality_label, "round_id"}} =
             Metrics.sanitize_labels(%{round_id: "round_123"})

    metrics = start_metrics()

    assert :ok =
             Metrics.counter("twelvgaige_rounds_total", %{round_id: "round_123"}, 1,
               metrics: metrics
             )

    assert Metrics.snapshot(metrics).counters == []
  end

  test "round execution records round, shot, llm, and safety metrics" do
    metrics = start_metrics()

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "metrics_workflow",
        version: "1.0.0",
        shots: [
          %{id: "approval", kind: :safety, description: "review"},
          %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"]}
        ]
      })

    assert {:ok, snapshot} =
             Runner.run(workflow, %{},
               metrics: metrics,
               limiter: nil,
               safety_decisions: %{"approval" => :approved}
             )

    assert snapshot.status == :complete

    assert eventually(fn ->
             names = metric_names(Metrics.snapshot(metrics))

             "twelvgaige_rounds_total" in names and
               "twelvgaige_shot_attempts_total" in names and
               "twelvgaige_llm_calls_total" in names and
               "twelvgaige_llm_tokens_total" in names and
               "twelvgaige_safety_decisions_total" in names
           end)
  end

  test "resource limiter records queued wait histograms" do
    metrics = start_metrics()

    limiter =
      start_supervised!({ResourceLimiter, name: nil, metrics: metrics, limits: %{llm_call: 1}})

    assert {:ok, permit} = ResourceLimiter.acquire(:llm_call, server: limiter)

    assert {:queued, waiter} =
             ResourceLimiter.acquire(:llm_call, %{}, server: limiter, queue?: true)

    assert :ok = ResourceLimiter.release(permit)
    assert_receive {:resource_available, waiter_id, :llm_call}, 100
    assert waiter_id == waiter.id

    assert eventually(fn ->
             snapshot = Metrics.snapshot(metrics)

             counter_recorded? =
               Enum.any?(snapshot.counters, fn counter ->
                 counter.name == "twelvgaige_resource_queue_total" and
                   {"profile", "laptop"} in counter.labels and
                   {"resource_kind", "llm_call"} in counter.labels and counter.value == 1
               end)

             histogram_recorded? =
               Enum.any?(snapshot.histograms, fn histogram ->
                 histogram.name == "twelvgaige_resource_queue_seconds" and
                   {"profile", "laptop"} in histogram.labels and
                   {"resource_kind", "llm_call"} in histogram.labels and
                   {"status", "granted"} in histogram.labels and
                   histogram.count == 1
               end)

             counter_recorded? and histogram_recorded?
           end)
  end

  defp metric_names(snapshot) do
    counter_names = Enum.map(snapshot.counters, & &1.name)
    histogram_names = Enum.map(snapshot.histograms, & &1.name)
    counter_names ++ histogram_names
  end

  defp eventually(fun), do: eventually(fun, 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts_left) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts_left - 1)
    end
  end
end
