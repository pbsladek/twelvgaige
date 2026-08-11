defmodule Twelvgaige.Operations.ReleaseGate do
  @moduledoc "Fail-closed driver, backend, security, and SLO release matrix."

  alias Twelvgaige.DelegatedSession.Codex.Schema
  alias Twelvgaige.Lifecycle.FaultMatrix
  alias Twelvgaige.Operations.{ProtocolConformance, SLO}

  @matrix [
    %{
      id: :codex_schema,
      kind: :protocol,
      check: :codex_schema
    },
    %{
      id: :codex_app_server_fixture,
      kind: :protocol,
      check: :codex_app_server_fixture
    },
    %{
      id: :developer_cli,
      kind: :developer_cli,
      evidence: "qualification/evidence/cli/developer-workflow.json"
    },
    %{
      id: :lifecycle_fault_matrix,
      kind: :lifecycle_fault_matrix,
      evidence: "qualification/evidence/lifecycle/fault-matrix.json"
    },
    %{
      id: :previous_release_migration,
      kind: :previous_release_migration,
      evidence: "qualification/evidence/migrations/previous-release.json",
      previous_release: "0.0.3"
    },
    %{
      id: :minimum_git_workspace,
      kind: :minimum_git_workspace,
      evidence: "qualification/evidence/workspace/git-2.39.0-macos-arm64.json",
      minimum_git_version: "2.39.0"
    },
    %{
      id: :release_cli_interrupt,
      kind: :release_cli_interrupt,
      evidence: "qualification/evidence/cli/release-interrupt.json",
      launcher: "_build/prod/rel/twelvgaige_native/bin/twelvgaige_interrupt"
    },
    %{
      id: :podman_live,
      kind: :backend,
      evidence: "qualification/evidence/podman-worker/live-qualification.json",
      slo_profile: :podman_macos_arm64
    },
    %{
      id: :podman_codex,
      kind: :driver_backend,
      evidence: "qualification/evidence/podman-worker/codex-provider-qualification.json"
    },
    %{
      id: :podman_codex_app_server,
      kind: :driver_backend,
      evidence:
        "qualification/evidence/podman-worker/codex-app-server-provider-qualification.json",
      protocol: :codex_app_server
    },
    %{
      id: :apple_container_live,
      kind: :backend,
      evidence: "qualification/evidence/apple-container/live-qualification.json",
      slo_profile: :apple_container_macos_arm64
    },
    %{
      id: :apple_container_codex,
      kind: :driver_backend,
      evidence: "qualification/evidence/apple-container/codex-provider-qualification.json"
    },
    %{
      id: :podman_attached_session,
      kind: :attached_session,
      backend: "podman",
      evidence: "qualification/evidence/attached-session/podman.json"
    },
    %{
      id: :apple_container_attached_session,
      kind: :attached_session,
      backend: "apple-container",
      evidence: "qualification/evidence/attached-session/apple-container.json"
    },
    %{
      id: :podman_independent_verification,
      kind: :independent_verification,
      evidence: "qualification/evidence/verification/podman-live-qualification.json"
    },
    %{
      id: :apple_container_independent_verification,
      kind: :independent_verification,
      evidence: "qualification/evidence/verification/apple-container-live-qualification.json"
    },
    %{
      id: :egress_proxy_image,
      kind: :supply_chain,
      check: :egress_proxy_image
    },
    %{
      id: :egress_boundary_live,
      kind: :network_boundary,
      check: :egress_boundary_live
    },
    %{
      id: :platform_support_matrix,
      kind: :support_matrix,
      check: :platform_support_matrix
    },
    %{
      id: :operations_slo,
      kind: :operations,
      evidence: "qualification/evidence/operations/live-qualification.json"
    }
  ]

  def matrix, do: @matrix

  def evaluate(root \\ File.cwd!(), opts \\ []) do
    max_age_days = Keyword.get(opts, :max_age_days, 30)
    now = Keyword.get(opts, :now, DateTime.utc_now())
    require_artifacts? = Keyword.get(opts, :require_artifacts?, false)

    checks =
      Enum.map(@matrix, fn
        %{check: :codex_schema} = entry ->
          Map.put(entry, :result, normalize_result(Schema.verify_bundle()))

        %{check: :codex_app_server_fixture} = entry ->
          result =
            root
            |> ProtocolConformance.codex_fixture_path()
            |> ProtocolConformance.verify_codex()

          Map.put(entry, :result, normalize_result(result))

        %{check: :egress_proxy_image} = entry ->
          result = egress_proxy_image_check(root, now, max_age_days, require_artifacts?)
          Map.put(entry, :result, result)

        %{check: :egress_boundary_live} = entry ->
          result = egress_boundary_check(root, now, max_age_days)
          Map.put(entry, :result, result)

        %{check: :platform_support_matrix} = entry ->
          result = platform_support_matrix_check(root)
          Map.put(entry, :result, result)

        %{evidence: relative} = entry ->
          result =
            evidence_check(
              root,
              Path.join(root, relative),
              entry,
              now,
              max_age_days,
              require_artifacts?
            )

          Map.put(entry, :result, result)
      end)

    status = if Enum.all?(checks, &(&1.result.status == :pass)), do: :pass, else: :fail
    %{schema_version: 1, slo_version: SLO.version(), status: status, checks: checks}
  end

  defp evidence_check(root, path, entry, now, max_age_days, require_artifacts?) do
    with {:ok, encoded} <- File.read(path),
         {:ok, evidence} <- Jason.decode(encoded),
         :ok <- passed(entry, evidence),
         :ok <- fresh(evidence, now, max_age_days),
         :ok <- qualification_complete(root, entry, evidence, require_artifacts?),
         :ok <- security_complete(entry, evidence),
         :ok <- protocol_complete(entry, evidence),
         :ok <- performance_within_slo(entry, evidence),
         :ok <- operations_complete(root, entry, evidence) do
      %{
        status: :pass,
        path: path,
        generated_at: evidence["generated_at"] || evidence["observed_at"]
      }
    else
      {:error, :enoent} ->
        %{status: :fail, path: path, reason: :qualification_evidence_missing}

      {:error, reason} ->
        %{status: :fail, path: path, reason: reason}
    end
  end

  defp passed(%{kind: kind}, %{"status" => "pass"})
       when kind in [:developer_cli, :previous_release_migration, :minimum_git_workspace],
       do: :ok

  defp passed(%{kind: kind}, %{"qualified" => true})
       when kind in [:lifecycle_fault_matrix, :release_cli_interrupt],
       do: :ok

  defp passed(_entry, %{"result" => "pass"}), do: :ok
  defp passed(_entry, _evidence), do: {:error, :qualification_failed}

  defp fresh(%{"generated_at" => generated_at}, now, max_age_days) do
    with {:ok, generated, _offset} <- DateTime.from_iso8601(generated_at),
         age_seconds = DateTime.diff(now, generated, :second),
         true <- age_seconds >= -300 and age_seconds <= max_age_days * 86_400 do
      :ok
    else
      false -> {:error, :qualification_stale}
      _other -> {:error, :qualification_timestamp_invalid}
    end
  end

  defp fresh(%{"observed_at" => observed_at}, now, max_age_days) do
    fresh(%{"generated_at" => observed_at}, now, max_age_days)
  end

  defp fresh(_evidence, _now, _max_age_days), do: {:error, :qualification_timestamp_missing}

  defp qualification_complete(_root, %{kind: :developer_cli}, evidence, _require_artifacts?) do
    required_contracts = [
      "configuration_provenance",
      "help_common_path",
      "completion_generation",
      "repository_inspection_json",
      "task_validation_json",
      "session_plan_no_mutation",
      "saved_plan_exact_handoff",
      "saved_plan_owner_only",
      "session_plan_task_redaction",
      "typed_command_model",
      "exhaustive_command_shape_completion_parity",
      "exhaustive_command_semantic_parser_parity",
      "complete_typed_default_inventory",
      "missing_daemon_fail_closed",
      "versioned_result_envelope"
    ]

    contracts = evidence["contracts"] || %{}

    valid? =
      evidence["schema_version"] == 1 and
        evidence["scope"] == "public no-mutation developer CLI" and
        Enum.all?(required_contracts, &(contracts[&1] == "pass")) and
        measurements_within_limits?(evidence)

    if valid?, do: :ok, else: {:error, :developer_cli_contract_failed}
  end

  defp qualification_complete(
         _root,
         %{kind: :lifecycle_fault_matrix},
         evidence,
         _require_artifacts?
       ) do
    cases = evidence["cases"] || []
    observed = cases |> Enum.map(& &1["case_id"]) |> MapSet.new()
    expected = FaultMatrix.case_ids()

    valid? =
      evidence["schema_version"] == 1 and
        evidence["schema"] == "twelvgaige.lifecycle-fault-evidence" and
        evidence["matrix_schema_version"] == FaultMatrix.schema_version() and
        evidence["case_count"] == MapSet.size(expected) and length(cases) == MapSet.size(expected) and
        observed == expected and
        Enum.all?(cases, fn fault_case ->
          fault_case["outcome"] in [
            "safe_resume",
            "validated_compensation",
            "needs_reconciliation"
          ] and is_map(fault_case["metadata"]) and
            is_binary(get_in(fault_case, ["metadata", "suite"]))
        end)

    if valid?, do: :ok, else: {:error, :lifecycle_fault_matrix_incomplete}
  end

  defp qualification_complete(
         root,
         %{kind: :previous_release_migration, previous_release: previous_release},
         evidence,
         _require_artifacts?
       ) do
    required_checks = [
      "completed_record_readable",
      "fixture_integrity",
      "interrupted_write_not_retried",
      "legacy_audit_chain_migrated",
      "manifest_and_events_readable",
      "previous_release_provenance",
      "reconciliation_persisted_after_restart",
      "result_manifest_v1_digest_preserved",
      "snapshot_schema_upgraded"
    ]

    checks = evidence["checks"] || %{}
    scope = evidence["scope"] || %{}
    artifacts = evidence["artifacts"] || %{}

    valid? =
      evidence["schema_version"] == 1 and scope["previous_release"] == previous_release and
        scope["consumer_version"] == current_version() and
        scope["canonical_contract"] == "result-manifest-v1" and
        Enum.sort(scope["persisted_stores"] || []) == ["file", "sqlite"] and
        valid_git_commit?(scope["previous_commit"]) and
        Enum.all?(required_checks, &(checks[&1] == "pass")) and
        Enum.all?(["file", "sqlite"], fn store ->
          migration_artifact_complete?(root, artifacts[store] || %{})
        end)

    if valid?, do: :ok, else: {:error, :previous_release_migration_incomplete}
  end

  defp qualification_complete(
         _root,
         %{kind: :minimum_git_workspace, minimum_git_version: minimum_git_version},
         evidence,
         _require_artifacts?
       ) do
    host = evidence["host"] || %{}
    fixture = evidence["fixture"] || %{}
    result = evidence["result"] || %{}

    valid? =
      evidence["schema_version"] == 1 and
        evidence["scope"] == "single-user local Git workspace qualification" and
        host["git_version"] == minimum_git_version and host["cli_version"] == current_version() and
        fixture["regular_files"] >= 2_000 and fixture["binary_bytes"] >= 8_388_608 and
        fixture["executable_files"] >= 1 and fixture["symlinks"] >= 1 and
        fixture["unusual_paths"] >= 4 and result["integrity"] == "verified" and
        valid_sha256?(result["manifest_digest"]) and measurements_within_limits?(evidence)

    if valid?, do: :ok, else: {:error, :minimum_git_workspace_contract_failed}
  end

  defp qualification_complete(
         root,
         %{kind: :release_cli_interrupt} = entry,
         evidence,
         require_artifacts?
       ) do
    checks = evidence["checks"] || %{}
    release = evidence["release"] || %{}

    boolean_checks = [
      "installed_launcher_invoked",
      "daemon_protocol_used",
      "first_interrupt_requested_cancellation",
      "cancellation_persisted",
      "second_interrupt_detached_truthfully",
      "child_process_reaped",
      "temporary_argument_files_removed",
      "temporary_interrupt_files_removed"
    ]

    valid? =
      evidence["schema_version"] == 1 and
        evidence["schema"] == "twelvgaige.cli.release-interrupt-qualification" and
        release["version"] == current_version() and valid_raw_sha256?(release["launcher_sha256"]) and
        Enum.all?(boolean_checks, &(checks[&1] == true)) and
        checks["ordinary_interrupt_exit_status"] == 130 and
        checks["invalid_command_exit_status"] == 4 and
        packaged_launcher_complete?(root, entry, release, require_artifacts?)

    if valid?, do: :ok, else: {:error, :release_cli_interrupt_contract_failed}
  end

  defp qualification_complete(_root, _entry, _evidence, _require_artifacts?), do: :ok

  defp security_complete(%{kind: :backend}, %{"security" => security}) do
    required = [
      "network_none",
      "mount_write",
      "credential_revocation",
      "copy_snapshot",
      "copy_snapshot_no_writable_host_mount",
      "copy_snapshot_source_not_mounted",
      "copy_snapshot_declared_export",
      "copy_snapshot_import_read_only"
    ]

    cancellation_passed =
      security["cancellation_cleanup"] == "pass" or
        security["cancellation_descendants_removed"] == "pass"

    if cancellation_passed and Enum.all?(required, &(security[&1] == "pass")),
      do: :ok,
      else: {:error, :backend_security_gate_failed}
  end

  defp security_complete(%{kind: :independent_verification}, %{"security" => security}) do
    required = [
      "copy_snapshot",
      "network_none",
      "credential_free",
      "provider_environment_absent",
      "command_evidence_complete",
      "cleanup_complete"
    ]

    if Enum.all?(required, &(security[&1] == "pass")),
      do: :ok,
      else: {:error, :independent_verification_security_gate_failed}
  end

  defp security_complete(%{kind: :attached_session, backend: backend}, evidence) do
    sandbox = evidence["sandbox"] || %{}
    auth = evidence["auth"] || %{}
    capture = evidence["result_capture"] || %{}
    lifecycle = evidence["lifecycle"] || %{}

    valid? =
      evidence["backend"] == backend and sandbox["attached_stdio"] == true and
        sandbox["detached_start_used"] == false and
        sandbox["source_host_mount_visible_to_worker"] == false and
        sandbox["outer_sandbox_authoritative"] == true and
        auth["persisted_in_result"] == false and auth["source_mounted_in_worker"] == false and
        capture["complete_workspace_repatriated"] == true and
        capture["exact_file_verified"] == true and
        lifecycle["provider_initialized_inside_sandbox"] == true and
        lifecycle["turn_completed"] == true and
        lifecycle["runtime_quiescence_proven"] == true and lifecycle["exact_cleanup"] == true

    if valid?, do: :ok, else: {:error, :attached_session_security_gate_failed}
  end

  defp security_complete(_entry, _evidence), do: :ok

  defp protocol_complete(%{protocol: :codex_app_server}, evidence) do
    protocol = evidence["protocol"] || %{}

    required_events = ["approval_required", "turn_completed"]
    observed_events = protocol["event_types"] || []

    if protocol["cli_version"] == Schema.cli_version() and
         protocol["schema_digest"] == Schema.digest() and
         protocol["transport"] == "stdio" and
         protocol["experimental_api"] == false and
         protocol["exact_resume_verified"] == true and
         protocol["digest_bound_receipts"] == true and
         is_integer(protocol["approval_count"]) and protocol["approval_count"] >= 1 and
         Enum.all?(required_events, &(&1 in observed_events)) do
      :ok
    else
      {:error, :codex_app_server_protocol_gate_failed}
    end
  end

  defp protocol_complete(_entry, _evidence), do: :ok

  defp performance_within_slo(%{slo_profile: profile}, evidence) do
    performance = evidence["performance"] || %{}

    {launch_ms, cancellation_ms} =
      case profile do
        :podman_macos_arm64 ->
          warm = performance["warm_launch_ms"] || []
          {percentile(warm, 0.95), performance["cancellation_ms"]}

        :apple_container_macos_arm64 ->
          samples = performance["repeated_samples"] || []

          {samples |> Enum.map(& &1["launch_ms"]) |> percentile(0.95),
           performance["cancellation_ms"]}
      end

    with {:ok, targets} <- SLO.profile(profile),
         true <- is_number(launch_ms) and launch_ms <= targets.launch_p95_ms,
         true <- is_number(cancellation_ms) and cancellation_ms <= targets.cancellation_p95_ms do
      :ok
    else
      _other -> {:error, :backend_performance_slo_failed}
    end
  end

  defp performance_within_slo(_entry, _evidence), do: :ok

  defp operations_complete(root, %{kind: :operations}, evidence) do
    profiles = evidence["profiles"] || %{}
    contract = evidence["security_contract"] || %{}

    required = %{
      "podman_macos_arm64" => "podman_macos_arm64",
      "apple_container_macos_arm64" => "apple_container_macos_arm64"
    }

    valid? =
      evidence["slo_version"] == SLO.version() and operations_contract_complete?(root, contract) and
        Enum.all?(required, fn {key, profile_name} ->
          profile = profiles[key] || %{}
          slo = profile["slo"] || %{}
          budgets = slo["error_budgets"] || %{}

          is_integer(profile["launch_attempts"]) and profile["launch_attempts"] >= 5 and
            slo["version"] == SLO.version() and
            slo["profile"] == profile_name and slo["status"] == "pass" and
            budgets != %{} and
            Enum.all?(budgets, fn {_name, budget} -> budget["exhausted"] == false end)
        end)

    if valid?, do: :ok, else: {:error, :operations_slo_gate_failed}
  end

  defp operations_complete(_root, _entry, _evidence), do: :ok

  defp operations_contract_complete?(root, contract) do
    required = [
      "local_user_and_loopback_binding",
      "backup_authority_stripping",
      "signed_audit_checkpoint_health",
      "audit_and_artifact_retention",
      "orphan_and_lease_reconciliation",
      "cross_session_isolation",
      "provider_rate_and_backoff",
      "scheduler_restart_and_replay",
      "cross_repository_commit_provenance",
      "authenticated_operator_protocol"
    ]

    checks = contract["checks"] || %{}
    sources = contract["sources"] || %{}

    contract["result"] == "pass" and contract["suite"] == "make check" and
      Enum.all?(required, &(checks[&1] == "pass")) and sources != %{} and
      Enum.all?(sources, fn {relative, expected} ->
        safe_relative?(relative) and digest_matches?(Path.join(root, relative), expected)
      end)
  end

  defp safe_relative?(relative) do
    is_binary(relative) and relative != "" and Path.type(relative) != :absolute and
      not Enum.member?(Path.split(relative), "..")
  end

  defp digest_matches?(path, "sha256:" <> expected) do
    case File.read(path) do
      {:ok, contents} ->
        actual = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
        Twelvgaige.Security.secure_equal?(actual, expected)

      {:error, _reason} ->
        false
    end
  end

  defp digest_matches?(_path, _expected), do: false

  defp egress_boundary_check(root, now, max_age_days) do
    path = Path.join(root, "qualification/evidence/egress-proxy/live-qualification.json")
    image_record_path = Path.join(root, "qualification/evidence/egress-proxy/image-record.json")

    with {:ok, evidence} <- read_json(path),
         {:ok, image_record} <- read_json(image_record_path),
         :ok <- passed(%{}, evidence),
         :ok <- fresh(evidence, now, max_age_days),
         true <-
           get_in(evidence, ["image", "digest"]) == get_in(image_record, ["image", "digest"]),
         true <- egress_contract_complete?(evidence) do
      %{status: :pass, path: path, generated_at: evidence["generated_at"]}
    else
      {:error, reason} -> %{status: :fail, path: path, reason: reason}
      false -> %{status: :fail, path: path, reason: :egress_boundary_gate_failed}
    end
  end

  defp egress_contract_complete?(evidence) do
    contract = evidence["contract"] || %{}
    backends = evidence["backends"] || %{}

    required_contract = [
      "per_session_internal_network",
      "worker_direct_egress_denied",
      "capability_required",
      "allowed_destination_connected",
      "undeclared_destination_denied",
      "private_dns_result_denied",
      "dns_address_pinned",
      "sidecar_non_root",
      "sidecar_read_only_root",
      "sidecar_capabilities_dropped",
      "sidecar_destroyed_on_revoke",
      "capability_absent_from_audit"
    ]

    Enum.all?(required_contract, &(contract[&1] == "pass")) and
      Enum.all?(["podman", "apple_container"], fn backend_name ->
        backend = backends[backend_name] || %{}
        worker = backend["worker_attestation"] || %{}

        backend["result"] == "pass" and backend["cleanup"] == "pass" and
          worker["uid"] == 65_532 and worker["gid"] == 65_532 and
          worker["network_mode"] == "broker_only" and worker["rootfs_mode"] == "read_only" and
          worker["dropped_capabilities"] == ["ALL"] and
          Enum.sort(worker["environment_names"] || []) ==
            Enum.sort(["HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"])
      end)
  end

  defp platform_support_matrix_check(root) do
    path = Path.join(root, "qualification/platform-matrix.json")

    with {:ok, matrix} <- read_json(path),
         true <- matrix["schema_version"] == 1,
         true <- is_map(matrix["platforms"]),
         :ok <- verify_support_entries(root, matrix["platforms"]) do
      %{status: :pass, path: path, generated_at: matrix["updated_at"]}
    else
      {:error, :enoent} ->
        %{status: :fail, path: path, reason: :support_matrix_missing}

      {:error, reason} ->
        %{status: :fail, path: path, reason: reason}

      false ->
        %{status: :fail, path: path, reason: :support_matrix_invalid}
    end
  end

  defp verify_support_entries(root, value) when is_map(value) do
    case value["status"] do
      nil ->
        Enum.reduce_while(value, :ok, fn {_key, child}, :ok ->
          case verify_support_entries(root, child) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      status ->
        verify_support_entry(root, status, value)
    end
  end

  defp verify_support_entries(_root, _value), do: {:error, :support_matrix_invalid}

  defp verify_support_entry(root, status, entry)
       when status in ["locally_qualified", "locally_qualified_opt_in"] do
    relative = entry["evidence"]

    with true <- safe_relative?(relative),
         {:ok, evidence} <- read_json(Path.join(root, relative)),
         true <- evidence["result"] == "pass" or evidence["status"] == "pass" do
      verify_nested_support_entries(root, entry)
    else
      false -> {:error, :support_matrix_evidence_failed}
      {:error, :enoent} -> {:error, :support_matrix_evidence_missing}
      {:error, _reason} -> {:error, :support_matrix_evidence_invalid}
    end
  end

  defp verify_support_entry(root, status, entry)
       when status in ["pending_ci", "pending_explicit_authorization", "not_advertised"] do
    verify_nested_support_entries(root, entry)
  end

  defp verify_support_entry(_root, _status, _entry),
    do: {:error, :support_matrix_status_invalid}

  defp verify_nested_support_entries(root, entry) do
    nested = Map.drop(entry, ["status", "evidence", "minimum_version", "ci_required"])
    verify_support_entries(root, nested)
  end

  defp egress_proxy_image_check(root, now, max_age_days, require_artifacts?) do
    directory = Path.join(root, "qualification/evidence/egress-proxy")
    record_path = Path.join(directory, "image-record.json")

    with {:ok, encoded} <- File.read(record_path),
         {:ok, record} <- Jason.decode(encoded),
         :ok <- fresh(record, now, max_age_days),
         :ok <- verify_egress_signature(root, directory, encoded),
         :ok <-
           verify_egress_image_record(root, directory, record, now, require_artifacts?) do
      %{status: :pass, path: record_path, generated_at: record["generated_at"]}
    else
      {:error, reason} -> %{status: :fail, path: record_path, reason: reason}
    end
  end

  defp verify_egress_signature(root, directory, encoded) do
    with {:ok, signature} <- File.read(Path.join(directory, "image-record.sig")),
         {:ok, pem} <- File.read(Path.join(directory, "qualification-signing-public-key.pem")),
         :ok <- trusted_qualification_key(root, pem),
         [entry] <- :public_key.pem_decode(pem),
         key <- :public_key.pem_entry_decode(entry),
         true <- :public_key.verify(encoded, :none, signature, key) do
      :ok
    else
      _other -> {:error, :egress_image_signature_invalid}
    end
  rescue
    _error -> {:error, :egress_image_signature_invalid}
  end

  defp trusted_qualification_key(root, pem) do
    policy_path = Path.join(root, "qualification/signing-policy.json")
    digest = "sha256:" <> Base.encode16(:crypto.hash(:sha256, pem), case: :lower)

    with {:ok, policy} <- read_json(policy_path),
         true <- policy["schema_version"] == 1,
         allowed when is_list(allowed) <- policy["allowed_public_key_sha256"],
         true <- digest in allowed do
      :ok
    else
      _other -> {:error, :qualification_signing_key_untrusted}
    end
  end

  defp verify_egress_image_record(root, directory, record, now, require_artifacts?) do
    security = record["security"] || %{}
    findings = security["findings"] || %{}
    evidence = record["evidence"] || %{}
    image = record["image"] || %{}
    vulnerabilities_path = Path.join(directory, "vulnerabilities.json")
    archive_path = Path.join(root, "artifacts/qualification/egress-proxy/egress-proxy.oci.tar")

    with true <- record["schema_version"] == 1,
         true <- image["architecture"] == "linux/arm64",
         true <- valid_sha256?(image["digest"]),
         true <- security["runs_as"] == "65532:65532",
         true <- security["rootfs"] == "read_only_at_runtime",
         true <- security["capabilities"] == "drop_all",
         true <- findings["critical"] == 0 and findings["high"] == 0,
         :ok <- digest_matches(Path.join(directory, "sbom.spdx.json"), evidence["sbom_digest"]),
         :ok <- digest_matches(vulnerabilities_path, evidence["vulnerability_digest"]),
         :ok <-
           digest_matches(
             Path.join(directory, "image-inspect.json"),
             evidence["image_inspect_digest"]
           ),
         :ok <-
           archive_digest_complete(
             archive_path,
             evidence["oci_archive_digest"],
             require_artifacts?
           ),
         {:ok, vulnerabilities} <- read_json(vulnerabilities_path),
         :ok <- vulnerability_database_fresh(vulnerabilities, now) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :egress_image_record_invalid}
    end
  end

  defp archive_digest_complete(path, expected, true), do: digest_matches(path, expected)

  defp archive_digest_complete(_path, expected, false) do
    if valid_sha256?(expected),
      do: :ok,
      else: {:error, :egress_archive_digest_invalid}
  end

  defp vulnerability_database_fresh(vulnerabilities, now) do
    status = get_in(vulnerabilities, ["descriptor", "db", "status"]) || %{}

    with true <- status["valid"] == true,
         {:ok, built, _offset} <- DateTime.from_iso8601(status["built"] || ""),
         age_seconds = DateTime.diff(now, built, :second),
         true <- age_seconds >= -300 and age_seconds <= 5 * 86_400 do
      :ok
    else
      _other -> {:error, :vulnerability_database_stale_or_invalid}
    end
  end

  defp digest_matches(path, expected) do
    with true <- valid_sha256?(expected),
         {:ok, value} <- File.read(path),
         true <-
           "sha256:" <> Base.encode16(:crypto.hash(:sha256, value), case: :lower) == expected do
      :ok
    else
      _other -> {:error, :egress_evidence_digest_mismatch}
    end
  end

  defp valid_sha256?("sha256:" <> digest), do: String.match?(digest, ~r/\A[0-9a-f]{64}\z/)
  defp valid_sha256?(_value), do: false

  defp valid_raw_sha256?(digest) when is_binary(digest),
    do: String.match?(digest, ~r/\A[0-9a-f]{64}\z/)

  defp valid_raw_sha256?(_digest), do: false

  defp valid_git_commit?(commit) when is_binary(commit),
    do: String.match?(commit, ~r/\A[0-9a-f]{40}\z/)

  defp valid_git_commit?(_commit), do: false

  defp current_version do
    case Application.spec(:twelvgaige, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp measurements_within_limits?(evidence) do
    limits = evidence["limits"] || %{}
    measurements = evidence["measurements"] || %{}
    evaluation = evidence["evaluation"] || %{}
    checks = evaluation["checks"] || []

    check_metrics = MapSet.new(checks, & &1["metric"])
    expected_metrics = Map.keys(limits) |> MapSet.new()

    limits != %{} and evaluation["status"] == "pass" and check_metrics == expected_metrics and
      Enum.all?(measurements, fn {_metric, observed} -> is_number(observed) and observed >= 0 end) and
      Enum.all?(checks, fn check ->
        metric = check["metric"]
        observed = check["observed"]
        limit = limits[metric]
        measured = Map.get(measurements, metric, observed)

        check["status"] == "pass" and is_number(limit) and is_number(observed) and observed >= 0 and
          observed <= limit and check["limit"] == limit and measured == observed
      end)
  end

  defp migration_artifact_complete?(root, artifact) do
    relative = artifact["path"]

    with true <- artifact["encoding"] == "base64+gzip" and safe_relative?(relative),
         true <- valid_raw_sha256?(artifact["compressed_sha256"]),
         true <- valid_raw_sha256?(artifact["uncompressed_sha256"]),
         {:ok, encoded} <- File.read(Path.join(root, relative)),
         {:ok, compressed} <- Base.decode64(String.replace(encoded, ~r/\s+/, "")),
         true <- byte_size(compressed) == artifact["compressed_bytes"],
         true <- raw_sha256(compressed) == artifact["compressed_sha256"],
         uncompressed <- :zlib.gunzip(compressed),
         true <- byte_size(uncompressed) == artifact["uncompressed_bytes"],
         true <- raw_sha256(uncompressed) == artifact["uncompressed_sha256"] do
      true
    else
      _other -> false
    end
  rescue
    _error -> false
  end

  defp packaged_launcher_complete?(_root, _entry, _release, false), do: true

  defp packaged_launcher_complete?(root, entry, release, true) do
    launcher = Path.join(root, entry.launcher)

    with {:ok, contents} <- File.read(launcher) do
      raw_sha256(contents) == release["launcher_sha256"]
    else
      _error -> false
    end
  end

  defp raw_sha256(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp read_json(path) do
    with {:ok, encoded} <- File.read(path), do: Jason.decode(encoded)
  end

  defp percentile([], _quantile), do: nil

  defp percentile(values, quantile) do
    values = Enum.sort(values)
    index = max(0, ceil(length(values) * quantile) - 1)
    Enum.at(values, index)
  end

  defp normalize_result(:ok), do: %{status: :pass}
  defp normalize_result({:error, reason}), do: %{status: :fail, reason: reason}
end
