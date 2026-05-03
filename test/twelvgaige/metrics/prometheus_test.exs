defmodule Twelvgaige.Metrics.PrometheusTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Metrics.Prometheus

  test "renders low-cardinality Prometheus resource metrics" do
    text =
      Prometheus.render(%{
        profile: "laptop",
        uptime_ms: 1234,
        active_rounds: 2,
        store: %{
          incomplete_rounds: 1,
          rounds: 4,
          terminal_rounds: 3,
          round_events: 7,
          audit_events: 9,
          attempt_journals: 5,
          tool_journals: 6,
          retained_bytes: 2048,
          retained_bytes_limit: 4096,
          retained_bytes_over_limit: false,
          evicted_rounds: 2
        },
        resources: %{
          used: %{"llm_call" => 1},
          limits: %{"llm_call" => 4},
          queue_depth: %{"llm_call" => 0},
          denials: [
            %{resource_kind: "llm_call", reason: "limit_exceeded", count: 3}
          ]
        },
        metrics: %{
          counters: [
            %{
              name: "twelvgaige_rounds_total",
              labels: [{"status", "complete"}, {"workflow_id", "wf"}],
              value: 2
            }
          ],
          histograms: [
            %{
              name: "twelvgaige_round_duration_seconds",
              labels: [{"status", "complete"}, {"workflow_id", "wf"}],
              buckets: [0.1, 1.0],
              bucket_counts: %{0.1 => 1, 1.0 => 2},
              count: 2,
              sum: 0.6
            }
          ]
        }
      })

    assert text =~ "# TYPE twelvgaige_up gauge\n"
    assert text =~ "twelvgaige_up 1\n"
    assert text =~ ~s(twelvgaige_rounds_active{profile="laptop"} 2)
    assert text =~ ~s(twelvgaige_store_rounds_retained{profile="laptop"} 4)
    assert text =~ ~s(twelvgaige_store_terminal_rounds_retained{profile="laptop"} 3)
    assert text =~ ~s(twelvgaige_store_round_events_retained{profile="laptop"} 7)
    assert text =~ ~s(twelvgaige_store_audit_events_retained{profile="laptop"} 9)
    assert text =~ ~s(twelvgaige_store_attempt_journals_retained{profile="laptop"} 5)
    assert text =~ ~s(twelvgaige_store_tool_journals_retained{profile="laptop"} 6)
    assert text =~ ~s(twelvgaige_store_retained_bytes{profile="laptop"} 2048)
    assert text =~ ~s(twelvgaige_store_retained_bytes_limit{profile="laptop"} 4096)
    assert text =~ ~s(twelvgaige_store_retained_bytes_over_limit{profile="laptop"} 0)
    assert text =~ ~s(twelvgaige_store_retention_evictions_total{profile="laptop"} 2)

    assert text =~
             ~s(twelvgaige_resource_permits_active{resource_kind="llm_call",profile="laptop"} 1)

    assert text =~ ~s(twelvgaige_resource_limit{resource_kind="llm_call",profile="laptop"} 4)

    assert text =~
             ~s(twelvgaige_resource_queue_depth{resource_kind="llm_call",profile="laptop"} 0)

    assert text =~
             ~s(twelvgaige_resource_denials_total{resource_kind="llm_call",reason="limit_exceeded",profile="laptop"} 3)

    assert text =~
             ~s(twelvgaige_rounds_total{status="complete",workflow_id="wf"} 2)

    assert text =~
             ~s(twelvgaige_round_duration_seconds_bucket{status="complete",workflow_id="wf",le="1"} 2)

    assert text =~
             ~s(twelvgaige_round_duration_seconds_count{status="complete",workflow_id="wf"} 2)
  end
end
