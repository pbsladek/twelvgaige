defmodule Twelvgaige.Workspace.PerformanceQualificationTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.PerformanceQualification

  test "accepts complete measurements at their release ceilings" do
    limits = PerformanceQualification.default_limits()

    measurements = %{
      repository_inspection_ms: limits.repository_inspection_ms,
      source_capture_ms: limits.source_capture_ms,
      result_capture_ms: limits.result_capture_ms,
      manifest_verification_ms: limits.manifest_verification_ms,
      memory_growth_bytes: limits.memory_growth_bytes,
      source_disk_bytes: 1_000,
      managed_disk_bytes: 4_000
    }

    assert %{status: "pass", checks: checks} =
             PerformanceQualification.evaluate(measurements)

    assert Enum.all?(checks, &(&1.status == "pass"))
  end

  test "fails every exceeded or missing measurement explicitly" do
    report =
      PerformanceQualification.evaluate(%{
        "repository_inspection_ms" => 10_001,
        "source_capture_ms" => 1,
        "result_capture_ms" => 1,
        "manifest_verification_ms" => 1,
        "memory_growth_bytes" => 1,
        "source_disk_bytes" => 1_000,
        "managed_disk_bytes" => 4_001
      })

    assert report.status == "fail"

    assert %{status: "fail"} =
             Enum.find(report.checks, &(&1.metric == :repository_inspection_ms))

    assert %{status: "fail"} =
             Enum.find(report.checks, &(&1.metric == :disk_amplification_milli))

    missing = PerformanceQualification.evaluate(%{})
    assert missing.status == "fail"
    assert Enum.all?(missing.checks, &(&1.status == "missing"))
  end
end
