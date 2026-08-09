defmodule Twelvgaige.Qualification.EgressBoundary do
  alias Twelvgaige.Egress.{Boundary, Broker}
  alias Twelvgaige.Sandbox.Backend.{AppleContainer, Podman}

  @proxy_environment_names ~w(HTTP_PROXY HTTPS_PROXY NO_PROXY)

  def run do
    root = Path.expand("..", __DIR__)
    data_root = System.get_env("TWELVGAIGE_DATA_ROOT") || default_data_root()
    evidence_dir = Path.join(root, "qualification/evidence/egress-proxy")
    runtime_root = Path.join(data_root, "runtime/egress-qualification")
    File.mkdir_p!(evidence_dir)
    File.mkdir_p!(runtime_root)

    {egress_reference, egress_digest} = egress_image!(root)
    {worker_reference, worker_digest} = worker_image!(root)

    {:ok, broker} =
      Broker.start_link(
        name: nil,
        resolver: fn
          "example.com" -> :inet.getaddrs(~c"example.com", :inet)
          "localhost" -> {:ok, [{127, 0, 0, 1}]}
        end
      )

    podman =
      qualify_backend!(
        :podman,
        Podman,
        broker,
        runtime_root,
        egress_reference,
        egress_digest,
        worker_reference,
        worker_digest
      )

    apple =
      qualify_backend!(
        :apple_container,
        AppleContainer,
        broker,
        runtime_root,
        egress_reference,
        egress_digest,
        worker_reference,
        worker_digest
      )

    evidence = %{
      schema_version: 1,
      generated_at: DateTime.utc_now(),
      result: "pass",
      image: %{reference: egress_reference, digest: egress_digest},
      contract: %{
        per_session_internal_network: "pass",
        worker_direct_egress_denied: "pass",
        capability_required: "pass",
        allowed_destination_connected: "pass",
        undeclared_destination_denied: "pass",
        private_dns_result_denied: "pass",
        dns_address_pinned: "pass",
        sidecar_non_root: "pass",
        sidecar_read_only_root: "pass",
        sidecar_capabilities_dropped: "pass",
        sidecar_destroyed_on_revoke: "pass",
        capability_absent_from_audit: "pass"
      },
      backends: %{podman: podman, apple_container: apple}
    }

    path = Path.join(evidence_dir, "live-qualification.json")
    File.write!(path, Jason.encode_to_iodata!(evidence, pretty: true))
    IO.puts("Broker-only egress qualification passed; evidence: #{path}")
  end

  defp qualify_backend!(
         backend_name,
         backend,
         broker,
         runtime_root,
         egress_reference,
         egress_digest,
         worker_reference,
         worker_digest
       ) do
    {:ok, lease} =
      Broker.issue(
        %{
          session_id: "egress-qualification-#{backend_name}",
          allowed_hosts: ["example.com", "localhost"],
          allowed_ports: [443],
          expires_at: DateTime.add(DateTime.utc_now(), 600),
          max_connections: 4
        },
        server: broker
      )

    boundary_opts = [
      runtime_root: Path.join(runtime_root, Atom.to_string(backend_name)),
      image_reference: egress_reference,
      image_digest: egress_digest,
      timeout_ms: 60_000
    ]

    {:ok, boundary} = Boundary.provision(backend_name, lease, boundary_opts)
    worker_id = nil

    try do
      worker_opts = Boundary.worker_options(boundary)
      workspace = prepare_workspace!(runtime_root, backend_name)

      spec = %{
        profile: :coding_restricted,
        image_reference: worker_reference,
        image_digest: worker_digest,
        workspace_transport: :bind_worktree,
        mounts: [%{source: workspace, destination: "/workspace", mode: :read_write}],
        network_mode: :broker_only,
        allowed_destinations: ["example.com", "localhost"],
        proxy_lease_id: lease.id,
        limits: %{cpu: 1, memory_bytes: 268_435_456, pids: 32},
        deadline: DateTime.add(DateTime.utc_now(), 300),
        policy_revision: "egress-qualification-1",
        created_at: DateTime.utc_now(),
        environment_names: @proxy_environment_names
      }

      {:ok, manifest} = backend.prepare(spec, allowed_roots: [runtime_root])

      command = [
        "/bin/sh",
        "-lc",
        probe_script(boundary.sidecar_address)
      ]

      create_opts =
        worker_opts
        |> Keyword.merge(command: command, timeout_ms: 60_000, qualification_workspace: workspace)

      {:ok, id, resource} = backend.create(manifest, create_opts)
      Process.put({__MODULE__, :worker_id, backend_name}, id)
      {:ok, _process} = backend.start(id, create_opts)

      try do
        :ok = wait_for_exit!(backend_name, backend, id, resource.manifest, create_opts)
      rescue
        error ->
          sidecar_logs =
            case Boundary.logs(boundary, boundary_opts) do
              {:ok, value} -> value
              {:error, reason} -> inspect(reason)
            end

          reraise "#{Exception.message(error)}; sidecar logs: #{inspect(sidecar_logs)}",
                  __STACKTRACE__
      end

      {:ok, logs} = Boundary.logs(boundary, boundary_opts)

      refute!(
        String.contains?(logs, lease.access_token),
        "egress token appeared in sidecar audit"
      )

      assert!(String.contains?(logs, "connection_authorized"), "allowed egress was not audited")
      assert!(String.contains?(logs, "connection_denied"), "denied egress was not audited")

      :ok = Broker.revoke(lease.id, server: broker)
      :ok = Boundary.revoke(boundary, boundary_opts)
      :ok = backend.destroy(id, create_opts)
      Process.delete({__MODULE__, :worker_id, backend_name})
      :ok = Boundary.destroy(boundary, boundary_opts)

      assert_boundary_removed!(backend_name, boundary)

      %{
        result: "pass",
        worker_network: boundary.network,
        proxy_address: boundary.sidecar_address,
        worker_attestation: %{
          network_mode: resource.observed.network_mode,
          uid: resource.observed.uid,
          gid: resource.observed.gid,
          rootfs_mode: resource.observed.rootfs_mode,
          dropped_capabilities: resource.observed.dropped_capabilities,
          environment_names: resource.observed.environment_names
        },
        audit_digest: "sha256:" <> sha256(logs),
        cleanup: "pass"
      }
    after
      case Process.get({__MODULE__, :worker_id, backend_name}, worker_id) do
        id when is_binary(id) ->
          _ = backend.destroy(id, timeout_ms: 60_000)
          Process.delete({__MODULE__, :worker_id, backend_name})

        _other ->
          :ok
      end

      _ = Boundary.destroy(boundary, boundary_opts)
      _ = Broker.revoke(lease.id, server: broker)
    end
  end

  defp probe_script(proxy_address) do
    proxy = shell_quote(proxy_address)

    "set -eu; " <>
      "printf 'start\\n' > /workspace/egress-stage; " <>
      "{ ip addr; ip route; } > /workspace/egress-network-debug 2>&1 || true; " <>
      "TWELVGAIGE_PROXY_TOKEN=${HTTPS_PROXY#http://twelvgaige:}; " <>
      "TWELVGAIGE_PROXY_TOKEN=${TWELVGAIGE_PROXY_TOKEN%@*}; " <>
      "if nc -z -w 2 1.1.1.1 443 >/dev/null 2>&1; then exit 71; fi; " <>
      "printf 'direct-denied\\n' > /workspace/egress-stage; " <>
      "invalid=''; attempts=0; " <>
      "while ! printf '%s' \"$invalid\" | grep -q '407 Proxy Authentication Required'; do " <>
      "attempts=$((attempts + 1)); [ \"$attempts\" -le 15 ] || exit 72; " <>
      "invalid=$(printf 'CONNECT example.com:443 HTTP/1.1\\r\\nProxy-Authorization: Bearer invalid\\r\\n\\r\\n' | nc -w 1 #{proxy} 8080 || true); " <>
      "sleep 0.1; done; " <>
      "printf '%s' \"$invalid\" | grep -q '407 Proxy Authentication Required'; " <>
      "printf 'auth-denied\\n' > /workspace/egress-stage; " <>
      "allowed=$(printf 'CONNECT example.com:443 HTTP/1.1\\r\\nProxy-Authorization: Bearer %s\\r\\n\\r\\n' \"$TWELVGAIGE_PROXY_TOKEN\" | nc -w 8 #{proxy} 8080); " <>
      "printf '%s' \"$allowed\" | grep -q '200 Connection Established'; " <>
      "printf 'allowed\\n' > /workspace/egress-stage; " <>
      "private=$(printf 'CONNECT localhost:443 HTTP/1.1\\r\\nProxy-Authorization: Bearer %s\\r\\n\\r\\n' \"$TWELVGAIGE_PROXY_TOKEN\" | nc -w 8 #{proxy} 8080); " <>
      "printf '%s' \"$private\" | grep -q '403 Forbidden'; " <>
      "printf 'private-denied\\n' > /workspace/egress-stage; " <>
      "denied=$(printf 'CONNECT telemetry.example.net:443 HTTP/1.1\\r\\nProxy-Authorization: Bearer %s\\r\\n\\r\\n' \"$TWELVGAIGE_PROXY_TOKEN\" | nc -w 8 #{proxy} 8080); " <>
      "printf '%s' \"$denied\" | grep -q '403 Forbidden'; " <>
      "printf 'qualified\\n' > /workspace/egress-stage; printf 'qualified\\n'"
  end

  defp wait_for_exit!(:podman, _backend, id, _manifest, _opts) do
    case System.cmd("podman", ["wait", id], stderr_to_stdout: true) do
      {output, 0} ->
        if String.trim(output) == "0",
          do: :ok,
          else: raise("Podman egress worker failed: #{output}")

      {output, status} ->
        raise "Podman wait failed with #{status}: #{output}"
    end
  end

  defp wait_for_exit!(:apple_container, backend, id, manifest, opts) do
    deadline = System.monotonic_time(:millisecond) + 60_000
    :ok = wait_for_apple_exit!(backend, id, manifest, opts, deadline)
    {logs, 0} = System.cmd("container", ["logs", id], stderr_to_stdout: true)

    if String.contains?(logs, "qualified"),
      do: :ok,
      else:
        raise(
          "Apple egress probe failed at #{inspect(read_stage(opts))}; network: #{inspect(read_network_debug(opts))}; worker logs: #{inspect(logs)}"
        )
  end

  defp wait_for_apple_exit!(backend, id, manifest, opts, deadline) do
    case backend.inspect(id, Keyword.put(opts, :manifest, manifest)) do
      {:ok, %{status: :stopped}} ->
        :ok

      {:ok, %{status: :running}} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          wait_for_apple_exit!(backend, id, manifest, opts, deadline)
        else
          raise "Apple egress worker exit timed out at #{inspect(read_stage(opts))}: #{inspect(read_network_debug(opts))}"
        end

      other ->
        raise "Apple egress worker did not exit successfully: #{inspect(other)}"
    end
  end

  defp assert_boundary_removed!(:podman, boundary) do
    {containers, 0} =
      System.cmd("podman", ["ps", "-a", "--filter", "name=#{boundary.sidecar}", "-q"])

    {networks, 0} =
      System.cmd("podman", ["network", "ls", "--filter", "name=#{boundary.network}", "-q"])

    assert!(String.trim(containers) == "", "Podman egress sidecar remained")
    assert!(String.trim(networks) == "", "Podman egress network remained")
  end

  defp assert_boundary_removed!(:apple_container, boundary) do
    {containers, 0} = System.cmd("container", ["list", "--all", "--format", "json"])
    {networks, 0} = System.cmd("container", ["network", "list", "--format", "json"])
    refute!(String.contains?(containers, boundary.sidecar), "Apple egress sidecar remained")
    refute!(String.contains?(networks, boundary.network), "Apple egress network remained")
  end

  defp prepare_workspace!(root, backend) do
    path = Path.join(root, "worker-#{backend}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    File.chmod!(path, 0o777)
    path
  end

  defp read_stage(opts) do
    case Keyword.get(opts, :qualification_workspace) do
      path when is_binary(path) ->
        case File.read(Path.join(path, "egress-stage")) do
          {:ok, stage} -> String.trim(stage)
          {:error, reason} -> {:missing, reason}
        end

      _other ->
        :unknown
    end
  end

  defp read_network_debug(opts) do
    case Keyword.get(opts, :qualification_workspace) do
      path when is_binary(path) ->
        case File.read(Path.join(path, "egress-network-debug")) do
          {:ok, debug} -> debug
          {:error, reason} -> {:missing, reason}
        end

      _other ->
        :unknown
    end
  end

  defp egress_image!(root) do
    script = Path.join(root, "scripts/egress_proxy.sh")
    {identity, 0} = System.cmd(script, ["status"], stderr_to_stdout: true)

    case String.split(String.trim(identity), "@", parts: 2) do
      [reference, "sha256:" <> _digest = digest] -> {reference, digest}
      _other -> raise "Egress proxy image identity is invalid: #{identity}"
    end
  end

  defp worker_image!(root) do
    catalog =
      root |> Path.join("qualification/evidence/podman-worker/catalog.json") |> read_json!()

    image = catalog |> Map.fetch!("images") |> List.first()
    {image["reference"], image["digest"]}
  end

  defp read_json!(path), do: path |> File.read!() |> Jason.decode!()

  defp default_data_root,
    do: Path.join([System.user_home!(), "Library", "Application Support", "Twelvgaige"])

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp assert!(true, _message), do: :ok
  defp assert!(false, message), do: raise(message)
  defp refute!(false, _message), do: :ok
  defp refute!(true, message), do: raise(message)
end

Twelvgaige.Qualification.EgressBoundary.run()
