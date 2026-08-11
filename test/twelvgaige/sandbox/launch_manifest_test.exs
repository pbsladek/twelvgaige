defmodule Twelvgaige.Sandbox.LaunchManifestTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Sandbox.LaunchManifest

  test "canonicalizes an enforced manifest and attests observed state" do
    root = temp_dir()
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    assert {:ok, manifest} = LaunchManifest.new(attrs(workspace), allowed_roots: [root])
    assert byte_size(manifest.manifest_digest) == 64
    assert manifest.mounts == [%{source: workspace, destination: "/workspace", mode: :read_write}]

    observed = %{
      image_digest: manifest.image_digest,
      mounts: manifest.mounts,
      uid: manifest.uid,
      gid: manifest.gid,
      rootfs_mode: :read_only,
      dropped_capabilities: ["ALL"],
      security_options: ["no-new-privileges"],
      network_mode: :none,
      limits: manifest.limits,
      labels: %{}
    }

    assert :ok = LaunchManifest.attest(manifest, observed)

    assert {:error, {:sandbox_attestation_failed, [:uid]}} =
             LaunchManifest.attest(manifest, %{observed | uid: 0})
  end

  test "rejects traversal, broad mounts, secret env, and implicit unrestricted network" do
    root = temp_dir()
    outside = temp_dir()

    assert {:error, {:mount_denied, ^outside, :outside_owned_roots}} =
             LaunchManifest.new(attrs(outside), allowed_roots: [root])

    assert {:error, :unrestricted_network_requires_explicit_flag} =
             LaunchManifest.new(%{attrs(root) | network_mode: :unrestricted},
               allowed_roots: [root]
             )

    assert {:error, :secret_environment_name_denied} =
             LaunchManifest.new(Map.put(attrs(root), :environment_names, ["OPENAI_API_KEY"]),
               allowed_roots: [root]
             )
  end

  test "admits a private copied Codex home without admitting ambient account paths" do
    root = temp_dir()
    workspace = Path.join(root, "workspace")
    codex_home = Path.join(root, "credential-material/session")
    File.mkdir_p!(workspace)
    File.mkdir_p!(codex_home)

    spec =
      attrs(workspace)
      |> Map.put(:workspace_transport, :copy_snapshot)
      |> Map.put(:environment_names, ["CODEX_HOME"])
      |> Map.put(:mounts, [
        %{source: workspace, destination: "/workspace", mode: :read_write},
        %{source: codex_home, destination: "/run/codex-home", mode: :read_write}
      ])

    assert {:ok, manifest} = LaunchManifest.new(spec, allowed_roots: [root])
    assert Enum.any?(manifest.mounts, &(&1.destination == "/run/codex-home"))
    assert manifest.environment_names == ["CODEX_HOME"]
  end

  defp attrs(workspace) do
    %{
      backend: :podman,
      backend_version: "5.5",
      profile: :coding_restricted,
      image_reference: "registry.example/twelvgaige/worker",
      image_digest: "sha256:" <> String.duplicate("a", 64),
      workspace_transport: :bind_worktree,
      mounts: [%{source: workspace, destination: "/workspace", mode: :read_write}],
      network_mode: :none,
      allowed_destinations: [],
      limits: %{cpu: 2, memory_bytes: 1_073_741_824, pids: 256},
      deadline: DateTime.add(DateTime.utc_now(), 3_600),
      policy_revision: "policy-1",
      created_at: DateTime.utc_now()
    }
  end

  defp temp_dir do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-sandbox-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
