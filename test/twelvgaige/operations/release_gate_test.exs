defmodule Twelvgaige.Operations.ReleaseGateTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Operations.{ReleaseGate, SLO}

  test "checked-in release matrix remains closed until attached-session evidence exists" do
    report = ReleaseGate.evaluate(File.cwd!(), now: qualification_now(File.cwd!()))
    assert report.status == :fail
    assert length(report.checks) == 20

    attached = Enum.filter(report.checks, &(&1.kind == :attached_session))
    assert length(attached) == 2
    assert Enum.all?(attached, &(&1.result.reason == :qualification_evidence_missing))

    assert report.checks
           |> Enum.reject(&(&1.kind == :attached_session))
           |> Enum.all?(&(&1.result.status == :pass))
  end

  test "release matrix accepts complete attached-session lifecycle evidence" do
    root = fixture_root("attached-session-pass")
    generated_at = qualification_now(root) |> DateTime.to_iso8601()

    write_attached_evidence(root, "podman", generated_at)
    write_attached_evidence(root, "apple-container", generated_at)

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    assert report.status == :pass
    assert Enum.all?(report.checks, &(&1.result.status == :pass))
  end

  test "release matrix rejects incomplete attached-session cleanup evidence" do
    root = fixture_root("attached-session-fail")
    generated_at = qualification_now(root) |> DateTime.to_iso8601()

    write_attached_evidence(root, "podman", generated_at, lifecycle: %{"exact_cleanup" => false})

    write_attached_evidence(root, "apple-container", generated_at)

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    check = Enum.find(report.checks, &(&1.id == :podman_attached_session))

    assert report.status == :fail
    assert check.result.reason == :attached_session_security_gate_failed
  end

  test "release matrix rejects a platform support claim without named evidence" do
    root = fixture_root("support-matrix-overclaim")
    path = Path.join(root, "qualification/platform-matrix.json")
    matrix = path |> File.read!() |> Jason.decode!()

    matrix =
      put_in(matrix, ["platforms", "linux-x86_64", "cli_contract"], %{
        "status" => "locally_qualified",
        "evidence" => "qualification/evidence/cli/linux.json"
      })

    File.write!(path, Jason.encode_to_iodata!(matrix, pretty: true))

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    check = Enum.find(report.checks, &(&1.id == :platform_support_matrix))

    assert report.status == :fail
    assert check.result.reason == :support_matrix_evidence_missing
  end

  test "release matrix validates the retained developer CLI contract rather than its status alone" do
    root = fixture_root("developer-cli-contract")
    path = Path.join(root, "qualification/evidence/cli/developer-workflow.json")
    evidence = path |> File.read!() |> Jason.decode!()
    evidence = put_in(evidence, ["contracts", "versioned_result_envelope"], "fail")
    File.write!(path, Jason.encode_to_iodata!(evidence, pretty: true))

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    check = Enum.find(report.checks, &(&1.id == :developer_cli))

    assert check.result.reason == :developer_cli_contract_failed
  end

  test "release matrix requires every authoritative lifecycle fault case exactly once" do
    root = fixture_root("fault-matrix-contract")
    path = Path.join(root, "qualification/evidence/lifecycle/fault-matrix.json")
    evidence = path |> File.read!() |> Jason.decode!()
    evidence = %{evidence | "cases" => tl(evidence["cases"])}
    File.write!(path, Jason.encode_to_iodata!(evidence, pretty: true))

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    check = Enum.find(report.checks, &(&1.id == :lifecycle_fault_matrix))

    assert check.result.reason == :lifecycle_fault_matrix_incomplete
  end

  test "release matrix rejects incomplete previous-release migration evidence" do
    root = fixture_root("migration-contract")
    path = Path.join(root, "qualification/evidence/migrations/previous-release.json")
    evidence = path |> File.read!() |> Jason.decode!()
    evidence = put_in(evidence, ["checks", "fixture_integrity"], "fail")
    File.write!(path, Jason.encode_to_iodata!(evidence, pretty: true))

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    check = Enum.find(report.checks, &(&1.id == :previous_release_migration))

    assert check.result.reason == :previous_release_migration_incomplete
  end

  test "release matrix binds workspace evidence to the published minimum Git version" do
    root = fixture_root("minimum-git-contract")
    path = Path.join(root, "qualification/evidence/workspace/git-2.39.0-macos-arm64.json")
    evidence = path |> File.read!() |> Jason.decode!()
    evidence = put_in(evidence, ["host", "git_version"], "2.38.5")
    File.write!(path, Jason.encode_to_iodata!(evidence, pretty: true))

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    check = Enum.find(report.checks, &(&1.id == :minimum_git_workspace))

    assert check.result.reason == :minimum_git_workspace_contract_failed
  end

  test "release matrix checks every packaged interrupt invariant" do
    root = fixture_root("release-interrupt-contract")
    path = Path.join(root, "qualification/evidence/cli/release-interrupt.json")
    evidence = path |> File.read!() |> Jason.decode!()
    evidence = put_in(evidence, ["checks", "child_process_reaped"], false)
    File.write!(path, Jason.encode_to_iodata!(evidence, pretty: true))

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    check = Enum.find(report.checks, &(&1.id == :release_cli_interrupt))

    assert check.result.reason == :release_cli_interrupt_contract_failed
  end

  test "artifact-required release qualification binds interrupt evidence to the packaged launcher" do
    root = fixture_root("release-interrupt-launcher")
    launcher = Path.join(root, "_build/prod/rel/twelvgaige_native/bin/twelvgaige_interrupt")
    File.mkdir_p!(Path.dirname(launcher))
    File.write!(launcher, "not the qualified launcher")

    report =
      ReleaseGate.evaluate(root,
        now: qualification_now(root),
        require_artifacts?: true
      )

    check = Enum.find(report.checks, &(&1.id == :release_cli_interrupt))
    assert check.result.reason == :release_cli_interrupt_contract_failed
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

  test "release gate rejects independent verification that gains credentials or network" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-verification-gate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.cp_r!("qualification", Path.join(root, "qualification"))
    File.cp_r!("test", Path.join(root, "test"))
    on_exit(fn -> File.rm_rf!(root) end)

    path =
      Path.join(
        root,
        "qualification/evidence/verification/podman-live-qualification.json"
      )

    evidence = path |> File.read!() |> Jason.decode!()
    evidence = put_in(evidence, ["security", "credential_free"], "fail")
    File.write!(path, Jason.encode_to_iodata!(evidence, pretty: true))

    report = ReleaseGate.evaluate(root, now: qualification_now(root))
    check = Enum.find(report.checks, &(&1.id == :podman_independent_verification))

    assert report.status == :fail
    assert check.result.reason == :independent_verification_security_gate_failed
  end

  defp qualification_now(root) do
    newest =
      [
        "qualification/evidence/operations/live-qualification.json",
        "qualification/evidence/verification/podman-live-qualification.json",
        "qualification/evidence/verification/apple-container-live-qualification.json",
        "qualification/evidence/cli/developer-workflow.json",
        "qualification/evidence/lifecycle/fault-matrix.json",
        "qualification/evidence/migrations/previous-release.json",
        "qualification/evidence/workspace/git-2.39.0-macos-arm64.json",
        "qualification/evidence/cli/release-interrupt.json"
      ]
      |> Enum.map(fn relative ->
        evidence = root |> Path.join(relative) |> File.read!() |> Jason.decode!()
        generated_at = evidence["generated_at"] || evidence["observed_at"]

        {:ok, generated, _offset} = DateTime.from_iso8601(generated_at)
        generated
      end)
      |> Enum.max_by(&DateTime.to_unix(&1, :microsecond))

    DateTime.add(newest, 60, :second)
  end

  defp fixture_root(name) do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-#{name}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.cp_r!("qualification", Path.join(root, "qualification"))
    File.cp_r!("test", Path.join(root, "test"))
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp write_attached_evidence(root, backend, generated_at, overrides \\ []) do
    lifecycle =
      %{
        "provider_initialized_inside_sandbox" => true,
        "turn_completed" => true,
        "runtime_quiescence_proven" => true,
        "exact_cleanup" => true
      }
      |> Map.merge(Map.new(Keyword.get(overrides, :lifecycle, %{})))

    evidence = %{
      "schema_version" => 1,
      "generated_at" => generated_at,
      "result" => "pass",
      "backend" => backend,
      "sandbox" => %{
        "attached_stdio" => true,
        "detached_start_used" => false,
        "source_host_mount_visible_to_worker" => false,
        "outer_sandbox_authoritative" => true
      },
      "auth" => %{
        "persisted_in_result" => false,
        "source_mounted_in_worker" => false
      },
      "result_capture" => %{
        "complete_workspace_repatriated" => true,
        "exact_file_verified" => true
      },
      "lifecycle" => lifecycle
    }

    path = Path.join([root, "qualification", "evidence", "attached-session", "#{backend}.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode_to_iodata!(evidence, pretty: true))
  end
end
