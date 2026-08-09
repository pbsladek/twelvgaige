defmodule Twelvgaige.Egress.BoundaryTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Egress.{Boundary, Lease}

  test "provisions an attested dual-homed proxy and keeps the worker on the internal network" do
    root = temp_dir()
    digest = "sha256:" <> String.duplicate("a", 64)
    lease = lease()
    parent = self()

    runner = fn binary, args, _opts ->
      send(parent, {:command, Path.basename(binary), args})

      output =
        case args do
          ["image", "inspect", _identity] ->
            Jason.encode!([%{"Digest" => digest}])

          ["network", "create" | network_args] ->
            network = List.last(network_args)
            Process.put(:boundary_network, network)
            network

          ["run" | run_args] ->
            sidecar = option(run_args, "--name")
            Process.put(:boundary_sidecar, sidecar)
            sidecar

          ["inspect", _sidecar, "--format", "json"] ->
            Jason.encode!([
              %{
                "ImageDigest" => digest,
                "Config" => %{
                  "User" => "65532:65532",
                  "Labels" => %{
                    "io.twelvgaige.managed" => "true",
                    "io.twelvgaige.role" => "egress-proxy"
                  }
                },
                "HostConfig" => %{
                  "ReadonlyRootfs" => true,
                  "CapDrop" => ["CAP_ALL"],
                  "SecurityOpt" => ["no-new-privileges"],
                  "Memory" => 67_108_864,
                  "PidsLimit" => 32
                },
                "State" => %{"Status" => "running"},
                "NetworkSettings" => %{
                  "Networks" => %{
                    Process.get(:boundary_network) => %{"IPAddress" => "10.89.0.2"},
                    "podman" => %{"IPAddress" => "10.88.0.2"}
                  }
                },
                "Mounts" => [
                  %{
                    "Destination" => "/run/twelvgaige",
                    "Source" => root,
                    "RW" => false,
                    "Type" => "bind"
                  }
                ]
              }
            ])

          [action | _rest] when action in ["rm", "logs"] ->
            if action == "logs", do: ~s({"event":"connection_authorized"}\n), else: ""

          ["network", "rm" | _rest] ->
            ""
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end

    assert {:ok, boundary} =
             Boundary.provision(:podman, lease,
               runtime_root: root,
               image_reference: "localhost/twelvgaige/egress-proxy",
               image_digest: digest,
               command_runner: runner
             )

    assert boundary.sidecar_address == "10.89.0.2"
    refute inspect(boundary) =~ lease.access_token

    worker_opts = Boundary.worker_options(boundary)
    assert worker_opts[:broker_network] == boundary.network
    assert worker_opts[:proxy_environment]["HTTPS_PROXY"] =~ "10.89.0.2:8080"
    assert worker_opts[:proxy_environment]["HTTPS_PROXY"] =~ lease.access_token

    assert_receive {:command, "podman", ["network", "create" | network_args]}
    assert "--internal" in network_args
    assert "--disable-dns" in network_args

    assert_receive {:command, "podman", ["run" | sidecar_args]}
    assert contiguous?(sidecar_args, ["--cap-drop", "ALL"])
    assert contiguous?(sidecar_args, ["--security-opt", "no-new-privileges"])
    assert contiguous?(sidecar_args, ["--network", boundary.network])
    assert contiguous?(sidecar_args, ["--network", "podman"])

    config_path = Path.join(boundary.config_dir, "egress.json")
    assert File.read!(config_path) =~ lease.access_token

    assert :ok = Boundary.destroy(boundary, command_runner: runner)
    refute File.exists?(boundary.config_dir)
  end

  test "rejects missing image identity and expired capabilities before runtime mutation" do
    root = temp_dir()
    expired = %{lease() | expires_at: DateTime.add(DateTime.utc_now(), -1)}

    assert {:error, :egress_lease_expired} =
             Boundary.provision(:podman, expired,
               runtime_root: root,
               image_reference: "localhost/twelvgaige/egress-proxy",
               image_digest: "sha256:" <> String.duplicate("a", 64)
             )

    assert {:error, :egress_proxy_image_identity_required} =
             Boundary.provision(:podman, lease(), runtime_root: root)
  end

  test "puts Apple's outbound network before the worker-facing network" do
    root = temp_dir()
    digest = "sha256:" <> String.duplicate("b", 64)
    lease = lease()
    parent = self()

    runner = fn _binary, args, _opts ->
      send(parent, {:apple_command, args})

      output =
        case args do
          ["image", "inspect", identity] ->
            Jason.encode!([%{"configuration" => %{"name" => identity}}])

          ["network", "create" | network_args] ->
            network = List.last(network_args)
            Process.put(:apple_boundary_network, network)
            network

          ["run" | run_args] ->
            sidecar = option(run_args, "--name")
            Process.put(:apple_boundary_sidecar, sidecar)
            sidecar

          ["inspect", _sidecar] ->
            Jason.encode!([
              %{
                "configuration" => %{
                  "image" => %{
                    "reference" => "localhost/twelvgaige/egress-proxy@#{digest}"
                  },
                  "initProcess" => %{
                    "user" => %{"raw" => %{"userString" => "65532:65532"}},
                    "rlimits" => [%{"limit" => "RLIMIT_NPROC", "hard" => 32}]
                  },
                  "readOnly" => true,
                  "capDrop" => ["ALL"],
                  "labels" => %{
                    "io.twelvgaige.managed" => "true",
                    "io.twelvgaige.role" => "egress-proxy"
                  },
                  "mounts" => [
                    %{
                      "destination" => "/run/twelvgaige",
                      "options" => ["readonly"]
                    }
                  ],
                  "resources" => %{"memoryInBytes" => 209_715_200}
                },
                "status" => %{
                  "state" => "running",
                  "networks" => [
                    %{"network" => "default", "ipv4Address" => "192.168.64.2/24"},
                    %{
                      "network" => Process.get(:apple_boundary_network),
                      "ipv4Address" => "192.168.128.2/24"
                    }
                  ]
                }
              }
            ])

          ["delete", "--force", _sidecar] ->
            ""

          ["network", "delete", _network] ->
            ""
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end

    assert {:ok, boundary} =
             Boundary.provision(:apple_container, lease,
               runtime_root: root,
               image_reference: "localhost/twelvgaige/egress-proxy",
               image_digest: digest,
               command_runner: runner,
               verify_runtime?: false
             )

    assert_receive {:apple_command, ["run" | sidecar_args]}

    network_attachments =
      sidecar_args
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.flat_map(fn
        ["--network", network] -> [network]
        _pair -> []
      end)

    assert network_attachments == ["default", boundary.network]
    assert :ok = Boundary.destroy(boundary, command_runner: runner)
  end

  defp lease do
    %Lease{
      id: "proxy_test",
      session_id: "session_test",
      allowed_hosts: ["api.example.com"],
      allowed_ports: [443],
      expires_at: DateTime.add(DateTime.utc_now(), 300),
      access_token: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      max_connections: 2
    }
  end

  defp option(args, name) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^name, value] -> value
      _pair -> nil
    end)
  end

  defp contiguous?(args, expected) do
    args
    |> Enum.chunk_every(length(expected), 1, :discard)
    |> Enum.any?(&(&1 == expected))
  end

  defp temp_dir do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-boundary-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
