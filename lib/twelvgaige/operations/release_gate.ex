defmodule Twelvgaige.Operations.ReleaseGate do
  @moduledoc "Fail-closed driver, backend, security, and SLO release matrix."

  alias Twelvgaige.DelegatedSession.Codex.Schema
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

        %{evidence: relative} = entry ->
          result = evidence_check(Path.join(root, relative), entry, now, max_age_days)
          Map.put(entry, :result, result)
      end)

    status = if Enum.all?(checks, &(&1.result.status == :pass)), do: :pass, else: :fail
    %{schema_version: 1, slo_version: SLO.version(), status: status, checks: checks}
  end

  defp evidence_check(path, entry, now, max_age_days) do
    with {:ok, encoded} <- File.read(path),
         {:ok, evidence} <- Jason.decode(encoded),
         :ok <- passed(evidence),
         :ok <- fresh(evidence, now, max_age_days),
         :ok <- security_complete(entry, evidence),
         :ok <- protocol_complete(entry, evidence),
         :ok <- performance_within_slo(entry, evidence),
         :ok <- operations_complete(root_from_evidence_path(path, entry), entry, evidence) do
      %{status: :pass, path: path, generated_at: evidence["generated_at"]}
    else
      {:error, reason} -> %{status: :fail, path: path, reason: reason}
    end
  end

  defp passed(%{"result" => "pass"}), do: :ok
  defp passed(_evidence), do: {:error, :qualification_failed}

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

  defp fresh(_evidence, _now, _max_age_days), do: {:error, :qualification_timestamp_missing}

  defp security_complete(%{kind: :backend}, %{"security" => security}) do
    required = [
      "network_none",
      "mount_write",
      "credential_revocation",
      "copy_snapshot",
      "copy_snapshot_no_writable_host_mount",
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

  defp root_from_evidence_path(path, %{kind: :operations}) do
    path
    |> Path.dirname()
    |> Path.join("../../..")
    |> Path.expand()
  end

  defp root_from_evidence_path(_path, _entry), do: nil

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
         :ok <- passed(evidence),
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
