defmodule Twelvgaige.Sandbox.OnboardingTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Sandbox.Onboarding

  test "Podman setup prepares private data and runs the idempotent machine, image, and health flow" do
    source_root = source_root()
    data_root = Path.join(source_root, "data")
    owner_uid = File.stat!(source_root).uid
    parent = self()

    runner = fn binary, args, opts ->
      send(parent, {:command, Path.basename(binary), args, opts[:env]})
      {:ok, %{status: 0, stdout: "ok", stderr: "", duration_ms: 1}}
    end

    health = fn backend, opts ->
      send(parent, {:health, backend, opts})
      {:ok, %{available: true, backend: backend}}
    end

    assert {:ok, report} =
             Onboarding.setup(:podman,
               source_root: source_root,
               data_root: data_root,
               os_type: {:unix, :darwin},
               identity_fun: fn [] -> {:ok, %{uid: owner_uid, username: "operator"}} end,
               command_runner: runner,
               health_fun: health
             )

    assert report.status == :ready
    assert report.backend == :podman
    assert Enum.map(report.steps, & &1.name) == [:podman_machine, :worker_image_built]
    assert File.stat!(data_root).mode |> Bitwise.band(0o077) == 0
    assert File.dir?(Path.join(data_root, "workspaces"))
    assert File.dir?(Path.join(data_root, "cache"))

    assert_receive {:command, "podman_machine.sh", ["create"], machine_env}
    assert {"TWELVGAIGE_PODMAN_CONFIRM", "1"} in machine_env
    assert_receive {:command, "podman_worker.sh", ["build"], _worker_env}
    assert_receive {:health, :podman, health_opts}
    assert health_opts[:machine_allowed_mounts] == [Path.expand(data_root)]
  end

  test "Apple setup explicitly starts the service and imports the pinned OCI worker" do
    source_root = source_root()
    data_root = Path.join(source_root, "data")
    owner_uid = File.stat!(source_root).uid
    parent = self()

    runner = fn binary, args, _opts ->
      send(parent, {:command, Path.basename(binary), args})
      {:ok, %{status: 0, stdout: "ok", stderr: "", duration_ms: 1}}
    end

    assert {:ok, report} =
             Onboarding.setup(:apple_container,
               source_root: source_root,
               data_root: data_root,
               os_type: {:unix, :darwin},
               identity_fun: fn [] -> {:ok, %{uid: owner_uid, username: "operator"}} end,
               command_runner: runner,
               apple_service_fun: fn _opts ->
                 send(parent, {:command, "container", ["system", "start"]})
                 {:ok, %{stdout: "started"}}
               end,
               apple_image_load_fun: fn archive, _opts ->
                 send(parent, {:command, "container", ["image", "load", "--input", archive]})
                 {:ok, %{stdout: "loaded"}}
               end,
               health_fun: fn :apple_container, _opts ->
                 {:ok, %{available: true, backend: :apple_container}}
               end
             )

    assert report.backend == :apple_container

    assert Enum.map(report.steps, & &1.name) == [
             :apple_container_service,
             :podman_machine,
             :worker_image_built,
             :worker_image_exported,
             :worker_image_imported
           ]

    assert_receive {:command, "container", ["system", "start"]}
    assert_receive {:command, "podman_worker.sh", ["export-oci"]}
    assert_receive {:command, "container", ["image", "load", "--input", archive]}
    assert String.ends_with?(archive, "artifacts/qualification/podman-worker/worker.oci.tar")
  end

  test "check is read-only and auto remains Podman-authoritative" do
    assert {:ok, %{backend: :podman, status: :ready}} =
             Onboarding.check(:auto,
               data_root: System.tmp_dir!(),
               os_type: {:unix, :darwin},
               health_fun: fn :podman, _opts -> {:ok, %{available: true}} end,
               command_runner: fn _binary, _args, _opts ->
                 flunk("check must not execute setup")
               end
             )
  end

  defp source_root do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige-onboarding-#{System.unique_integer([:positive])}")

    scripts = Path.join(root, "scripts")
    File.mkdir_p!(scripts)
    File.write!(Path.join(scripts, "podman_machine.sh"), "#!/bin/sh\n")
    File.write!(Path.join(scripts, "podman_worker.sh"), "#!/bin/sh\n")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
