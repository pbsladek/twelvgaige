alias Twelvgaige.Credential.Broker
alias Twelvgaige.Sandbox.{Admission, Backend.AppleContainer, Manager, Reconciler}

defmodule Twelvgaige.AppleContainerQualification do
  @moduledoc false

  @memory_bytes 268_435_456
  @pids 32
  @samples 5
  @resource_table :twelvgaige_apple_qualification_resources

  def run do
    repo_root = Path.expand("..", __DIR__)
    data_root = System.fetch_env!("TWELVGAIGE_DATA_ROOT") |> Path.expand()
    podman_evidence = Path.join(repo_root, "qualification/evidence/podman-worker")
    evidence_dir = Path.join(repo_root, "qualification/evidence/apple-container")
    File.mkdir_p!(evidence_dir)

    catalog = podman_evidence |> Path.join("catalog.json") |> File.read!() |> Jason.decode!()
    [image] = catalog["images"]
    reference = image["reference"]
    digest = image["digest"]

    probe = expect_ok!(AppleContainer.probe(timeout_ms: 60_000), "Apple container probe")

    run_id = "qualification-#{System.unique_integer([:positive])}"
    root = Path.join([data_root, "workspaces", "apple-container", run_id])
    File.mkdir_p!(root)
    :ets.new(@resource_table, [:named_table, :public, :set])
    System.at_exit(fn _status -> cleanup() end)

    {security, cancellation_ms, recovery_ms} =
      security_qualification(root, reference, digest)

    security = Map.merge(security, copy_snapshot_qualification(root, reference, digest))

    performance =
      performance_qualification(root, reference, digest, cancellation_ms, recovery_ms)

    evidence = %{
      schema_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      result: "pass",
      host: host_metadata(),
      backend: probe,
      image: %{reference: reference, digest: digest},
      security: security,
      performance: performance,
      security_contract: %{
        authority: "one Apple lightweight VM per worker",
        no_new_privileges: "not exposed by Apple container 1.2.0; not claimed",
        process_limit: "RLIMIT_NPROC inside a per-session VM",
        guest_control_channels: "denied"
      }
    }

    destination = Path.join(evidence_dir, "live-qualification.json")
    File.write!(destination, Jason.encode!(evidence, pretty: true) <> "\n")
    IO.puts("Apple container live qualification passed; evidence: #{destination}")
  end

  defp security_qualification(root, reference, digest) do
    {:ok, admission} =
      Admission.start_link(name: :apple_qualification_admission, limits: admission_limits(6))

    {:ok, broker} = Broker.start_link(name: :apple_qualification_broker)
    lease = issue_lease!(broker, "apple-recovery-session")

    {:ok, manager} =
      Manager.start_link(
        name: :apple_qualification_manager,
        backend: AppleContainer,
        admission: admission,
        credential_broker: broker
      )

    Process.unlink(manager)
    workspace = prepare_workspace!(Path.join(root, "security"))

    command = [
      "/bin/sh",
      "-lc",
      "set -eu; printf 'mount-write-ok\\n' > /workspace/mount.txt; " <>
        "for path in /run/container-apiserver.sock /var/run/container-apiserver.sock /run/host-services; do test ! -e \"$path\"; done; " <>
        "if env | grep -E '(^|_)(TOKEN|SECRET|PASSWORD|API_KEY|CREDENTIAL)=' >/workspace/secrets.txt; then exit 72; fi; " <>
        "if git ls-remote https://github.com/openai/codex.git >/workspace/network.txt 2>&1; then exit 71; fi; " <>
        "printf 'controls-blocked\\n' > /workspace/control-result.txt; printf 'network-blocked\\n' > /workspace/network-result.txt; sleep 300 & wait"
    ]

    {resource_id, record} =
      expect_launch!(
        Manager.launch(launch_spec(workspace, reference, digest, lease.id, "security"),
          server: manager,
          allowed_roots: [root],
          command: command,
          timeout_ms: 60_000
        ),
        "Apple security fixture launch"
      )

    remember(resource_id)
    wait_for_file!(Path.join(workspace, "network-result.txt"), 20_000)

    manifest = record.resource.manifest
    observed = record.resource.observed
    assert!(manifest.machine_id == resource_id, "launch manifest did not persist VM identity")
    assert!(observed.machine_id == resource_id, "inspection did not attest VM identity")
    assert!(observed.rootfs_mode == :read_only, "root filesystem is not read-only")
    assert!(observed.dropped_capabilities == ["ALL"], "capabilities were not dropped")
    assert!(observed.security_options == [], "Apple security evidence fabricated OCI options")
    assert!(observed.network_mode == :none, "network-none was not attested")
    assert!(observed.uid == 65_532 and observed.gid == 65_532, "worker is not non-root")

    assert!(
      observed.limits == %{cpu: 1, memory_bytes: @memory_bytes, pids: @pids},
      "limits drifted"
    )

    assert!(
      File.read!(Path.join(workspace, "mount.txt")) == "mount-write-ok\n",
      "workspace write failed"
    )

    assert!(
      File.read!(Path.join(workspace, "network-result.txt")) == "network-blocked\n",
      "network none failed"
    )

    assert!(
      File.read!(Path.join(workspace, "control-result.txt")) == "controls-blocked\n",
      "guest control channel exposed"
    )

    GenServer.stop(manager, :normal)

    recovery_started = System.monotonic_time(:millisecond)

    resumed =
      Reconciler.reconcile(%{resource_id => %{manifest: manifest}}, AppleContainer,
        timeout_ms: 60_000
      )

    recovery_ms = System.monotonic_time(:millisecond) - recovery_started

    assert!(resumed[resource_id].status == :resume, "matching VM did not resume")

    wrong_vm = %{manifest | machine_id: "wrong-vm"}

    drifted =
      Reconciler.reconcile(%{resource_id => %{manifest: wrong_vm}}, AppleContainer,
        timeout_ms: 60_000
      )

    assert!(drifted[resource_id].status == :quarantine, "VM identity drift did not quarantine")

    :ok = AppleContainer.stop(resource_id, grace_seconds: 1, timeout_ms: 60_000)
    :ok = AppleContainer.destroy(resource_id, timeout_ms: 60_000)
    forget(resource_id)
    :ok = Admission.release(record.admission_lease_id, server: admission)
    :ok = Broker.revoke(lease.id, server: broker)

    cancel_lease = issue_lease!(broker, "apple-cancel-session")

    {:ok, cancel_manager} =
      Manager.start_link(
        name: :apple_qualification_cancel_manager,
        backend: AppleContainer,
        admission: admission,
        credential_broker: broker
      )

    cancel_workspace = prepare_workspace!(Path.join(root, "cancel"))

    {:ok, cancel_id, _record} =
      Manager.launch(launch_spec(cancel_workspace, reference, digest, cancel_lease.id, "cancel"),
        server: cancel_manager,
        allowed_roots: [root],
        command: ["/bin/sh", "-lc", "sleep 300 & wait"],
        timeout_ms: 60_000
      )

    remember(cancel_id)
    started = System.monotonic_time(:millisecond)
    :ok = Manager.cancel(cancel_id, server: cancel_manager, grace_seconds: 1, timeout_ms: 60_000)
    cancellation_ms = System.monotonic_time(:millisecond) - started
    forget(cancel_id)

    {:error, :credential_lease_revoked} =
      Broker.authorize(
        cancel_lease.access_token,
        %{
          session_id: "apple-cancel-session",
          model: "qualification-model",
          destination: "provider.invalid",
          amount: 1
        },
        server: broker
      )

    {:ok, managed} = AppleContainer.managed_resources(timeout_ms: 60_000)
    refute!(cancel_id in managed, "cancelled VM remains managed")

    {%{
       launch_attestation: "pass",
       distinct_vm_identity: "pass",
       vm_identity_recovery: "resume",
       vm_identity_drift: "quarantine",
       mount_write: "pass",
       network_none: "pass",
       guest_control_channels: "denied",
       host_credentials: "not mounted",
       rootfs: "read_only",
       uid: 65_532,
       gid: 65_532,
       capabilities: "drop_all",
       no_new_privileges: "not exposed or claimed",
       credential_revocation: "pass",
       cancellation_cleanup: "pass"
     }, cancellation_ms, recovery_ms}
  end

  defp performance_qualification(root, reference, digest, cancellation_ms, recovery_ms) do
    samples =
      Enum.map(1..@samples, fn index ->
        workspace = prepare_workspace!(Path.join(root, "repeat-#{index}"))
        timed_worker(workspace, reference, digest, "repeat-#{index}")
      end)

    concurrent_started = System.monotonic_time(:millisecond)

    concurrent =
      1..2
      |> Task.async_stream(
        fn index ->
          workspace = prepare_workspace!(Path.join(root, "concurrent-#{index}"))
          timed_worker(workspace, reference, digest, "concurrent-#{index}", hold_ms: 1_000)
        end,
        max_concurrency: 2,
        ordered: true,
        timeout: 120_000
      )
      |> Enum.map(fn {:ok, sample} -> sample end)

    ids = Enum.map(concurrent, & &1.machine_id)
    assert!(MapSet.size(MapSet.new(ids)) == 2, "concurrent workers reused a VM identity")

    guest_envelope =
      AppleContainer.memory_envelope(Enum.map(samples, & &1.guest_memory_bytes), @memory_bytes)

    host_peak =
      (samples ++ concurrent)
      |> Enum.map(& &1.host_vm_rss_bytes)
      |> Enum.max(fn -> 0 end)

    host_high_water = trunc(@memory_bytes * 2 * 1.25)

    {:ok, managed} = AppleContainer.managed_resources(timeout_ms: 60_000)
    history = @resource_table |> :ets.tab2list() |> Enum.map(&elem(&1, 0))
    leftovers = Enum.filter(history, &(&1 in managed))
    assert!(leftovers == [], "qualification left managed Apple VMs: #{inspect(leftovers)}")

    %{
      repeated_samples: samples,
      concurrent_samples: concurrent,
      repeated_count: @samples,
      concurrent_count: 2,
      concurrent_elapsed_ms: System.monotonic_time(:millisecond) - concurrent_started,
      cancellation_ms: cancellation_ms,
      recovery_ms: recovery_ms,
      guest_memory_envelope: guest_envelope,
      host_vm_peak_rss_bytes: host_peak,
      host_high_water_bytes: host_high_water,
      backend_restart_policy:
        if(host_peak > host_high_water, do: "restart_required", else: "within_high_water"),
      all_resources_destroyed: leftovers == []
    }
  end

  defp copy_snapshot_qualification(root, reference, digest) do
    source = prepare_workspace!(Path.join(root, "copy-snapshot-source"))
    output = prepare_workspace!(Path.join(root, "copy-snapshot-output"))
    File.write!(Path.join(source, "README.md"), "isolated snapshot\n")
    File.chmod!(Path.join(source, "README.md"), 0o666)

    spec =
      launch_spec(source, reference, digest, nil, "copy-snapshot", :copy_snapshot)
      |> Map.delete(:reservation)

    manifest =
      expect_ok!(
        AppleContainer.prepare(spec, allowed_roots: [root]),
        "Apple copy snapshot prepare"
      )

    command = [
      "/bin/sh",
      "-lc",
      "set -eu; test \"$(cat README.md)\" = 'isolated snapshot'; " <>
        "if printf denied > /run/twelvgaige-import/workspace/escape.txt 2>/dev/null; then exit 72; fi; " <>
        "printf 'qualified\\n' > result.txt; sleep 300 & wait"
    ]

    {:ok, id, resource} =
      AppleContainer.create(manifest, command: command, timeout_ms: 60_000)

    remember(id)
    {:ok, _process} = AppleContainer.start(id, timeout_ms: 60_000)

    observed = resource.observed
    host_mounts = Enum.filter(observed.mounts, &(&1.type in ["bind", :bind]))
    volumes = Enum.filter(observed.mounts, &(&1.type in ["volume", :volume]))

    assert!(
      Enum.all?(host_mounts, &(&1.mode == :read_only)),
      "Apple copy_snapshot retained a writable host bind mount"
    )

    assert!(
      Enum.any?(volumes, &(&1.destination == "/workspace" and &1.mode == :read_write)),
      "Apple copy_snapshot did not use sandbox-owned writable storage"
    )

    refute!(File.exists?(Path.join(source, "result.txt")), "Apple copy_snapshot wrote to input")
    refute!(File.exists?(Path.join(source, "escape.txt")), "Apple copy_snapshot changed input")

    :ok = AppleContainer.stop(id, grace_seconds: 1, timeout_ms: 60_000)

    export =
      expect_ok!(
        AppleContainer.export(id, output, ["result.txt"],
          manifest: resource.manifest,
          allowed_export_roots: [output],
          max_export_bytes: 1_024,
          timeout_ms: 60_000
        ),
        "Apple declared export"
      )

    assert!(File.read!(Path.join(output, "result.txt")) == "qualified\n", "Apple export drifted")
    assert!(export.bytes == 10, "Apple export byte accounting drifted")

    :ok = AppleContainer.destroy(id, timeout_ms: 60_000)
    forget(id)

    %{
      copy_snapshot: "pass",
      copy_snapshot_no_writable_host_mount: "pass",
      copy_snapshot_import_read_only: "pass",
      copy_snapshot_declared_export: "pass",
      copy_snapshot_volume_bootstrap: "host_controlled_ephemeral_vm",
      copy_snapshot_export_bytes: export.bytes
    }
  end

  defp timed_worker(workspace, reference, digest, label, opts \\ []) do
    spec = launch_spec(workspace, reference, digest, nil, label)

    {:ok, manifest} =
      AppleContainer.prepare(Map.delete(spec, :reservation),
        allowed_roots: [Path.dirname(workspace)]
      )

    started = System.monotonic_time(:millisecond)

    {:ok, id, resource} =
      AppleContainer.create(manifest,
        command: ["/bin/sh", "-lc", "printf ready > /workspace/ready; sleep 300 & wait"],
        timeout_ms: 60_000
      )

    remember(id)
    {:ok, _process} = AppleContainer.start(id, timeout_ms: 60_000)
    wait_for_file!(Path.join(workspace, "ready"), 20_000)
    launch_ms = System.monotonic_time(:millisecond) - started
    Process.sleep(Keyword.get(opts, :hold_ms, 0))

    guest_memory =
      case AppleContainer.stats(id, timeout_ms: 60_000) do
        {:ok, %{memory_bytes: bytes}} when is_integer(bytes) -> bytes
        _other -> 0
      end

    host_rss = host_vm_rss(id)
    :ok = AppleContainer.stop(id, grace_seconds: 1, timeout_ms: 60_000)
    :ok = AppleContainer.destroy(id, timeout_ms: 60_000)
    forget(id)

    %{
      machine_id: resource.manifest.machine_id,
      launch_ms: launch_ms,
      guest_memory_bytes: guest_memory,
      host_vm_rss_bytes: host_rss
    }
  end

  defp launch_spec(
         workspace,
         reference,
         digest,
         credential_lease_id,
         label,
         transport \\ :bind_worktree
       ) do
    %{
      profile: :coding_restricted,
      image_reference: reference,
      image_digest: digest,
      workspace_transport: transport,
      mounts: [%{source: workspace, destination: "/workspace", mode: :read_write}],
      network_mode: :none,
      allowed_destinations: [],
      limits: %{cpu: 1, memory_bytes: @memory_bytes, pids: @pids},
      deadline: DateTime.add(DateTime.utc_now(), 600),
      credential_lease_id: credential_lease_id,
      policy_revision: "apple-container-qualification-1",
      created_at: DateTime.utc_now(),
      labels: %{"io.twelvgaige.qualification" => label},
      reservation: %{sandboxes: 1, cpu: 1, memory_bytes: @memory_bytes, pids: @pids}
    }
  end

  defp admission_limits(sandboxes),
    do: %{
      sandboxes: sandboxes,
      cpu: sandboxes,
      memory_bytes: sandboxes * @memory_bytes,
      pids: sandboxes * @pids,
      workspace_bytes: 1_073_741_824,
      artifact_bytes: 1_073_741_824,
      provider_tokens: 1_000_000
    }

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
          destinations: ["provider.invalid"],
          models: ["qualification-model"],
          budget: 10,
          expires_at: DateTime.add(DateTime.utc_now(), 600),
          upstream_secret: "ephemeral-qualification-only"
        },
        server: broker
      )

    lease
  end

  defp prepare_workspace!(path) do
    File.mkdir_p!(path)
    File.chmod!(path, 0o777)
    path
  end

  defp wait_for_file!(path, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_for_file(path, deadline)
  end

  defp wait_for_file(path, deadline) do
    cond do
      File.exists?(path) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        raise "timed out waiting for #{path}"

      true ->
        Process.sleep(100)
        wait_for_file(path, deadline)
    end
  end

  defp host_vm_rss(resource_id) do
    {output, 0} = System.cmd("ps", ["-axo", "rss=,command="])

    output
    |> String.split("\n")
    |> Enum.filter(
      &(String.contains?(&1, resource_id) or String.contains?(&1, "container-runtime-linux"))
    )
    |> Enum.map(fn line ->
      line |> String.trim() |> String.split(~r/\s+/, parts: 2) |> hd() |> parse_integer()
    end)
    |> Enum.sum()
    |> Kernel.*(1024)
  end

  defp host_metadata do
    %{
      hostname: elem(:inet.gethostname(), 1) |> List.to_string(),
      macos_version: String.trim(elem(System.cmd("sw_vers", ["-productVersion"]), 0)),
      architecture: String.trim(elem(System.cmd("uname", ["-m"]), 0)),
      logical_cpus: :erlang.system_info(:logical_processors_available),
      memory_bytes:
        case System.cmd("sysctl", ["-n", "hw.memsize"]) do
          {value, 0} -> value |> String.trim() |> parse_integer()
          _other -> 0
        end
    }
  end

  defp remember(id) do
    true = :ets.insert(@resource_table, {id, :active})
    :ok
  end

  defp forget(id) do
    true = :ets.insert(@resource_table, {id, :destroyed})
    :ok
  end

  defp cleanup do
    active =
      if :ets.whereis(@resource_table) == :undefined do
        []
      else
        :ets.select(@resource_table, [{{:"$1", :active}, [], [:"$1"]}])
      end

    Enum.each(active, fn id ->
      _ = AppleContainer.stop(id, grace_seconds: 1, timeout_ms: 10_000)
      _ = AppleContainer.destroy(id, timeout_ms: 10_000)
    end)
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> 0
    end
  end

  defp expect_ok!({:ok, value}, _label), do: value
  defp expect_ok!({:error, reason}, label), do: raise("#{label} failed: #{inspect(reason)}")
  defp expect_launch!({:ok, resource_id, record}, _label), do: {resource_id, record}
  defp expect_launch!({:error, reason}, label), do: raise("#{label} failed: #{inspect(reason)}")
  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)
  defp refute!(false, _message), do: :ok
  defp refute!(true, message), do: raise(message)
end

Twelvgaige.AppleContainerQualification.run()
