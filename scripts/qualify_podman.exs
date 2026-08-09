alias Twelvgaige.Credential.Broker
alias Twelvgaige.Sandbox.{Admission, Backend.Podman, Image, Manager, Reconciler}

defmodule Twelvgaige.PodmanQualification do
  @moduledoc false

  @memory_bytes 268_435_456
  @pids 32

  def run do
    repo_root = Path.expand("..", __DIR__)
    data_root = System.fetch_env!("TWELVGAIGE_DATA_ROOT") |> Path.expand()
    evidence_dir = Path.join(repo_root, "qualification/evidence/podman-worker")
    catalog = evidence_dir |> Path.join("catalog.json") |> File.read!() |> Jason.decode!()

    image_record =
      evidence_dir |> Path.join("image-record.json") |> File.read!() |> Jason.decode!()

    [catalog_image] = catalog["images"]
    image_reference = catalog_image["reference"]
    image_digest = catalog_image["digest"]

    :ok = admit_image(catalog_image, image_record)

    probe =
      expect_ok!(
        Podman.probe(
          machine_name: System.get_env("TWELVGAIGE_PODMAN_MACHINE", "twelvgaige"),
          machine_allowed_mounts: [data_root]
        ),
        "Podman machine probe"
      )

    run_id = "qualification-#{System.unique_integer([:positive])}"
    workspace_root = Path.join([data_root, "workspaces", run_id])
    File.mkdir_p!(workspace_root)
    File.chmod!(workspace_root, 0o777)

    Process.put(:qualification_resources, [])
    System.at_exit(fn _status -> cleanup_resources() end)

    {security, cancellation_ms, recovery_ms} =
      qualify_security(workspace_root, image_reference, image_digest)

    copy_snapshot = qualify_copy_snapshot(workspace_root, image_reference, image_digest)
    security = Map.merge(security, copy_snapshot)

    performance =
      qualify_performance(
        workspace_root,
        image_reference,
        image_digest,
        cancellation_ms,
        recovery_ms
      )

    evidence = %{
      schema_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      host: host_metadata(),
      podman: probe,
      image: %{reference: image_reference, digest: image_digest},
      security: security,
      performance: performance,
      result: "pass"
    }

    destination = Path.join(evidence_dir, "live-qualification.json")
    File.write!(destination, Jason.encode!(evidence, pretty: true) <> "\n")
    IO.puts("Podman live qualification passed; evidence: #{destination}")
  end

  defp admit_image(catalog_image, image_record) do
    image = %Image{
      reference: catalog_image["reference"],
      digest: catalog_image["digest"],
      provenance: image_record["provenance"],
      sbom_digest: catalog_image["sbom_digest"],
      vulnerability_result: catalog_image["vulnerability_result"],
      signature_verified: catalog_image["signature_verified"],
      support_status: String.to_existing_atom(catalog_image["support_status"]),
      catalog_revision: "qualification-2026-08-02"
    }

    :ok = Image.admit(image)
  end

  defp qualify_security(workspace_root, image_reference, image_digest) do
    {:ok, admission} =
      Admission.start_link(
        name: :podman_qualification_admission,
        limits: admission_limits(4)
      )

    {:ok, broker} = Broker.start_link(name: :podman_qualification_broker)

    lease = issue_lease!(broker, "recovery-session")

    {:ok, manager} =
      Manager.start_link(
        name: :podman_qualification_manager,
        backend: Podman,
        admission: admission,
        credential_broker: broker
      )

    Process.unlink(manager)

    recovery_workspace = Path.join(workspace_root, "recovery")
    prepare_workspace!(recovery_workspace)

    command = [
      "/bin/sh",
      "-lc",
      "set -eu; printf 'mount-write-ok\\n' > /workspace/mount.txt; " <>
        "if git ls-remote https://github.com/openai/codex.git >/workspace/network.txt 2>&1; " <>
        "then exit 71; fi; printf 'network-blocked\\n' > /workspace/network-result.txt; " <>
        "sleep 300 & wait"
    ]

    spec =
      launch_spec(recovery_workspace, image_reference, image_digest, lease.id, "recovery")

    {:ok, resource_id, record} =
      expect_ok!(
        Manager.launch(spec,
          server: manager,
          allowed_roots: [workspace_root],
          command: command,
          timeout_ms: 60_000
        ),
        "security fixture launch"
      )

    remember_resource(resource_id)
    wait_for_file!(Path.join(recovery_workspace, "network-result.txt"), 10_000)

    created_manifest = record.resource.manifest
    observed = record.resource.observed
    assert!(observed.rootfs_mode == :read_only, "root filesystem is not read-only")
    assert!(observed.dropped_capabilities == ["ALL"], "capabilities were not dropped")
    assert!(observed.security_options == ["no-new-privileges"], "no-new-privileges missing")
    assert!(observed.network_mode == :none, "network mode is not none")
    assert!(observed.uid == 65_532 and observed.gid == 65_532, "worker is not non-root")

    assert!(
      observed.limits == %{cpu: 1, memory_bytes: @memory_bytes, pids: @pids},
      "limits drifted"
    )

    assert!(
      File.read!(Path.join(recovery_workspace, "mount.txt")) == "mount-write-ok\n",
      "workspace mount was not writable"
    )

    assert!(
      File.read!(Path.join(recovery_workspace, "network-result.txt")) == "network-blocked\n",
      "network none did not block egress"
    )

    GenServer.stop(manager, :normal)

    recovery_started_at = System.monotonic_time(:millisecond)

    decisions =
      Reconciler.reconcile(%{resource_id => %{manifest: created_manifest}}, Podman,
        timeout_ms: 60_000
      )

    recovery_ms = System.monotonic_time(:millisecond) - recovery_started_at

    assert!(decisions[resource_id].status == :resume, "matching crash recovery did not resume")

    drifted_manifest = %{created_manifest | uid: 65_531}

    drifted =
      Reconciler.reconcile(%{resource_id => %{manifest: drifted_manifest}}, Podman,
        timeout_ms: 60_000
      )

    assert!(drifted[resource_id].status == :quarantine, "attestation drift was not quarantined")

    :ok = Podman.stop(resource_id, grace_seconds: 1, timeout_ms: 60_000)
    :ok = Podman.destroy(resource_id, timeout_ms: 60_000)
    forget_resource(resource_id)
    :ok = Admission.release(record.admission_lease_id, server: admission)
    :ok = Broker.revoke(lease.id, server: broker)

    cancel_lease = issue_lease!(broker, "cancel-session")

    {:ok, cancel_manager} =
      Manager.start_link(
        name: :podman_qualification_cancel_manager,
        backend: Podman,
        admission: admission,
        credential_broker: broker
      )

    cancel_workspace = Path.join(workspace_root, "cancel")
    prepare_workspace!(cancel_workspace)

    {:ok, cancel_id, _cancel_record} =
      expect_ok!(
        Manager.launch(
          launch_spec(cancel_workspace, image_reference, image_digest, cancel_lease.id, "cancel"),
          server: cancel_manager,
          allowed_roots: [workspace_root],
          command: ["/bin/sh", "-lc", "sleep 300 & wait"],
          timeout_ms: 60_000
        ),
        "cancellation fixture launch"
      )

    remember_resource(cancel_id)
    started_at = System.monotonic_time(:millisecond)
    :ok = Manager.cancel(cancel_id, server: cancel_manager, grace_seconds: 1, timeout_ms: 60_000)
    cancellation_ms = System.monotonic_time(:millisecond) - started_at
    forget_resource(cancel_id)

    {:error, :credential_lease_revoked} =
      Broker.authorize(
        cancel_lease.access_token,
        %{
          session_id: "cancel-session",
          model: "qualification-model",
          destination: "provider.invalid",
          amount: 1
        },
        server: broker
      )

    {inspect_status, _output} = system(["inspect", cancel_id])
    assert!(inspect_status != 0, "cancelled container still exists")

    security = %{
      launch_attestation: "pass",
      mount_write: "pass",
      network_none: "pass",
      resource_limits: observed.limits,
      non_root: "pass",
      read_only_rootfs: "pass",
      dropped_capabilities: "pass",
      no_new_privileges: "pass",
      crash_recovery: "resume",
      drift_recovery: "quarantine",
      cancellation_descendants_removed: "pass",
      credential_revocation: "pass"
    }

    {security, cancellation_ms, recovery_ms}
  end

  defp qualify_performance(
         workspace_root,
         image_reference,
         image_digest,
         cancellation_ms,
         recovery_ms
       ) do
    samples =
      for index <- 0..4 do
        workspace = Path.join(workspace_root, "perf-#{index}")
        prepare_workspace!(workspace)
        timed_launch(workspace, image_reference, image_digest, "perf-#{index}")
      end

    concurrent_started = System.monotonic_time(:millisecond)

    concurrent =
      0..1
      |> Task.async_stream(
        fn index ->
          workspace = Path.join(workspace_root, "concurrent-#{index}")
          prepare_workspace!(workspace)
          timed_launch(workspace, image_reference, image_digest, "concurrent-#{index}")
        end,
        max_concurrency: 2,
        timeout: 60_000,
        ordered: true
      )
      |> Enum.map(fn {:ok, sample} -> sample end)

    %{
      definition: "cached image; cold is first container launch, warm is subsequent launch",
      cold_launch_ms: hd(samples),
      warm_launch_ms: tl(samples),
      warm_summary_ms: summarize(tl(samples)),
      concurrent_sessions: 2,
      concurrent_individual_ms: concurrent,
      concurrent_wall_ms: System.monotonic_time(:millisecond) - concurrent_started,
      cancellation_ms: cancellation_ms,
      recovery_ms: recovery_ms
    }
  end

  defp qualify_copy_snapshot(workspace_root, image_reference, image_digest) do
    source = Path.join(workspace_root, "copy-snapshot-source")
    output = Path.join(workspace_root, "copy-snapshot-output")
    prepare_workspace!(source)
    prepare_workspace!(output)
    File.write!(Path.join(source, "README.md"), "isolated snapshot\n")
    File.chmod!(Path.join(source, "README.md"), 0o666)

    spec = %{
      profile: :coding_restricted,
      image_reference: image_reference,
      image_digest: image_digest,
      workspace_transport: :copy_snapshot,
      mounts: [%{source: source, destination: "/workspace", mode: :read_write}],
      network_mode: :none,
      allowed_destinations: [],
      limits: %{cpu: 1, memory_bytes: @memory_bytes, pids: @pids},
      deadline: DateTime.add(DateTime.utc_now(), 300),
      policy_revision: "podman-copy-snapshot-qualification-1",
      created_at: DateTime.utc_now()
    }

    manifest =
      expect_ok!(Podman.prepare(spec, allowed_roots: [workspace_root]), "copy snapshot prepare")

    command = [
      "/bin/sh",
      "-lc",
      "set -eu; test \"$(cat README.md)\" = 'isolated snapshot'; " <>
        "if printf denied > /run/twelvgaige-import/workspace/escape.txt 2>/dev/null; then exit 72; fi; " <>
        "printf 'qualified\\n' > result.txt"
    ]

    {:ok, resource_id, resource} =
      expect_ok!(
        Podman.create(manifest, command: command, timeout_ms: 60_000),
        "copy snapshot create"
      )

    remember_resource(resource_id)
    expect_ok!(Podman.start(resource_id, timeout_ms: 60_000), "copy snapshot start")
    {0, _output} = system(["wait", resource_id])

    observed = resource.observed
    host_mounts = Enum.filter(observed.mounts, &(&1.type in ["bind", :bind]))
    volumes = Enum.filter(observed.mounts, &(&1.type in ["volume", :volume]))

    assert!(
      Enum.all?(host_mounts, &(&1.mode == :read_only)),
      "copy_snapshot retained a writable host bind mount"
    )

    assert!(
      Enum.any?(volumes, &(&1.destination == "/workspace" and &1.mode == :read_write)),
      "copy_snapshot did not use sandbox-owned writable storage"
    )

    refute_file!(
      Path.join(source, "result.txt"),
      "copy_snapshot wrote its result to the host input"
    )

    refute_file!(Path.join(source, "escape.txt"), "copy_snapshot modified the read-only input")

    {:ok, export} =
      Podman.export(resource_id, output, ["result.txt"],
        manifest: resource.manifest,
        allowed_export_roots: [output],
        max_export_bytes: 1_024,
        timeout_ms: 60_000
      )

    assert!(
      File.read!(Path.join(output, "result.txt")) == "qualified\n",
      "declared export drifted"
    )

    assert!(export.bytes == 10, "declared export byte accounting drifted")

    assert!(
      match?(
        {:error, :export_path_invalid},
        Podman.export(resource_id, output, ["../escape"],
          manifest: resource.manifest,
          allowed_export_roots: [output]
        )
      ),
      "copy_snapshot accepted export traversal"
    )

    :ok = Podman.destroy(resource_id, timeout_ms: 60_000)
    forget_resource(resource_id)

    %{
      copy_snapshot: "pass",
      copy_snapshot_no_writable_host_mount: "pass",
      copy_snapshot_import_read_only: "pass",
      copy_snapshot_declared_export: "pass",
      copy_snapshot_export_bytes: export.bytes
    }
  end

  defp timed_launch(workspace, image_reference, image_digest, name) do
    spec =
      workspace
      |> launch_spec(image_reference, image_digest, nil, name)
      |> Map.delete(:reservation)

    started_at = System.monotonic_time(:millisecond)
    manifest = expect_ok!(Podman.prepare(spec, allowed_roots: [workspace]), "performance prepare")

    {:ok, resource_id, _resource} =
      expect_ok!(
        Podman.create(manifest,
          command: ["/bin/sh", "-lc", "true"],
          timeout_ms: 60_000
        ),
        "performance create"
      )

    remember_resource(resource_id)

    try do
      _process = expect_ok!(Podman.start(resource_id, timeout_ms: 60_000), "performance start")
      {0, _output} = system(["wait", resource_id])
      System.monotonic_time(:millisecond) - started_at
    after
      _ = Podman.destroy(resource_id, timeout_ms: 60_000)
      forget_resource(resource_id)
    end
  end

  defp launch_spec(workspace, image_reference, image_digest, credential_lease_id, suffix) do
    %{
      profile: :integration_test,
      image_reference: image_reference,
      image_digest: image_digest,
      workspace_transport: :bind_worktree,
      mounts: [%{source: workspace, destination: "/workspace", mode: :read_write}],
      network_mode: :none,
      allowed_destinations: [],
      limits: %{cpu: 1, memory_bytes: @memory_bytes, pids: @pids},
      deadline: DateTime.add(DateTime.utc_now(), 300),
      credential_lease_id: credential_lease_id,
      policy_revision: "podman-live-qualification-2026-08-02-#{suffix}",
      created_at: DateTime.utc_now(),
      reservation: reservation()
    }
  end

  defp reservation do
    %{
      sandboxes: 1,
      cpu: 1,
      memory_bytes: @memory_bytes,
      pids: @pids,
      workspace_bytes: 1_048_576,
      artifact_bytes: 1_048_576,
      provider_tokens: 100
    }
  end

  defp admission_limits(sandboxes) do
    [
      sandboxes: sandboxes,
      cpu: sandboxes,
      memory_bytes: sandboxes * @memory_bytes,
      pids: sandboxes * @pids,
      workspace_bytes: sandboxes * 1_048_576,
      artifact_bytes: sandboxes * 1_048_576,
      provider_tokens: sandboxes * 100
    ]
  end

  defp issue_lease!(broker, session_id) do
    {:ok, lease} =
      Broker.issue(
        %{
          session_id: session_id,
          round_id: "qualification-round",
          shot_id: "qualification-shot",
          attempt: 1,
          runtime: :codex,
          principal: "local-qualification",
          provider_account: "local",
          models: ["qualification-model"],
          destinations: ["provider.invalid"],
          budget: 10,
          expires_at: DateTime.add(DateTime.utc_now(), 300),
          upstream_secret: "ephemeral-qualification-only"
        },
        server: broker
      )

    lease
  end

  defp prepare_workspace!(path) do
    File.mkdir_p!(path)
    File.chmod!(path, 0o777)
  end

  defp wait_for_file!(path, timeout_ms) do
    started_at = System.monotonic_time(:millisecond)
    do_wait_for_file(path, started_at, timeout_ms)
  end

  defp do_wait_for_file(path, started_at, timeout_ms) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) - started_at >= timeout_ms ->
        raise "timed out waiting for #{path}"

      true ->
        Process.sleep(50)
        do_wait_for_file(path, started_at, timeout_ms)
    end
  end

  defp summarize(samples) do
    sorted = Enum.sort(samples)
    %{min: hd(sorted), median: Enum.at(sorted, div(length(sorted), 2)), max: List.last(sorted)}
  end

  defp host_metadata do
    %{
      os: command_output("sw_vers", ["-productVersion"]),
      architecture: :erlang.system_info(:system_architecture) |> List.to_string(),
      logical_cpus: command_output("sysctl", ["-n", "hw.logicalcpu"]) |> String.to_integer(),
      memory_bytes: command_output("sysctl", ["-n", "hw.memsize"]) |> String.to_integer()
    }
  end

  defp command_output(binary, args) do
    {output, 0} = System.cmd(binary, args, stderr_to_stdout: true)
    String.trim(output)
  end

  defp system(args) do
    {output, status} = System.cmd("podman", args, stderr_to_stdout: true)
    {status, output}
  end

  defp expect_ok!({:ok, value}, _operation), do: value
  defp expect_ok!({:ok, first, second}, _operation), do: {:ok, first, second}

  defp expect_ok!({:error, reason}, operation),
    do: raise("#{operation} failed: #{inspect(reason)}")

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)

  defp refute_file!(path, message) do
    if File.exists?(path), do: raise(message), else: :ok
  end

  defp remember_resource(resource_id) do
    Process.put(:qualification_resources, [
      resource_id | Process.get(:qualification_resources, [])
    ])
  end

  defp forget_resource(resource_id) do
    Process.put(
      :qualification_resources,
      List.delete(Process.get(:qualification_resources, []), resource_id)
    )
  end

  defp cleanup_resources do
    Enum.each(Process.get(:qualification_resources, []), fn resource_id ->
      System.cmd("podman", ["rm", "--force", "--volumes", resource_id], stderr_to_stdout: true)
    end)
  end
end

Twelvgaige.PodmanQualification.run()
