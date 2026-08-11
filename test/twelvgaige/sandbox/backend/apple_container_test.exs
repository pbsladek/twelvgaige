defmodule Twelvgaige.Sandbox.Backend.AppleContainerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Sandbox.Backend.AppleContainer
  alias Twelvgaige.Sandbox.LaunchManifest

  test "onboarding leaves a healthy signed service running and starts only a stopped service" do
    parent = self()

    assert {:ok, "already running"} =
             AppleContainer.ensure_system_started(
               command_runner: service_runner(parent, "Status: running\n"),
               container_binary_path: "/usr/local/bin/container"
             )

    refute_received {:service_start, _args}

    assert {:ok, "started"} =
             AppleContainer.ensure_system_started(
               command_runner: service_runner(parent, "Status: stopped\n"),
               container_binary_path: "/usr/local/bin/container"
             )

    assert_receive {:service_start, ["system", "start"]}
  end

  test "probes the pinned host/runtime contract and creates an attested per-session VM" do
    parent = self()
    root = temp_dir()
    digest = "sha256:" <> String.duplicate("a", 64)

    runner = fn binary, args, _opts ->
      send(parent, {:command, binary, args})

      output =
        case {Path.basename(binary), args} do
          {"codesign", ["--verify", "--strict", "/usr/local/bin/container"]} ->
            ""

          {"codesign", ["-d", "--verbose=2", "/usr/local/bin/container"]} ->
            "Identifier=com.apple.container.cli\nTeamIdentifier=UPBK2H6LZM\n"

          {"container", ["--version"]} ->
            "container CLI version 1.2.0 (build: release, commit: pinned)\n"

          {"container", ["system", "status"]} ->
            "Status: running\napiserver version: 1.2.0\n"

          {"sw_vers", ["-productVersion"]} ->
            "26.6\n"

          {"uname", ["-m"]} ->
            "arm64\n"

          {"container", ["image", "inspect", image]} ->
            Jason.encode!(%{"configuration" => %{"name" => image}})

          {"container", ["volume", action | _args]}
          when action in ["create", "delete"] ->
            ""

          {"container", ["volume", "list", "--format", "json"]} ->
            "[]"

          {"container", ["run" | _args]} ->
            ""

          {"container", ["create" | create_args]} ->
            name = option(create_args, "--name")
            Process.put({:manifest_digest, name}, label(create_args, "io.twelvgaige.manifest"))
            name

          {"container", ["inspect", name]} ->
            inspect_fixture(root, name, digest, Process.get({:manifest_digest, name}))

          {"container", ["start", name]} ->
            name

          {"container", ["delete", "--force", _name]} ->
            ""
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end

    assert {:ok,
            %{
              backend: :apple_container,
              version: "1.2.0",
              architecture: "arm64",
              capabilities: %{vm_per_session: true},
              code_signature: %{verified: true, team_identifier: "UPBK2H6LZM"}
            }} =
             AppleContainer.probe(
               command_runner: runner,
               container_binary_path: "/usr/local/bin/container"
             )

    assert {:ok, manifest} =
             AppleContainer.prepare(spec(root, digest),
               allowed_roots: [root],
               backend_version: "1.2.0"
             )

    assert manifest.security_options == []
    assert manifest.capabilities.vm_per_session

    assert {:ok, resource_id, %{manifest: created, observed: observed}} =
             AppleContainer.create(manifest,
               command_runner: runner,
               command: ["sleep", "300"]
             )

    assert created.machine_id == resource_id
    refute created.manifest_digest == manifest.manifest_digest
    assert created.labels["io.twelvgaige.manifest"] == created.manifest_digest
    assert observed.machine_id == resource_id
    assert observed.security_options == []
    assert observed.limits == %{cpu: 1, memory_bytes: 268_435_456, pids: 32}
    assert :ok = LaunchManifest.attest(created, observed)

    assert_receive {:command, container_binary, ["create" | create_args]}
    assert Path.basename(container_binary) == "container"
    assert contiguous?(create_args, ["--cap-drop", "ALL"])
    assert "--read-only" in create_args
    assert "--interactive" in create_args
    assert contiguous?(create_args, ["--network", "none"])
    assert "--no-dns" in create_args
    refute "--security-opt" in create_args
    assert contiguous?(create_args, ["--ulimit", "nproc=32:32"])

    assert {:ok, %{status: :running, machine_id: ^resource_id}} =
             AppleContainer.start(resource_id, command_runner: runner)

    assert {:ok,
            %{
              binary: ^container_binary,
              arguments: ["start", "--attach", "--interactive", ^resource_id],
              environment: [{"PATH", "/qualified/bin"}]
            }} =
             AppleContainer.stdio_transport(resource_id,
               command_runner: runner,
               container_binary_path: container_binary,
               transport_environment: [{"PATH", "/qualified/bin"}]
             )
  end

  test "distinct workers have distinct VM identities and identity drift quarantines recovery" do
    root = temp_dir()
    digest = "sha256:" <> String.duplicate("b", 64)
    {:ok, manifest} = AppleContainer.prepare(spec(root, digest), allowed_roots: [root])

    observed = fn manifest -> evidence(manifest) end

    assert {:ok, first_id, %{manifest: first}} =
             AppleContainer.create(manifest,
               command_runner: success_runner(digest),
               observed_factory: observed
             )

    assert {:ok, second_id, %{manifest: second}} =
             AppleContainer.create(manifest,
               command_runner: success_runner(digest),
               observed_factory: observed
             )

    refute first_id == second_id
    refute first.machine_id == second.machine_id

    mismatched = %{evidence(first) | machine_id: second.machine_id}

    assert {:ok, :quarantine, ^mismatched} =
             AppleContainer.reconcile(%{resource_id: first_id, manifest: first},
               observed: mismatched
             )
  end

  test "memory high-water policy requires backend restart after reclamation drift" do
    assert %{status: :within_envelope, peak_bytes: 110} =
             AppleContainer.memory_envelope([80, %{memory_bytes: 110}], 100,
               high_water_ratio: 1.2
             )

    assert %{status: :backend_restart_required, high_water_bytes: 120} =
             AppleContainer.memory_envelope([121], 100, high_water_ratio: 1.2)
  end

  test "decodes Apple 1.2 one-shot memory statistics" do
    runner = fn binary, args, _opts ->
      output =
        cond do
          Path.basename(binary) == "codesign" and hd(args) == "-d" ->
            "Identifier=com.apple.container.cli\nTeamIdentifier=UPBK2H6LZM\n"

          Path.basename(binary) == "codesign" ->
            ""

          hd(args) == "stats" ->
            Jason.encode!([
              %{
                "id" => "vm",
                "memoryUsageBytes" => 3_739_648,
                "memoryLimitBytes" => 268_435_456,
                "numProcesses" => 1,
                "cpuUsageUsec" => 2_215
              }
            ])
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end

    assert {:ok,
            %{
              memory_bytes: 3_739_648,
              memory_limit_bytes: 268_435_456,
              processes: 1,
              cpu_usage_usec: 2_215
            }} = AppleContainer.stats("vm", command_runner: runner)
  end

  test "rejects unsupported runtime and non-integral MiB memory" do
    runner = fn binary, args, _opts ->
      output =
        case {Path.basename(binary), args} do
          {"codesign", ["--verify", "--strict", "/usr/local/bin/container"]} ->
            ""

          {"codesign", ["-d", "--verbose=2", "/usr/local/bin/container"]} ->
            "Identifier=com.apple.container.cli\nTeamIdentifier=UPBK2H6LZM\n"

          {"container", ["--version"]} ->
            "container CLI version 1.3.0"

          _other ->
            ""
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end

    assert {:error,
            {:apple_container_unavailable, {:unsupported_apple_container_version, "1.3.0"}}} =
             AppleContainer.probe(
               command_runner: runner,
               container_binary_path: "/usr/local/bin/container"
             )

    root = temp_dir()
    digest = "sha256:" <> String.duplicate("c", 64)
    bad = put_in(spec(root, digest), [:limits, :memory_bytes], 1_000_000)

    assert {:error, :apple_container_memory_must_be_whole_mib} =
             AppleContainer.prepare(bad, allowed_roots: [root])
  end

  test "a failed CLI signature check prevents every container control call" do
    root = temp_dir()
    digest = "sha256:" <> String.duplicate("e", 64)
    {:ok, manifest} = AppleContainer.prepare(spec(root, digest), allowed_roots: [root])

    runner = fn binary, args, _opts ->
      case {Path.basename(binary), args} do
        {"codesign", ["--verify", "--strict", _path]} ->
          {:ok, %{status: 1, stdout: "", stderr: "invalid signature", duration_ms: 1}}

        {"container", _args} ->
          flunk("an unverified CLI must never receive a control call")
      end
    end

    assert {:error, %{status: 1, output: "invalid signature"}} =
             AppleContainer.create(manifest, command_runner: runner)
  end

  test "declared export uses a capability-free helper after the worker stops" do
    root = temp_dir()
    output = Path.join(root, "output")
    digest = "sha256:" <> String.duplicate("f", 64)

    {:ok, prepared} = AppleContainer.prepare(spec(root, digest), allowed_roots: [root])
    manifest = LaunchManifest.bind_resource(prepared, "sbx_export", machine_id: "sbx_export")
    parent = self()

    runner = fn binary, args, _opts ->
      output_text =
        case {Path.basename(binary), args} do
          {"codesign", ["--verify", "--strict", "/usr/local/bin/container"]} ->
            ""

          {"codesign", ["-d", "--verbose=2", "/usr/local/bin/container"]} ->
            "Identifier=com.apple.container.cli\nTeamIdentifier=UPBK2H6LZM\n"

          {"container", ["run" | run_args]} ->
            send(parent, {:export_helper, run_args})

            staging =
              run_args
              |> Enum.find(&String.contains?(&1, "target=/export"))
              |> String.split(",")
              |> Enum.find_value(fn field ->
                case String.split(field, "=", parts: 2) do
                  ["source", path] -> path
                  _other -> nil
                end
              end)

            File.write!(Path.join(staging, "result.txt"), "qualified\n")
            ""
        end

      {:ok, %{status: 0, stdout: output_text, stderr: "", duration_ms: 1}}
    end

    assert {:ok, %{bytes: 10, exported: [%{path: "result.txt", bytes: 10}]}} =
             AppleContainer.export("sbx_export", output, ["result.txt"],
               manifest: manifest,
               observed: %{status: :stopped},
               allowed_export_roots: [root],
               command_runner: runner,
               container_binary_path: "/usr/local/bin/container"
             )

    assert File.read!(Path.join(output, "result.txt")) == "qualified\n"

    managed = Path.join(root, "managed")
    File.mkdir_p!(managed)
    File.write!(Path.join(managed, "deleted.txt"), "old\n")

    assert {:ok, %{managed_snapshot_replaced: true, bytes: 10}} =
             AppleContainer.export_workspace("sbx_export", managed,
               manifest: manifest,
               observed: %{status: :stopped},
               allowed_export_roots: [root],
               max_export_bytes: 1_024,
               command_runner: runner,
               container_binary_path: "/usr/local/bin/container"
             )

    assert File.read!(Path.join(managed, "result.txt")) == "qualified\n"
    refute File.exists?(Path.join(managed, "deleted.txt"))

    assert_receive {:export_helper, args}
    assert contiguous?(args, ["--user", "65532:65532"])
    assert contiguous?(args, ["--cap-drop", "ALL"])
    assert contiguous?(args, ["--network", "none"])
    assert "--read-only" in args
    assert Enum.any?(args, &String.contains?(&1, "target=/source,readonly"))
    assert Enum.any?(args, &String.contains?(&1, "target=/export"))
    refute Enum.any?(args, &String.contains?(&1, "source=#{root},target=/workspace"))

    assert {:error, :apple_export_requires_stopped_worker} =
             AppleContainer.export("sbx_export", Path.join(root, "second"), ["result.txt"],
               manifest: manifest,
               observed: %{status: :running},
               allowed_export_roots: [root],
               command_runner: runner,
               container_binary_path: "/usr/local/bin/container"
             )
  end

  defp spec(root, digest) do
    %{
      profile: :coding_restricted,
      image_reference: "localhost/twelvgaige/worker",
      image_digest: digest,
      workspace_transport: :copy_snapshot,
      mounts: [%{source: root, destination: "/workspace", mode: :read_write}],
      network_mode: :none,
      allowed_destinations: [],
      limits: %{cpu: 1, memory_bytes: 268_435_456, pids: 32},
      deadline: DateTime.add(DateTime.utc_now(), 300),
      policy_revision: "policy-1",
      created_at: DateTime.utc_now()
    }
  end

  defp service_runner(parent, status) do
    fn binary, args, _opts ->
      output =
        case {Path.basename(binary), args} do
          {"codesign", ["--verify", "--strict", "/usr/local/bin/container"]} ->
            ""

          {"codesign", ["-d", "--verbose=2", "/usr/local/bin/container"]} ->
            "Identifier=com.apple.container.cli\nTeamIdentifier=UPBK2H6LZM\n"

          {"container", ["--version"]} ->
            "container CLI version 1.2.0\n"

          {"container", ["system", "status"]} ->
            status

          {"container", ["system", "start"] = start_args} ->
            send(parent, {:service_start, start_args})
            "started"

          {"sw_vers", ["-productVersion"]} ->
            "26.0\n"

          {"uname", ["-m"]} ->
            "arm64\n"
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end
  end

  defp inspect_fixture(_root, name, digest, manifest_digest) do
    Jason.encode!(%{
      "id" => name,
      "status" => "stopped",
      "configuration" => %{
        "image" => %{"reference" => "localhost/twelvgaige/worker@#{digest}"},
        "initProcess" => %{
          "user" => %{"raw" => %{"userString" => "65532:65532"}},
          "rlimits" => [
            %{"limit" => "RLIMIT_NPROC", "soft" => 32, "hard" => 32}
          ]
        },
        "resources" => %{"cpus" => 1, "memoryInBytes" => 268_435_456},
        "readOnly" => true,
        "capDrop" => ["ALL"],
        "networks" => [],
        "mounts" => [
          %{
            "source" => name <> "-workspace",
            "destination" => "/workspace",
            "options" => [],
            "type" => "volume"
          }
        ],
        "labels" => %{
          "io.twelvgaige.managed" => "true",
          "io.twelvgaige.resource" => name,
          "io.twelvgaige.manifest" => manifest_digest
        }
      }
    })
  end

  defp evidence(manifest) do
    %{
      machine_id: manifest.machine_id,
      image_digest: manifest.image_digest,
      mounts: LaunchManifest.runtime_mounts(manifest),
      uid: manifest.uid,
      gid: manifest.gid,
      rootfs_mode: manifest.rootfs_mode,
      dropped_capabilities: manifest.dropped_capabilities,
      security_options: manifest.security_options,
      network_mode: manifest.network_mode,
      limits: manifest.limits,
      labels: manifest.labels
    }
  end

  defp success_runner(_digest) do
    fn binary, args, _opts ->
      output =
        cond do
          Path.basename(binary) == "codesign" and hd(args) == "-d" ->
            "Identifier=com.apple.container.cli\nTeamIdentifier=UPBK2H6LZM\n"

          Path.basename(binary) == "codesign" ->
            ""

          Enum.take(args, 2) == ["image", "inspect"] ->
            Jason.encode!([%{"configuration" => %{"name" => List.last(args)}}])

          true ->
            ""
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end
  end

  defp option(args, name) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^name, value] -> value
      _pair -> nil
    end)
  end

  defp label(args, name) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      ["--label", value] ->
        case String.split(value, "=", parts: 2) do
          [^name, result] -> result
          _other -> nil
        end

      _pair ->
        nil
    end)
  end

  defp contiguous?(values, pair),
    do: Enum.chunk_every(values, length(pair), 1, :discard) |> Enum.member?(pair)

  defp temp_dir do
    path = Path.join(System.tmp_dir!(), "twelvgaige-apple-#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
