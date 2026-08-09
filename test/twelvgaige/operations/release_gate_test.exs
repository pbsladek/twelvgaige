defmodule Twelvgaige.Operations.ReleaseGateTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Operations.{ReleaseGate, SLO}

  test "checked-in supported driver/backend matrix passes current security and latency gates" do
    report = ReleaseGate.evaluate(File.cwd!(), now: qualification_now(File.cwd!()))
    assert report.status == :pass
    assert length(report.checks) == 10
    assert Enum.all?(report.checks, &(&1.result.status == :pass))
  end

  test "SLO evaluation fails closed on missing measures and accounts for exhausted error budget" do
    observations = %{
      availability_percent: 99.0,
      launch_success_percent: 99.5,
      launch_p95_ms: 500,
      cancellation_p95_ms: 2_000,
      recovery_success_percent: 99.5,
      recovery_p95_ms: 5_000,
      queue_admission_p95_ms: 1_000,
      retention_run_success_percent: 100.0,
      retention_max_lag_seconds: 1_000
    }

    assert {:ok, report} = SLO.evaluate(:podman_macos_arm64, observations)
    assert report.status == :fail
    assert report.checks.availability.status == :fail
    assert report.error_budgets.availability_percent.exhausted

    assert {:ok, missing} = SLO.evaluate(:podman_macos_arm64, %{})
    assert missing.status == :fail
    assert missing.checks.launch_latency.status == :missing
  end

  test "release gate rejects a proxy image record that no longer matches its signature" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-release-gate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.cp_r!("qualification", Path.join(root, "qualification"))
    on_exit(fn -> File.rm_rf!(root) end)

    record = Path.join(root, "qualification/evidence/egress-proxy/image-record.json")
    File.write!(record, String.replace(File.read!(record), "\"high\": 0", "\"high\": 1"))

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    check = Enum.find(report.checks, &(&1.id == :egress_proxy_image))

    assert report.status == :fail
    assert check.result.status == :fail
    assert check.result.reason == :egress_image_signature_invalid
  end

  test "release gate rejects incomplete or stale operational security evidence" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-operations-gate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.cp_r!("qualification", Path.join(root, "qualification"))
    File.cp_r!("test", Path.join(root, "test"))
    on_exit(fn -> File.rm_rf!(root) end)

    path = Path.join(root, "qualification/evidence/operations/live-qualification.json")
    evidence = path |> File.read!() |> Jason.decode!()

    tampered =
      put_in(
        evidence,
        ["security_contract", "checks", "backup_authority_stripping"],
        "fail"
      )

    File.write!(path, Jason.encode_to_iodata!(tampered, pretty: true))

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    check = Enum.find(report.checks, &(&1.id == :operations_slo))

    assert report.status == :fail
    assert check.result.reason == :operations_slo_gate_failed
  end

  test "release gate fails when a supported backend or driver contract regresses" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-supported-matrix-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.cp_r!("qualification", Path.join(root, "qualification"))
    File.cp_r!("test", Path.join(root, "test"))
    on_exit(fn -> File.rm_rf!(root) end)

    backend_path =
      Path.join(root, "qualification/evidence/podman-worker/live-qualification.json")

    backend = backend_path |> File.read!() |> Jason.decode!()
    backend = put_in(backend, ["security", "network_none"], "fail")
    File.write!(backend_path, Jason.encode_to_iodata!(backend, pretty: true))

    driver_path =
      Path.join(
        root,
        "qualification/evidence/podman-worker/codex-app-server-provider-qualification.json"
      )

    driver = driver_path |> File.read!() |> Jason.decode!()
    driver = put_in(driver, ["protocol", "schema_digest"], "sha256:regressed")
    File.write!(driver_path, Jason.encode_to_iodata!(driver, pretty: true))

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    podman = Enum.find(report.checks, &(&1.id == :podman_live))
    codex = Enum.find(report.checks, &(&1.id == :podman_codex_app_server))

    assert report.status == :fail
    assert podman.result.reason == :backend_security_gate_failed
    assert codex.result.reason == :codex_app_server_protocol_gate_failed
  end

  defp qualification_now(root) do
    newest =
      [
        "qualification/evidence/operations/live-qualification.json"
      ]
      |> Enum.map(fn relative ->
        generated_at =
          root
          |> Path.join(relative)
          |> File.read!()
          |> Jason.decode!()
          |> Map.fetch!("generated_at")

        {:ok, generated, _offset} = DateTime.from_iso8601(generated_at)
        generated
      end)
      |> Enum.max_by(&DateTime.to_unix(&1, :microsecond))

    DateTime.add(newest, 60, :second)
  end
end
