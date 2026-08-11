defmodule Twelvgaige.Sandbox.Backend.PodmanTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Sandbox.Backend.Podman
  alias Twelvgaige.Sandbox.LaunchManifest

  test "requires the dedicated machine and creates with enforced security flags before start" do
    parent = self()
    root = temp_dir()

    runner = fn _binary, args, _opts ->
      send(parent, {:podman, args})

      output =
        cond do
          Enum.take(args, 2) == ["version", "--format"] ->
            Jason.encode!(%{"Client" => %{"Version" => "5.5.0"}})

          Enum.take(args, 2) == ["machine", "inspect"] ->
            Jason.encode!([%{"Name" => "twelvgaige"}])

          Enum.take(args, 2) == ["machine", "ssh"] ->
            Jason.encode!(%{"filesystems" => []})

          hd(args) == "create" ->
            Enum.at(args, Enum.find_index(args, &(&1 == "--name")) + 1)

          hd(args) == "start" ->
            List.last(args)

          true ->
            ""
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end

    assert {:ok, %{machine_id: "twelvgaige", version: "5.5.0"}} =
             Podman.probe(command_runner: runner)

    assert_receive {:podman, ["version" | _]}
    assert_receive {:podman, ["machine", "inspect" | _]}
    assert_receive {:podman, ["machine", "ssh" | _]}

    spec = %{
      profile: :coding_restricted,
      image_reference: "registry.example/worker",
      image_digest: "sha256:" <> String.duplicate("a", 64),
      workspace_transport: :bind_worktree,
      mounts: [%{source: root, destination: "/workspace", mode: :read_write}],
      network_mode: :none,
      allowed_destinations: [],
      limits: %{cpu: 2, memory_bytes: 1024, pids: 100},
      deadline: DateTime.add(DateTime.utc_now(), 300),
      policy_revision: "policy-1",
      created_at: DateTime.utc_now(),
      environment_names: ["CODEX_HOME"]
    }

    assert {:ok, manifest} =
             Podman.prepare(spec, allowed_roots: [root], backend_version: "5.5.0")

    observed_factory = fn manifest ->
      %{
        image_digest: manifest.image_digest,
        mounts: manifest.mounts,
        uid: manifest.uid,
        gid: manifest.gid,
        rootfs_mode: manifest.rootfs_mode,
        dropped_capabilities: manifest.dropped_capabilities,
        security_options: manifest.security_options,
        network_mode: manifest.network_mode,
        limits: manifest.limits,
        environment_names: manifest.environment_names,
        labels: manifest.labels
      }
    end

    assert {:ok, resource_id, %{status: :created}} =
             Podman.create(manifest,
               command_runner: runner,
               observed_factory: observed_factory,
               environment: %{"CODEX_HOME" => "/run/codex-home"},
               command: ["sleep", "infinity"]
             )

    assert_receive {:podman, create_args}
    assert hd(create_args) == "create"
    assert "--read-only" in create_args
    assert "--interactive" in create_args
    assert contiguous?(create_args, ["--cap-drop", "ALL"])
    assert contiguous?(create_args, ["--security-opt", "no-new-privileges"])
    assert contiguous?(create_args, ["--network", "none"])
    assert contiguous?(create_args, ["--env", "CODEX_HOME=/run/codex-home"])

    assert {:ok, %{status: :running}} = Podman.start(resource_id, command_runner: runner)

    runtime_binary = System.find_executable("sh")

    assert {:ok,
            %{
              binary: ^runtime_binary,
              arguments: ["start", "--attach", "--interactive", ^resource_id],
              environment: [{"PATH", "/qualified/bin"}]
            }} =
             Podman.stdio_transport(resource_id,
               podman_binary: runtime_binary,
               transport_environment: [{"PATH", "/qualified/bin"}]
             )
  end

  test "restricted health rejects broad machine mounts and accepts declared roots" do
    root = temp_dir()

    runner = fn _binary, args, _opts ->
      output =
        case Enum.take(args, 2) do
          ["version", "--format"] ->
            Jason.encode!(%{"Client" => %{"Version" => "5.5.0"}})

          ["machine", "inspect"] ->
            Jason.encode!([%{"Name" => "twelvgaige"}])

          ["machine", "ssh"] ->
            Jason.encode!(%{"filesystems" => [%{"target" => root, "fstype" => "virtiofs"}]})
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end

    assert {:error, {:podman_unavailable, {:podman_machine_mount_mismatch, [], [observed_root]}}} =
             Podman.probe(command_runner: runner)

    assert observed_root == Path.expand(root)

    assert {:ok, %{available: true}} =
             Podman.probe(command_runner: runner, machine_allowed_mounts: [root])
  end

  test "normalizes live Podman inspection semantics for attestation" do
    root = temp_dir()
    parent = self()

    runner = fn _binary, args, _opts ->
      send(parent, {:podman, args})

      output =
        case hd(args) do
          "create" ->
            Process.put(:live_manifest_digest, label_value(args, "io.twelvgaige.manifest"))
            Enum.at(args, Enum.find_index(args, &(&1 == "--name")) + 1)

          "inspect" ->
            live_inspect_fixture(root, args, Process.get(:live_manifest_digest))

          "rm" ->
            ""
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end

    spec = %{
      profile: :coding_restricted,
      image_reference: "localhost/twelvgaige/worker",
      image_digest: "sha256:" <> String.duplicate("a", 64),
      workspace_transport: :bind_worktree,
      mounts: [%{source: root, destination: "/workspace", mode: :read_write}],
      network_mode: :none,
      allowed_destinations: [],
      limits: %{cpu: 1, memory_bytes: 268_435_456, pids: 32},
      deadline: DateTime.add(DateTime.utc_now(), 300),
      policy_revision: "policy-1",
      created_at: DateTime.utc_now()
    }

    assert {:ok, manifest} = Podman.prepare(spec, allowed_roots: [root])

    assert {:ok, _resource_id, %{observed: observed, manifest: created_manifest}} =
             Podman.create(manifest, command_runner: runner)

    assert observed.dropped_capabilities == ["ALL"]
    assert observed.limits.cpu == 1
    assert observed.labels == created_manifest.labels
  end

  test "full workspace export replaces the managed copy only after staging validation" do
    root = temp_dir()
    destination = Path.join(root, "managed-workspace")
    File.mkdir_p!(destination)
    File.write!(Path.join(destination, "deleted.txt"), "old\n")

    spec = %{
      profile: :coding_restricted,
      image_reference: "localhost/twelvgaige/worker",
      image_digest: "sha256:" <> String.duplicate("a", 64),
      workspace_transport: :copy_snapshot,
      mounts: [%{source: destination, destination: "/workspace", mode: :read_write}],
      network_mode: :none,
      allowed_destinations: [],
      limits: %{cpu: 1, memory_bytes: 268_435_456, pids: 32},
      deadline: DateTime.add(DateTime.utc_now(), 300),
      policy_revision: "policy-1",
      created_at: DateTime.utc_now()
    }

    assert {:ok, prepared} = Podman.prepare(spec, allowed_roots: [root])
    manifest = LaunchManifest.bind_resource(prepared, "sbx_full_export")

    runner = fn _binary, ["cp", "--archive=false", _source, staging], _opts ->
      File.write!(Path.join(staging, "result.txt"), "qualified\n")
      {:ok, %{status: 0, stdout: "", stderr: "", duration_ms: 1}}
    end

    assert {:ok, %{managed_snapshot_replaced: true, bytes: 10}} =
             Podman.export_workspace("sbx_full_export", destination,
               manifest: manifest,
               allowed_export_roots: [root],
               max_export_bytes: 1_024,
               command_runner: runner
             )

    assert File.read!(Path.join(destination, "result.txt")) == "qualified\n"
    refute File.exists?(Path.join(destination, "deleted.txt"))
  end

  defp contiguous?(values, pair),
    do: Enum.chunk_every(values, length(pair), 1, :discard) |> Enum.member?(pair)

  defp live_inspect_fixture(root, args, manifest_digest) do
    resource_id = hd(tl(args))

    Jason.encode!([
      %{
        "ImageDigest" => "sha256:" <> String.duplicate("a", 64),
        "Config" => %{
          "User" => "65532:65532",
          "Labels" => %{
            "io.twelvgaige.managed" => "true",
            "io.twelvgaige.resource" => resource_id,
            "io.twelvgaige.manifest" => manifest_digest,
            "org.opencontainers.image.title" => "worker"
          },
          "CreateCommand" => ["podman", "create", "--cap-drop", "ALL"]
        },
        "HostConfig" => %{
          "ReadonlyRootfs" => true,
          "CapDrop" => ["CAP_CHOWN", "CAP_SETUID"],
          "SecurityOpt" => ["no-new-privileges"],
          "NetworkMode" => "none",
          "NanoCpus" => 1_000_000_000,
          "Memory" => 268_435_456,
          "PidsLimit" => 32
        },
        "Mounts" => [
          %{"Source" => root, "Destination" => "/workspace", "RW" => true}
        ]
      }
    ])
  end

  defp label_value(args, name) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--label", value] ->
        case String.split(value, "=", parts: 2) do
          [^name, label_value] -> label_value
          _other -> nil
        end

      _pair ->
        nil
    end)
  end

  defp temp_dir do
    path = Path.join(System.tmp_dir!(), "twelvgaige-podman-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
