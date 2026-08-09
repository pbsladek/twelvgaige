defmodule Twelvgaige.Egress.Boundary do
  @moduledoc """
  Per-session broker-only data-plane boundary.

  The worker receives only an ephemeral internal network and an authenticated
  proxy URL. A separate capability-free sidecar is dual-homed to that network
  and the runtime's outbound network. The sidecar independently validates the
  capability, destination, port, DNS result, expiry, and connection limit.
  """

  alias Twelvgaige.Egress.Lease
  alias Twelvgaige.Sandbox.Backend.AppleContainer
  alias Twelvgaige.Tool.CommandRunner

  @config_destination "/run/twelvgaige/egress.json"
  @config_mount_destination "/run/twelvgaige"
  @proxy_port 8080
  @managed_label "io.twelvgaige.managed"
  @enforce_keys [
    :id,
    :backend,
    :lease_id,
    :network,
    :sidecar,
    :sidecar_address,
    :config_dir,
    :image_reference,
    :image_digest,
    :access_token
  ]
  defstruct @enforce_keys ++ [:created_at, schema_version: 1]

  @type t :: %__MODULE__{}

  @doc "Creates and attests a dedicated internal network and egress sidecar."
  @spec provision(:podman | :apple_container, Lease.t(), keyword()) ::
          {:ok, t()} | {:error, term()}
  def provision(backend, %Lease{} = lease, opts)
      when backend in [:podman, :apple_container] do
    with :ok <- validate_lease(lease),
         {:ok, image_reference, image_digest} <- resolve_image_identity(opts),
         :ok <- verify_runtime(backend, opts),
         boundary <- boundary(backend, lease, image_reference, image_digest, opts) do
      provision_boundary(boundary, lease, opts)
    end
  end

  def provision(_backend, _lease, _opts), do: {:error, :egress_boundary_invalid}

  defp provision_boundary(boundary, lease, opts) do
    with :ok <- write_config(boundary, lease),
         :ok <- verify_image(boundary, opts),
         {:ok, _output} <- command(boundary.backend, network_create_args(boundary), opts),
         {:ok, _output} <- command(boundary.backend, sidecar_run_args(boundary), opts),
         {:ok, observed} <- inspect_sidecar(boundary, opts),
         :ok <- attest(boundary, observed) do
      {:ok, %{boundary | sidecar_address: observed.internal_address}}
    else
      {:error, reason} ->
        _ = destroy(boundary, Keyword.put(opts, :verify_runtime?, false))
        {:error, reason}
    end
  end

  @doc "Returns the secret-bearing worker launch options without persisting them in a manifest."
  def worker_options(%__MODULE__{} = boundary) do
    encoded = URI.encode_www_form(boundary.access_token)
    proxy = "http://twelvgaige:#{encoded}@#{boundary.sidecar_address}:#{@proxy_port}"

    [
      broker_network: boundary.network,
      proxy_environment: %{
        "HTTP_PROXY" => proxy,
        "HTTPS_PROXY" => proxy,
        "NO_PROXY" => "127.0.0.1,localhost"
      }
    ]
  end

  @doc "Destroys the sidecar and internal network before erasing the raw capability."
  def revoke(%__MODULE__{} = boundary, opts \\ []) do
    boundary.backend
    |> command(sidecar_delete_args(boundary), opts)
    |> idempotent_command()
  end

  def destroy(%__MODULE__{} = boundary, opts \\ []) do
    sidecar_result = revoke(boundary, opts)

    network_result =
      boundary.backend
      |> command(network_delete_args(boundary), opts)
      |> idempotent_command()

    config_result =
      case File.rm_rf(boundary.config_dir) do
        {:ok, _paths} -> :ok
        {:error, reason, path} -> {:error, {:egress_config_cleanup_failed, path, reason}}
      end

    case {sidecar_result, network_result, config_result} do
      {:ok, :ok, :ok} -> :ok
      results -> {:error, {:egress_boundary_cleanup_failed, results}}
    end
  end

  @doc "Reads sidecar audit records for qualification or durable ingestion."
  def logs(%__MODULE__{} = boundary, opts \\ []) do
    case command(boundary.backend, logs_args(boundary), opts) do
      {:ok, output} -> {:ok, output}
      {:error, reason} -> {:error, reason}
    end
  end

  defp boundary(backend, lease, image_reference, image_digest, opts) do
    suffix = boundary_suffix(lease.id)
    id = "egress_" <> suffix
    root = opts |> Keyword.fetch!(:runtime_root) |> Path.expand()
    config_dir = Path.join(root, id)

    %__MODULE__{
      id: id,
      backend: backend,
      lease_id: lease.id,
      network: "twelvgaige-egress-" <> suffix,
      sidecar: "twelvgaige-egress-proxy-" <> suffix,
      sidecar_address: nil,
      config_dir: config_dir,
      image_reference: image_reference,
      image_digest: image_digest,
      access_token: lease.access_token,
      created_at: DateTime.utc_now()
    }
  end

  defp boundary_suffix(lease_id) do
    :crypto.hash(:sha256, lease_id)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 20)
  end

  defp write_config(boundary, lease) do
    config_path = config_path(boundary)

    config = %{
      listen: "0.0.0.0:#{@proxy_port}",
      token: lease.access_token,
      allowed_hosts: lease.allowed_hosts,
      allowed_ports: lease.allowed_ports,
      expires_at: DateTime.to_iso8601(lease.expires_at),
      max_connections: lease.max_connections,
      max_header_bytes: 32_768,
      header_timeout_ms: 10_000,
      connect_timeout_ms: 10_000,
      idle_timeout_ms: 300_000
    }

    with :ok <- File.mkdir_p(boundary.config_dir),
         :ok <- File.chmod(boundary.config_dir, 0o755),
         :ok <- File.write(config_path, Jason.encode!(config)),
         :ok <- File.chmod(config_path, 0o444) do
      :ok
    else
      {:error, reason} -> {:error, {:egress_config_write_failed, reason}}
    end
  end

  defp validate_lease(lease) do
    cond do
      not is_binary(lease.id) or lease.id == "" ->
        {:error, :egress_lease_id_required}

      not is_binary(lease.access_token) or byte_size(lease.access_token) < 32 ->
        {:error, :egress_access_token_required}

      lease.allowed_hosts == [] ->
        {:error, :egress_hosts_required}

      lease.allowed_ports == [] ->
        {:error, :egress_ports_required}

      not match?(%DateTime{}, lease.expires_at) ->
        {:error, :egress_expiry_required}

      DateTime.compare(lease.expires_at, Twelvgaige.Clock.utc_now()) != :gt ->
        {:error, :egress_lease_expired}

      true ->
        :ok
    end
  end

  defp resolve_image_identity(opts) do
    reference = Keyword.get(opts, :image_reference)
    digest = Keyword.get(opts, :image_digest)

    if is_binary(reference) and reference != "" and
         match?("sha256:" <> <<_::binary-size(64)>>, digest) do
      {:ok, reference, digest}
    else
      {:error, :egress_proxy_image_identity_required}
    end
  end

  defp verify_runtime(:podman, _opts), do: :ok

  defp verify_runtime(:apple_container, opts) do
    if Keyword.get(opts, :verify_runtime?, true) do
      case AppleContainer.probe(opts) do
        {:ok, _probe} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp verify_image(boundary, opts) do
    case command(boundary.backend, image_inspect_args(boundary), opts) do
      {:ok, output} -> verify_image_output(boundary, output)
      {:error, reason} -> {:error, reason}
    end
  end

  defp verify_image_output(%{backend: :podman} = boundary, output) do
    with {:ok, [image | _]} <- Jason.decode(output),
         observed when is_binary(observed) <- image["Digest"] || image["digest"],
         true <- observed == boundary.image_digest do
      :ok
    else
      _other -> {:error, :egress_proxy_image_digest_mismatch}
    end
  end

  defp verify_image_output(%{backend: :apple_container} = boundary, output) do
    with {:ok, decoded} <- Jason.decode(output),
         image when is_map(image) <- List.wrap(decoded) |> List.first(),
         reference when is_binary(reference) <- get_in(image, ["configuration", "name"]),
         true <- String.ends_with?(reference, "@" <> boundary.image_digest) do
      :ok
    else
      _other -> {:error, :egress_proxy_image_digest_mismatch}
    end
  end

  defp inspect_sidecar(boundary, opts) do
    with {:ok, output} <- command(boundary.backend, inspect_args(boundary), opts),
         {:ok, decoded} <- Jason.decode(output),
         record when is_map(record) <- List.wrap(decoded) |> List.first() do
      observed(boundary, record)
    else
      _other -> {:error, :egress_sidecar_inspect_invalid}
    end
  end

  defp observed(%{backend: :podman} = boundary, record) do
    config = record["Config"] || %{}
    host = record["HostConfig"] || %{}
    networks = get_in(record, ["NetworkSettings", "Networks"]) || %{}

    with %{} = internal <- networks[boundary.network],
         address when is_binary(address) and address != "" <- internal["IPAddress"] do
      {:ok,
       %{
         state: get_in(record, ["State", "Status"]),
         image_digest: record["ImageDigest"],
         uid_gid: config["User"],
         read_only: host["ReadonlyRootfs"],
         cap_drop: host["CapDrop"] || [],
         create_command: config["CreateCommand"] || [],
         security_options: host["SecurityOpt"] || [],
         networks: networks |> Map.keys() |> Enum.sort(),
         internal_address: address,
         mounts: record["Mounts"] || [],
         labels: config["Labels"] || %{},
         memory: host["Memory"],
         pids: host["PidsLimit"]
       }}
    else
      _other -> {:error, :egress_sidecar_internal_address_missing}
    end
  end

  defp observed(%{backend: :apple_container} = boundary, record) do
    config = record["configuration"] || %{}
    status = record["status"] || %{}
    networks = status["networks"] || []

    with %{} = internal <- Enum.find(networks, &(&1["network"] == boundary.network)),
         cidr when is_binary(cidr) <- internal["ipv4Address"],
         [address | _] <- String.split(cidr, "/", parts: 2) do
      {:ok,
       %{
         state: status["state"],
         image_digest: digest_from_reference(get_in(config, ["image", "reference"])),
         uid_gid: get_in(config, ["initProcess", "user", "raw", "userString"]),
         read_only: config["readOnly"],
         cap_drop: config["capDrop"] || [],
         create_command: [],
         security_options: [],
         networks: networks |> Enum.map(& &1["network"]) |> Enum.sort(),
         internal_address: address,
         mounts: config["mounts"] || [],
         labels: config["labels"] || %{},
         memory: get_in(config, ["resources", "memoryInBytes"]),
         pids: apple_process_limit(get_in(config, ["initProcess", "rlimits"]) || [])
       }}
    else
      _other -> {:error, :egress_sidecar_internal_address_missing}
    end
  end

  defp attest(boundary, observed) do
    expected_networks =
      case boundary.backend do
        :podman -> [boundary.network, "podman"]
        :apple_container -> [boundary.network, "default"]
      end

    expected = %{
      state: "running",
      image_digest: boundary.image_digest,
      uid_gid: "65532:65532",
      read_only: true,
      cap_drop: ["ALL"],
      networks: Enum.sort(expected_networks),
      config_mount: :read_only,
      managed: "true",
      role: "egress-proxy"
    }

    actual = %{
      state: observed.state,
      image_digest: observed.image_digest,
      uid_gid: observed.uid_gid,
      read_only: observed.read_only,
      cap_drop: normalize_capabilities(observed.cap_drop, observed.create_command),
      networks: observed.networks,
      config_mount: config_mount_mode(observed.mounts),
      managed: observed.labels[@managed_label],
      role: observed.labels["io.twelvgaige.role"]
    }

    drift = for {key, value} <- expected, actual[key] != value, do: key

    cond do
      drift != [] ->
        {:error, {:egress_sidecar_attestation_failed, Enum.sort(drift), actual}}

      observed.memory not in [67_108_864, 209_715_200] ->
        {:error, {:egress_sidecar_attestation_failed, [:memory]}}

      observed.pids != 32 ->
        {:error, {:egress_sidecar_attestation_failed, [:pids]}}

      boundary.backend == :podman and "no-new-privileges" not in observed.security_options ->
        {:error, {:egress_sidecar_attestation_failed, [:security_options]}}

      true ->
        :ok
    end
  end

  defp config_mount_mode(mounts) do
    case Enum.find(mounts, fn mount ->
           (mount["Destination"] || mount["destination"]) == @config_mount_destination
         end) do
      nil ->
        :missing

      mount ->
        writable = mount["RW"]
        options = mount["options"] || []

        if writable == false or Enum.any?(options, &(&1 in ["ro", "readonly"])),
          do: :read_only,
          else: :read_write
    end
  end

  defp normalize_capabilities(values, create_command) do
    explicit_drop_all? =
      create_command
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.any?(fn
        ["--cap-drop", value] -> String.upcase(value) == "ALL"
        _pair -> false
      end)

    if explicit_drop_all? or
         Enum.any?(List.wrap(values), &(String.upcase(to_string(&1)) in ["ALL", "CAP_ALL"])),
       do: ["ALL"],
       else: []
  end

  defp network_create_args(%{backend: :podman} = boundary) do
    [
      "network",
      "create",
      "--internal",
      "--disable-dns",
      "--label",
      "#{@managed_label}=true",
      "--label",
      "io.twelvgaige.role=egress-network",
      "--label",
      "io.twelvgaige.lease=#{boundary.lease_id}",
      boundary.network
    ]
  end

  defp network_create_args(%{backend: :apple_container} = boundary) do
    [
      "network",
      "create",
      "--internal",
      "--label",
      "#{@managed_label}=true",
      "--label",
      "io.twelvgaige.role=egress-network",
      "--label",
      "io.twelvgaige.lease=#{boundary.lease_id}",
      boundary.network
    ]
  end

  defp sidecar_run_args(%{backend: :podman} = boundary) do
    [
      "run",
      "--detach",
      "--name",
      boundary.sidecar,
      "--label",
      "#{@managed_label}=true",
      "--label",
      "io.twelvgaige.role=egress-proxy",
      "--label",
      "io.twelvgaige.lease=#{boundary.lease_id}",
      "--user",
      "65532:65532",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--pids-limit",
      "32",
      "--cpus",
      "0.25",
      "--memory",
      "64m",
      "--network",
      boundary.network,
      "--network",
      "podman",
      "--mount",
      "type=bind,src=#{boundary.config_dir},dst=#{@config_mount_destination},ro",
      image_ref(boundary),
      "--config",
      @config_destination
    ]
  end

  defp sidecar_run_args(%{backend: :apple_container} = boundary) do
    [
      "run",
      "--detach",
      "--name",
      boundary.sidecar,
      "--label",
      "#{@managed_label}=true",
      "--label",
      "io.twelvgaige.role=egress-proxy",
      "--label",
      "io.twelvgaige.lease=#{boundary.lease_id}",
      "--user",
      "65532:65532",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--ulimit",
      "nproc=32:32",
      "--cpus",
      "1",
      "--memory",
      "200M",
      # Apple assigns the default route only to the first attachment. Its vmnet
      # implementation also misroutes peer traffic when a dual-homed VM puts a
      # host-only network first (observed on container 1.2.0 / macOS 26).
      # Keep outbound first and the worker-facing host-only network second.
      "--network",
      "default",
      "--network",
      boundary.network,
      "--mount",
      "type=bind,source=#{boundary.config_dir},target=#{@config_mount_destination},readonly",
      image_ref(boundary),
      "--config",
      @config_destination
    ]
  end

  defp image_inspect_args(boundary), do: ["image", "inspect", image_ref(boundary)]

  defp inspect_args(%{backend: :podman, sidecar: sidecar}),
    do: ["inspect", sidecar, "--format", "json"]

  defp inspect_args(%{backend: :apple_container, sidecar: sidecar}), do: ["inspect", sidecar]

  defp sidecar_delete_args(%{backend: :podman, sidecar: sidecar}),
    do: ["rm", "--force", sidecar]

  defp sidecar_delete_args(%{backend: :apple_container, sidecar: sidecar}),
    do: ["delete", "--force", sidecar]

  defp network_delete_args(%{backend: :podman, network: network}),
    do: ["network", "rm", "--force", network]

  defp network_delete_args(%{backend: :apple_container, network: network}),
    do: ["network", "delete", network]

  defp logs_args(%{backend: :podman, sidecar: sidecar}), do: ["logs", sidecar]
  defp logs_args(%{backend: :apple_container, sidecar: sidecar}), do: ["logs", sidecar]

  defp image_ref(boundary), do: boundary.image_reference <> "@" <> boundary.image_digest
  defp config_path(boundary), do: Path.join(boundary.config_dir, "egress.json")

  defp command(backend, args, opts) do
    runner = Keyword.get(opts, :command_runner, &CommandRunner.run/3)
    binary = command_binary(backend, opts)

    case runner.(binary, args,
           timeout_ms: Keyword.get(opts, :timeout_ms, 60_000),
           require_absolute_binary?: Keyword.get(opts, :require_absolute_binary?, false),
           scrub_env?: true,
           posix_port_runner?: true
         ) do
      {:ok, %{status: 0, stdout: stdout}} ->
        {:ok, stdout}

      {:ok, %{status: status} = result} ->
        {:error, %{status: status, output: result.stdout <> result.stderr}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp command_binary(:podman, opts), do: Keyword.get(opts, :podman_binary, "podman")

  defp command_binary(:apple_container, opts),
    do:
      Keyword.get(
        opts,
        :container_binary_path,
        System.find_executable("container") || "container"
      )

  defp idempotent_command({:ok, _output}), do: :ok

  defp idempotent_command({:error, %{output: output}}) when is_binary(output) do
    if Regex.match?(~r/(not found|does not exist|no such|not running|already stopped)/i, output),
      do: :ok,
      else: {:error, output}
  end

  defp idempotent_command({:error, reason}), do: {:error, reason}

  defp digest_from_reference(reference) when is_binary(reference) do
    case String.split(reference, "@", parts: 2) do
      [_name, digest] -> digest
      _other -> reference
    end
  end

  defp digest_from_reference(_reference), do: nil

  defp apple_process_limit(limits) do
    Enum.find_value(limits, fn limit ->
      if limit["limit"] == "RLIMIT_NPROC", do: limit["hard"], else: nil
    end)
  end
end

defimpl Inspect, for: Twelvgaige.Egress.Boundary do
  import Inspect.Algebra

  def inspect(boundary, _opts) do
    concat([
      "#Twelvgaige.Egress.Boundary<id=",
      boundary.id,
      " backend=",
      to_string(boundary.backend),
      " token=[REDACTED]>"
    ])
  end
end
