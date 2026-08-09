defmodule Twelvgaige.Sandbox.BackendConformanceTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Sandbox.Backend.{AppleContainer, Podman}
  alias Twelvgaige.Sandbox.LaunchManifest

  for backend <- [Podman, AppleContainer] do
    @backend backend

    test "#{inspect(backend)} satisfies the common create, attest, recover, cancel, and cleanup contract" do
      root = temp_dir()
      digest = "sha256:" <> String.duplicate("d", 64)
      backend = @backend

      assert {:ok, manifest} =
               backend.prepare(spec(root, digest),
                 allowed_roots: [root],
                 backend_version: "qualified"
               )

      observed = fn manifest -> evidence(manifest) end

      assert {:ok, resource_id, %{manifest: created, observed: actual}} =
               backend.create(manifest,
                 command_runner: success_runner(digest),
                 observed_factory: observed,
                 command: ["sleep", "300"]
               )

      assert created.resource_id == resource_id
      assert :ok = LaunchManifest.attest(created, actual)
      assert created.uid != 0 and created.gid != 0
      assert created.rootfs_mode == :read_only
      assert created.dropped_capabilities == ["ALL"]
      assert created.network_mode == :none
      assert Enum.all?(created.mounts, &(&1.destination in ["/workspace", "/artifacts"]))
      refute Enum.any?(created.mounts, &String.contains?(&1.source, "container-apiserver"))

      assert {:ok, :resume, _evidence} =
               backend.reconcile(%{resource_id: resource_id, manifest: created},
                 observed: actual
               )

      drifted = %{actual | network_mode: :unrestricted}

      assert {:ok, :quarantine, ^drifted} =
               backend.reconcile(%{resource_id: resource_id, manifest: created},
                 observed: drifted
               )

      assert {:ok, %{status: :running}} =
               backend.start(resource_id, command_runner: success_runner(digest))

      assert :ok = backend.stop(resource_id, command_runner: success_runner(digest))
      assert :ok = backend.destroy(resource_id, command_runner: success_runner(digest))
    end
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
      policy_revision: "conformance-1",
      created_at: DateTime.utc_now()
    }
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

          hd(args) == "start" ->
            List.last(args)

          true ->
            ""
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end
  end

  defp temp_dir do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-conformance-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
