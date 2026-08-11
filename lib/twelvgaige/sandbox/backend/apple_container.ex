defmodule Twelvgaige.Sandbox.Backend.AppleContainer do
  @moduledoc """
  Apple `container` backend with one lightweight VM per delegated session.

  The signed CLI remains the only host control surface used by this module.
  Guests receive neither the container API service nor host credential stores.
  """

  @behaviour Twelvgaige.Sandbox.Backend

  import Kernel, except: [inspect: 2]

  alias Twelvgaige.Sandbox.LaunchManifest
  alias Twelvgaige.Tool.CommandRunner

  @supported_version "1.2.0"
  @codesign_identifier "com.apple.container.cli"
  @codesign_team "UPBK2H6LZM"
  @mib 1_048_576
  @gib 1_073_741_824
  @default_workspace_volume_bytes 10 * @gib
  @managed_label "io.twelvgaige.managed"
  @proxy_environment_names ~w(HTTP_PROXY HTTPS_PROXY NO_PROXY)

  @impl true
  def probe(opts) do
    with {:ok, signature} <- verify_cli_signature(opts),
         {:ok, version_output} <- command(["--version"], opts),
         {:ok, version} <- parse_version(version_output),
         :ok <- supported_version(version, opts),
         {:ok, status_output} <- command(["system", "status"], opts),
         :ok <- running_service(status_output),
         {:ok, macos_output} <- host_command("sw_vers", ["-productVersion"], opts),
         :ok <- supported_macos(String.trim(macos_output)),
         {:ok, architecture_output} <- host_command("uname", ["-m"], opts),
         :ok <- apple_silicon(String.trim(architecture_output)) do
      {:ok,
       %{
         available: true,
         backend: :apple_container,
         version: version,
         pinned_version: @supported_version,
         architecture: String.trim(architecture_output),
         macos_version: String.trim(macos_output),
         service_status: :running,
         capabilities: capabilities(),
         code_signature: signature,
         documentation_release: "https://github.com/apple/container/tree/#{@supported_version}"
       }}
    else
      {:error, reason} -> {:error, {:apple_container_unavailable, reason}}
    end
  end

  @doc "Starts the signed Apple container service during explicit onboarding."
  def system_start(opts \\ []), do: command(["system", "start"], opts)

  @doc "Leaves an already-running signed service alone, otherwise starts it explicitly."
  def ensure_system_started(opts \\ []) do
    case probe(opts) do
      {:ok, _health} ->
        {:ok, "already running"}

      {:error, {:apple_container_unavailable, :apple_container_service_not_running}} ->
        system_start(opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Loads an OCI archive through the signed Apple container CLI."
  def load_image(archive, opts \\ []) when is_binary(archive),
    do: command(["image", "load", "--input", Path.expand(archive)], opts)

  @impl true
  def prepare(spec, opts) do
    with :ok <- exact_memory_limit(value(spec, :limits)) do
      attrs =
        spec
        |> Map.put(:backend, :apple_container)
        |> Map.put_new(:backend_version, Keyword.get(opts, :backend_version, @supported_version))
        |> Map.put(:machine_id, nil)
        |> Map.put(:security_options, [])
        |> Map.update(:capabilities, capabilities(), &Map.merge(capabilities(), &1))

      LaunchManifest.new(attrs,
        allowed_roots: Keyword.fetch!(opts, :allowed_roots),
        allow_unrestricted?: Keyword.get(opts, :allow_unrestricted?, false)
      )
    end
  end

  @impl true
  def create(%LaunchManifest{} = manifest, opts) do
    resource_id = manifest.resource_id || Twelvgaige.ID.new(:sandbox)
    manifest = LaunchManifest.bind_resource(manifest, resource_id, machine_id: resource_id)

    with :ok <- validate_runtime_environment(manifest, opts),
         {:ok, _signature} <- verify_cli_signature(opts),
         :ok <- verify_image(manifest, opts) do
      create_attested(resource_id, manifest, opts)
    end
  end

  defp create_attested(resource_id, manifest, opts) do
    with :ok <- prepare_copy_volumes(manifest, opts),
         {:ok, _output} <-
           command(create_args(manifest, Keyword.get(opts, :command, []), opts), opts),
         {:ok, observed} <- inspect(resource_id, Keyword.put(opts, :manifest, manifest)),
         :ok <- LaunchManifest.attest(manifest, observed) do
      {:ok, resource_id, %{status: :created, manifest: manifest, observed: observed}}
    else
      {:error, reason} ->
        _ = destroy(resource_id, opts)
        {:error, reason}
    end
  end

  @impl true
  def start(resource_id, opts) do
    with {:ok, output} <- command(["start", resource_id], opts) do
      {:ok,
       %{
         resource_id: resource_id,
         machine_id: resource_id,
         status: :running,
         output: String.trim(output)
       }}
    end
  end

  @impl true
  def stdio_transport(resource_id, opts) when is_binary(resource_id) and resource_id != "" do
    with {:ok, binary} <- signed_container_binary(opts) do
      {:ok,
       %{
         binary: binary,
         arguments: ["start", "--attach", "--interactive", resource_id],
         environment: transport_environment(opts)
       }}
    end
  end

  @impl true
  def await(resource_id, opts) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, 900_000)

    await_stopped(resource_id, deadline, opts)
  end

  @impl true
  def logs(resource_id, opts), do: command(["logs", resource_id], opts)

  @impl true
  def inspect(resource_id, opts) do
    case {Keyword.get(opts, :observed), Keyword.get(opts, :observed_factory)} do
      {%{} = observed, _factory} ->
        {:ok, observed}

      {nil, factory} when is_function(factory, 1) ->
        {:ok, factory.(Keyword.fetch!(opts, :manifest))}

      {nil, _factory} ->
        inspect_command(resource_id, opts)
    end
  end

  defp await_stopped(resource_id, deadline, opts) do
    case inspect(resource_id, opts) do
      {:ok, %{status: :stopped}} ->
        {:ok, %{status: :stopped, exit_status: nil}}

      {:ok, %{status: status}} when status in [:created, :running] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(100)
          await_stopped(resource_id, deadline, opts)
        else
          {:error, :apple_container_wait_timeout}
        end

      {:ok, %{status: status}} ->
        {:error, {:apple_container_wait_state_invalid, status}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def stop(resource_id, opts) do
    timeout = Keyword.get(opts, :grace_seconds, 10)

    case command(["stop", "--time", Integer.to_string(timeout), resource_id], opts) do
      {:ok, _output} -> :ok
      {:error, %{output: output}} when is_binary(output) -> idempotent_result(output)
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def destroy(resource_id, opts) do
    container_result =
      case command(["delete", "--force", resource_id], opts) do
        {:ok, _output} -> :ok
        {:error, %{output: output}} when is_binary(output) -> idempotent_result(output)
        {:error, reason} -> {:error, reason}
      end

    volume_result = cleanup_copy_volumes(resource_id, opts)

    case {container_result, volume_result} do
      {:ok, :ok} -> :ok
      other -> {:error, {:apple_container_destroy_failed, other}}
    end
  end

  @impl true
  def export(resource_id, destination, declared_paths, opts) do
    destination = Path.expand(destination)

    with %LaunchManifest{workspace_transport: :copy_snapshot} = manifest <-
           Keyword.fetch!(opts, :manifest),
         :ok <- allowed_export_destination(destination, opts),
         {:ok, paths} <- normalize_declared_paths(declared_paths),
         :ok <- ensure_export_targets_absent(destination, paths),
         :ok <- ensure_stopped(resource_id, manifest, opts),
         :ok <- File.mkdir_p(destination) do
      started = System.monotonic_time(:millisecond)
      staging = Path.join(destination, ".twelvgaige-export-#{System.unique_integer([:positive])}")

      result =
        try do
          with :ok <- File.mkdir(staging),
               :ok <- prepare_export_staging(staging, paths),
               {:ok, _output} <-
                 command(export_helper_args(resource_id, staging, paths, manifest), opts) do
            finalize_export(staging, destination, paths, opts)
          end
        after
          File.rm_rf(staging)
        end

      case result do
        {:ok, exported, bytes} ->
          {:ok,
           %{
             transport: :copy_snapshot,
             destination: destination,
             exported: Enum.reverse(exported),
             bytes: bytes,
             duration_ms: System.monotonic_time(:millisecond) - started
           }}

        {:error, _reason} = error ->
          error
      end
    else
      %LaunchManifest{} -> {:error, :sandbox_export_transport_invalid}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def export_workspace(resource_id, destination, opts) do
    destination = Path.expand(destination)

    with %LaunchManifest{workspace_transport: :copy_snapshot} = manifest <-
           Keyword.fetch!(opts, :manifest),
         :ok <- allowed_export_destination(destination, opts),
         :ok <- ensure_stopped(resource_id, manifest, opts) do
      staging =
        destination <>
          ".runtime-staging-" <> Integer.to_string(System.unique_integer([:positive]))

      result =
        with :ok <- File.mkdir(staging),
             {:ok, _output} <-
               command(full_export_helper_args(resource_id, staging, manifest), opts),
             {:ok, report} <-
               Twelvgaige.Workspace.RuntimeImport.replace(staging, destination, opts) do
          {:ok, Map.put(report, :transport, :copy_snapshot)}
        end

      if File.exists?(staging), do: File.rm_rf(staging)
      result
    else
      %LaunchManifest{} -> {:error, :sandbox_export_transport_invalid}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def reconcile(durable, opts) do
    resource_id = Map.fetch!(durable, :resource_id)
    manifest = Map.fetch!(durable, :manifest)

    case inspect(resource_id, Keyword.put(opts, :manifest, manifest)) do
      {:ok, observed} ->
        case LaunchManifest.attest(manifest, observed) do
          :ok -> {:ok, :resume, observed}
          {:error, _reason} -> {:ok, :quarantine, observed}
        end

      {:error, reason} ->
        {:ok, :missing, %{reason: reason}}
    end
  end

  @doc "Returns one-shot guest memory statistics for host-envelope accounting."
  def stats(resource_id, opts \\ []) do
    with {:ok, output} <- command(["stats", "--format", "json", "--no-stream", resource_id], opts),
         {:ok, decoded} <- Jason.decode(output),
         {:ok, record} <- one_record(decoded) do
      {:ok,
       %{
         resource_id: resource_id,
         memory_bytes:
           integer_value(record, [
             "memoryUsageBytes",
             "memoryUsageInBytes",
             "memory_usage",
             "memory"
           ]),
         memory_limit_bytes: integer_value(record, ["memoryLimitBytes"]),
         processes: integer_value(record, ["numProcesses"]),
         cpu_usage_usec: integer_value(record, ["cpuUsageUsec"]),
         cpu_percent: value(record, "cpuPercentage", value(record, "cpu_percent")),
         observed_at: DateTime.utc_now()
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Classifies repeated-session memory samples against an explicit host high-water mark."
  def memory_envelope(samples, declared_bytes, opts \\ [])
      when is_list(samples) and is_integer(declared_bytes) and declared_bytes > 0 do
    high_water_ratio = Keyword.get(opts, :high_water_ratio, 1.25)
    peak = samples |> Enum.map(&sample_memory/1) |> Enum.max(fn -> 0 end)
    high_water = trunc(declared_bytes * high_water_ratio)

    %{
      declared_bytes: declared_bytes,
      peak_bytes: peak,
      high_water_bytes: high_water,
      status: if(peak > high_water, do: :backend_restart_required, else: :within_envelope)
    }
  end

  @doc "Lists resources carrying Twelvgaige's management label for orphan reconciliation."
  def managed_resources(opts \\ []) do
    with {:ok, output} <- command(["list", "--all", "--format", "json"], opts),
         {:ok, decoded} <- Jason.decode(output) do
      resources =
        decoded
        |> records()
        |> Enum.filter(fn record ->
          value(value(record, "configuration", %{}), "labels", %{})[@managed_label] == "true"
        end)
        |> Enum.map(fn record -> value(record, "id", value(record, "name")) end)
        |> Enum.reject(&is_nil/1)

      {:ok, resources}
    end
  end

  defp capabilities do
    %{
      oci: true,
      inspect_json: true,
      network_none: true,
      vm_per_session: true,
      cap_drop: true,
      read_only_rootfs: true,
      rlimit_nproc: true,
      copy_snapshot: true
    }
  end

  defp inspect_command(resource_id, opts) do
    with {:ok, output} <- command(["inspect", resource_id], opts),
         {:ok, decoded} <- Jason.decode(output),
         {:ok, container} <- one_record(decoded) do
      {:ok, observed_evidence(container, Keyword.get(opts, :manifest), opts)}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp observed_evidence(container, manifest, opts) do
    config = value(container, "configuration", container)
    init = value(config, "initProcess", %{})
    user = get_in_flexible(init, ["user", "raw", "userString"]) || "0:0"
    [uid, gid] = parse_user(user)

    image_reference =
      get_in_flexible(config, ["image", "reference"]) || value(config, "imageReference")

    %{
      resource_id: value(container, "id"),
      machine_id: value(container, "id"),
      status: normalize_status(value(container, "status", value(container, "state"))),
      image_digest: digest_from_reference(image_reference),
      mounts: normalize_mounts(value(config, "mounts", [])),
      uid: uid,
      gid: gid,
      rootfs_mode: if(value(config, "readOnly", false), do: :read_only, else: :read_write),
      dropped_capabilities: normalize_capabilities(value(config, "capDrop", [])),
      security_options: [],
      network_mode: normalize_network(value(config, "networks", []), opts),
      limits: %{
        cpu: integer_value(value(config, "resources", %{}), ["cpus", "cpuCount"]),
        memory_bytes: integer_value(value(config, "resources", %{}), ["memoryInBytes", "memory"]),
        pids: process_limit(init)
      },
      environment_names: declared_environment_names(value(init, "environment", []), manifest),
      labels: expected_labels(value(config, "labels", %{}), manifest)
    }
  end

  defp create_args(manifest, worker_command, opts) do
    identity = ["create", "--name", manifest.resource_id]

    labels =
      manifest.labels
      |> Enum.sort()
      |> Enum.flat_map(fn {key, val} -> ["--label", "#{key}=#{val}"] end)

    security = [
      "--interactive",
      "--user",
      "#{manifest.uid}:#{manifest.gid}",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--cpus",
      Integer.to_string(value(manifest.limits, :cpu)),
      "--memory",
      "#{div(value(manifest.limits, :memory_bytes), @mib)}M",
      "--ulimit",
      "nproc=#{value(manifest.limits, :pids)}:#{value(manifest.limits, :pids)}"
    ]

    network = network_args(manifest.network_mode, opts)

    mounts = mount_args(manifest)
    environment = runtime_environment_args(opts)
    worker_command = wrap_copy_snapshot_command(manifest, worker_command)

    identity ++
      labels ++
      security ++ network ++ environment ++ mounts ++ [image_identity(manifest)] ++ worker_command
  end

  defp verify_image(manifest, opts) do
    if Keyword.get(opts, :verify_image?, true) do
      with {:ok, output} <- command(["image", "inspect", image_identity(manifest)], opts),
           {:ok, decoded} <- Jason.decode(output),
           {:ok, image} <- one_record(decoded) do
        reference = get_in_flexible(image, ["configuration", "name"])

        if exact_image_identity?(reference, manifest),
          do: :ok,
          else: {:error, :apple_container_image_digest_mismatch}
      else
        {:error, %Jason.DecodeError{}} -> {:error, :apple_container_image_inspect_invalid}
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp image_identity(manifest), do: manifest.image_reference <> "@" <> manifest.image_digest

  defp exact_image_identity?(reference, manifest) when is_binary(reference) do
    digest_from_reference(reference) == manifest.image_digest and
      image_repository(reference) == image_repository(manifest.image_reference)
  end

  defp exact_image_identity?(_reference, _manifest), do: false

  defp image_repository(reference) do
    reference
    |> String.split("@", parts: 2)
    |> hd()
    |> String.replace(~r/:[^\/:]+$/, "")
  end

  defp network_args(:none, _opts), do: ["--network", "none", "--no-dns"]

  defp network_args(:broker_only, opts) do
    ["--network", Keyword.fetch!(opts, :broker_network), "--no-dns"]
  end

  defp network_args(:unrestricted, _opts), do: []

  defp normalize_network([], _opts), do: :none
  defp normalize_network(nil, _opts), do: :none

  defp normalize_network(networks, opts) do
    names = records(networks) |> Enum.map(&network_name/1)
    broker = Keyword.get(opts, :broker_network, "twelvgaige-broker")
    if broker in names, do: :broker_only, else: :unrestricted
  end

  defp validate_runtime_environment(manifest, opts) do
    environment = runtime_environment(opts)
    names = environment |> Map.keys() |> Enum.sort()

    cond do
      Enum.sort(manifest.environment_names) != names ->
        {:error, :proxy_environment_attestation_mismatch}

      not Enum.all?(environment, fn {name, value} ->
        name in manifest.environment_names and is_binary(value) and value != ""
      end) ->
        {:error, :proxy_environment_invalid}

      manifest.network_mode == :broker_only and
          not Enum.all?(@proxy_environment_names, &Map.has_key?(environment, &1)) ->
        {:error, :proxy_environment_required}

      true ->
        :ok
    end
  end

  defp runtime_environment_args(opts) do
    opts
    |> runtime_environment()
    |> Enum.sort()
    |> Enum.flat_map(fn {name, value} -> ["--env", "#{name}=#{value}"] end)
  end

  defp runtime_environment(opts) do
    Keyword.get(opts, :environment, %{})
    |> Map.merge(Keyword.get(opts, :proxy_environment, %{}))
  end

  defp declared_environment_names(environment, manifest) do
    expected = MapSet.new(if(manifest, do: manifest.environment_names, else: []))

    environment
    |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))
    |> Enum.filter(&MapSet.member?(expected, &1))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp network_name(name) when is_binary(name), do: name

  defp network_name(network),
    do: value(network, "name", value(network, "network", value(network, "id")))

  defp normalize_mounts(mounts) do
    mounts
    |> records()
    |> Enum.map(fn mount ->
      options = value(mount, "options", [])

      %{
        source: value(mount, "source"),
        destination: value(mount, "destination", value(mount, "target")),
        mode: if(readonly_mount?(options), do: :read_only, else: :read_write),
        type: normalize_mount_type(value(mount, "type", "bind"))
      }
    end)
  end

  defp readonly_mount?(options) when is_list(options),
    do: Enum.any?(options, &(&1 in ["ro", "readonly", "read-only"]))

  defp readonly_mount?(_options), do: false

  defp normalize_mount_type(%{"volume" => _details}), do: :volume
  defp normalize_mount_type(%{"virtiofs" => _details}), do: :bind
  defp normalize_mount_type(type) when type in ["volume", :volume], do: :volume
  defp normalize_mount_type(_type), do: :bind

  defp normalize_capabilities(capabilities) do
    if Enum.any?(List.wrap(capabilities), &(String.upcase(to_string(&1)) == "ALL")),
      do: ["ALL"],
      else: []
  end

  defp prepare_copy_volumes(%{workspace_transport: :copy_snapshot} = manifest, opts) do
    Enum.reduce_while(manifest.mounts, :ok, fn mount, :ok ->
      name = copy_volume_name(manifest.resource_id, mount.destination)

      with {:ok, _output} <- command(volume_create_args(name, manifest, mount, opts), opts),
           {:ok, _output} <- command(volume_initializer_args(manifest, mount, name), opts) do
        {:cont, :ok}
      else
        {:error, reason} ->
          _ = command(["delete", "--force", copy_initializer_name(manifest, mount)], opts)
          {:halt, {:error, {:copy_volume_create_failed, name, reason}}}
      end
    end)
  end

  defp prepare_copy_volumes(_manifest, _opts), do: :ok

  defp cleanup_copy_volumes(resource_id, opts) do
    with {:ok, output} <- command(["volume", "list", "--format", "json"], opts),
         {:ok, available} <- decode_volume_names(output) do
      ["/workspace", "/artifacts", "/run/codex-home"]
      |> Enum.map(&copy_volume_name(resource_id, &1))
      |> Enum.filter(&MapSet.member?(available, &1))
      |> Enum.reduce_while(:ok, fn name, :ok ->
        case command(["volume", "delete", name], opts) do
          {:ok, _output} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp decode_volume_names(output) do
    if String.trim(output) == "" do
      {:ok, MapSet.new()}
    else
      with {:ok, decoded} <- Jason.decode(output) do
        names =
          decoded
          |> records()
          |> Enum.map(&value(&1, "name", value(&1, "id")))
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        {:ok, names}
      else
        {:error, _reason} -> {:error, :apple_container_volume_inventory_invalid}
      end
    end
  end

  defp mount_args(%{workspace_transport: :copy_snapshot} = manifest) do
    Enum.flat_map(manifest.mounts, fn mount ->
      volume = copy_volume_name(manifest.resource_id, mount.destination)
      readonly = if mount.mode == :read_only, do: ",readonly", else: ""

      ["--mount", "type=volume,source=#{volume},target=#{mount.destination}#{readonly}"]
    end)
  end

  defp mount_args(manifest) do
    Enum.flat_map(manifest.mounts, fn mount ->
      readonly = if mount.mode == :read_only, do: ",readonly", else: ""
      ["--mount", "type=bind,source=#{mount.source},target=#{mount.destination}#{readonly}"]
    end)
  end

  defp wrap_copy_snapshot_command(_manifest, command), do: command

  defp copy_volume_name(resource_id, destination) do
    suffix = destination |> String.trim_leading("/") |> String.replace(~r/[^A-Za-z0-9_.-]/, "-")
    resource_id <> "-" <> suffix
  end

  defp copy_initializer_name(manifest, mount),
    do: copy_volume_name(manifest.resource_id, mount.destination) <> "-init"

  defp volume_initializer_args(manifest, mount, volume) do
    destination = mount.destination
    import = "/run/twelvgaige-import" <> destination

    [
      "run",
      "--rm",
      "--name",
      copy_initializer_name(manifest, mount),
      "--label",
      "io.twelvgaige.managed=true",
      "--label",
      "io.twelvgaige.qualification=copy-snapshot-volume-init",
      "--user",
      "0:0",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--cap-add",
      "CHOWN",
      "--cap-add",
      "DAC_READ_SEARCH",
      "--cpus",
      "1",
      "--memory",
      "200M",
      "--ulimit",
      "nproc=8:8",
      "--network",
      "none",
      "--no-dns",
      "--mount",
      "type=bind,source=#{mount.source},target=#{import},readonly",
      "--mount",
      "type=volume,source=#{volume},target=#{destination}",
      image_identity(manifest),
      "/bin/sh",
      "-lc",
      "set -eu; cp -R #{shell_quote(import)}/. #{shell_quote(destination)}/; chown -R #{manifest.uid}:#{manifest.gid} #{shell_quote(destination)}"
    ]
  end

  defp volume_create_args(name, manifest, mount, opts) do
    bytes = volume_size_bytes(mount.destination, opts)

    [
      "volume",
      "create",
      "--label",
      "#{@managed_label}=true",
      "--label",
      "io.twelvgaige.resource=#{manifest.resource_id}",
      "--label",
      "io.twelvgaige.manifest=#{manifest.manifest_digest}",
      "-s",
      Integer.to_string(bytes),
      name
    ]
  end

  defp volume_size_bytes("/artifacts", opts),
    do: positive_bytes(opts, :artifact_volume_bytes, @default_workspace_volume_bytes)

  defp volume_size_bytes(_destination, opts),
    do: positive_bytes(opts, :workspace_volume_bytes, @default_workspace_volume_bytes)

  defp positive_bytes(opts, key, default) do
    case Keyword.get(opts, key) do
      value when is_integer(value) and value > 0 -> value
      _other -> default
    end
  end

  defp ensure_stopped(resource_id, manifest, opts) do
    case inspect(resource_id, Keyword.put(opts, :manifest, manifest)) do
      {:ok, %{status: :stopped}} -> :ok
      {:ok, _observed} -> {:error, :apple_export_requires_stopped_worker}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_export_targets_absent(destination, paths) do
    case Enum.find(paths, &path_present?(Path.join(destination, &1))) do
      nil -> :ok
      relative -> {:error, {:export_target_exists, relative}}
    end
  end

  defp path_present?(path) do
    case File.lstat(path) do
      {:ok, _stat} -> true
      {:error, :enoent} -> false
      {:error, _reason} -> true
    end
  end

  defp prepare_export_staging(staging, paths) do
    Enum.reduce_while(paths, :ok, fn relative, :ok ->
      case File.mkdir_p(Path.dirname(Path.join(staging, relative))) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {relative, reason}}}
      end
    end)
  end

  defp export_helper_args(resource_id, staging, paths, manifest) do
    helper_id = resource_id <> "-export-" <> Integer.to_string(System.unique_integer([:positive]))
    volume = copy_volume_name(resource_id, "/workspace")

    copies =
      paths
      |> Enum.map(fn relative ->
        source = "/source/" <> relative
        target = "/export/" <> relative

        "([ -e #{shell_quote(source)} ] || [ -L #{shell_quote(source)} ]) && " <>
          "cp -R #{shell_quote(source)} #{shell_quote(target)}"
      end)
      |> Enum.join("; ")

    [
      "run",
      "--rm",
      "--name",
      helper_id,
      "--label",
      "#{@managed_label}=true",
      "--label",
      "io.twelvgaige.resource=#{resource_id}",
      "--label",
      "io.twelvgaige.role=copy-snapshot-export",
      "--user",
      "#{manifest.uid}:#{manifest.gid}",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--cpus",
      "1",
      "--memory",
      "200M",
      "--ulimit",
      "nproc=16:16",
      "--network",
      "none",
      "--no-dns",
      "--mount",
      "type=volume,source=#{volume},target=/source,readonly",
      "--mount",
      "type=bind,source=#{staging},target=/export",
      image_identity(manifest),
      "/bin/sh",
      "-lc",
      "set -eu; umask 077; #{copies}"
    ]
  end

  defp full_export_helper_args(resource_id, staging, manifest) do
    helper_id =
      resource_id <> "-export-all-" <> Integer.to_string(System.unique_integer([:positive]))

    volume = copy_volume_name(resource_id, "/workspace")

    [
      "run",
      "--rm",
      "--name",
      helper_id,
      "--label",
      "#{@managed_label}=true",
      "--label",
      "io.twelvgaige.resource=#{resource_id}",
      "--label",
      "io.twelvgaige.role=copy-snapshot-export",
      "--user",
      "#{manifest.uid}:#{manifest.gid}",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--cpus",
      "1",
      "--memory",
      "200M",
      "--ulimit",
      "nproc=16:16",
      "--network",
      "none",
      "--no-dns",
      "--mount",
      "type=volume,source=#{volume},target=/source,readonly",
      "--mount",
      "type=bind,source=#{staging},target=/export",
      image_identity(manifest),
      "/bin/sh",
      "-lc",
      "set -eu; umask 077; cp -R /source/. /export/"
    ]
  end

  defp finalize_export(staging, destination, paths, opts) do
    Enum.reduce_while(paths, {:ok, [], 0}, fn relative, {:ok, exported, bytes} ->
      target = Path.join(destination, relative)
      staged_target = Path.join(staging, relative)

      with :ok <- Twelvgaige.Workspace.Transport.validate_export_tree(staged_target),
           size <- tree_bytes(staged_target),
           :ok <- within_export_limit(bytes + size, opts),
           :ok <- File.mkdir_p(Path.dirname(target)),
           :ok <- File.rename(staged_target, target) do
        {:cont, {:ok, [%{path: relative, bytes: size} | exported], bytes + size}}
      else
        {:error, reason} -> {:halt, {:error, {relative, reason}}}
      end
    end)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp allowed_export_destination(destination, opts) do
    roots =
      opts
      |> Keyword.fetch!(:allowed_export_roots)
      |> Enum.map(&(&1 |> Path.expand() |> Path.absname()))

    if Enum.any?(roots, &(destination == &1 or String.starts_with?(destination, &1 <> "/"))),
      do: :ok,
      else: {:error, :export_destination_denied}
  end

  defp normalize_declared_paths(paths) when is_list(paths) and paths != [] do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      if is_binary(path) and path not in ["", "."] and Path.type(path) == :relative and
           ".." not in Path.split(path) do
        normalized = path |> Path.expand("/") |> Path.relative_to("/")
        {:cont, {:ok, [normalized | acc]}}
      else
        {:halt, {:error, :export_path_invalid}}
      end
    end)
    |> case do
      {:ok, normalized} -> reject_overlapping_paths(normalized |> Enum.uniq() |> Enum.sort())
      error -> error
    end
  end

  defp normalize_declared_paths(_paths), do: {:error, :export_paths_required}

  defp reject_overlapping_paths(paths) do
    overlap? =
      Enum.any?(paths, fn parent ->
        Enum.any?(paths, fn child ->
          child != parent and String.starts_with?(child, parent <> "/")
        end)
      end)

    if overlap?, do: {:error, :export_paths_overlap}, else: {:ok, paths}
  end

  defp within_export_limit(bytes, opts) do
    case Keyword.get(opts, :max_export_bytes) do
      nil -> :ok
      limit when is_integer(limit) and limit >= bytes -> :ok
      _limit -> {:error, :export_size_limit_exceeded}
    end
  end

  defp tree_bytes(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        size

      {:ok, %File.Stat{type: :directory}} ->
        path |> File.ls!() |> Enum.map(&tree_bytes(Path.join(path, &1))) |> Enum.sum()

      _other ->
        0
    end
  end

  defp process_limit(init) do
    init
    |> value("rlimits", [])
    |> records()
    |> Enum.find_value(fn limit ->
      if value(limit, "limit") == "RLIMIT_NPROC",
        do: integer_value(limit, ["hard", "soft"]),
        else: nil
    end)
  end

  defp exact_memory_limit(limits) do
    memory = value(limits, :memory_bytes)

    if is_integer(memory) and memory > 0 and rem(memory, @mib) == 0,
      do: :ok,
      else: {:error, :apple_container_memory_must_be_whole_mib}
  end

  defp parse_version(output) do
    case Regex.run(~r/\b(\d+\.\d+\.\d+)\b/, output, capture: :all_but_first) do
      [version] -> {:ok, version}
      _other -> {:error, :apple_container_version_invalid}
    end
  end

  defp supported_version(version, opts) do
    supported = Keyword.get(opts, :supported_versions, [@supported_version])

    if version in supported,
      do: :ok,
      else: {:error, {:unsupported_apple_container_version, version}}
  end

  defp running_service(output) do
    if Regex.match?(~r/(^|\n)\s*(status\s*[: ]\s*)?running\s*($|\n)/i, output),
      do: :ok,
      else: {:error, :apple_container_service_not_running}
  end

  defp supported_macos(version) do
    case Integer.parse(version) do
      {major, _rest} when major >= 26 -> :ok
      _other -> {:error, {:unsupported_macos_version, version}}
    end
  end

  defp apple_silicon(architecture) when architecture in ["arm64", "aarch64"], do: :ok
  defp apple_silicon(architecture), do: {:error, {:unsupported_architecture, architecture}}

  defp verify_cli_signature(opts) do
    binary = resolve_container_binary(opts)
    identifier = Keyword.get(opts, :codesign_identifier, @codesign_identifier)
    team = Keyword.get(opts, :codesign_team, @codesign_team)

    with true <- is_binary(binary) or {:error, :apple_container_binary_not_found},
         {:ok, _verified} <-
           host_command_result("codesign", ["--verify", "--strict", binary], opts),
         {:ok, details} <-
           host_command_result("codesign", ["-d", "--verbose=2", binary], opts),
         true <-
           String.contains?(details, "Identifier=#{identifier}") or
             {:error, :apple_container_signature_identifier_mismatch},
         true <-
           String.contains?(details, "TeamIdentifier=#{team}") or
             {:error, :apple_container_signature_team_mismatch} do
      {:ok, %{identifier: identifier, team_identifier: team, verified: true}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp signed_container_binary(opts) do
    with {:ok, _signature} <- verify_cli_signature(opts),
         binary when is_binary(binary) <- resolve_container_binary(opts) do
      {:ok, binary}
    else
      nil -> {:error, :apple_container_binary_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp transport_environment(opts) do
    Keyword.get_lazy(opts, :transport_environment, fn ->
      ["PATH", "HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR"]
      |> Enum.flat_map(fn name ->
        case System.get_env(name) do
          nil -> []
          value -> [{name, value}]
        end
      end)
    end)
  end

  defp resolve_container_binary(opts) do
    case Keyword.get(opts, :container_binary_path) ||
           Keyword.get(opts, :container_binary, "container") do
      binary when is_binary(binary) ->
        if Path.type(binary) == :absolute, do: binary, else: System.find_executable(binary)

      _other ->
        nil
    end
  end

  defp host_command_result(binary, args, opts) do
    runner = Keyword.get(opts, :command_runner, &CommandRunner.run/3)

    case runner.(Keyword.get(opts, String.to_atom("#{binary}_binary"), binary), args,
           timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
           require_absolute_binary?: Keyword.get(opts, :require_absolute_binary?, false),
           scrub_env?: true,
           posix_port?: true
         ) do
      {:ok, %{status: 0} = result} ->
        {:ok, result.stdout <> result.stderr}

      {:ok, %{status: status} = result} ->
        {:error, %{status: status, output: result.stdout <> result.stderr}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp host_command(binary, args, opts) do
    runner = Keyword.get(opts, :command_runner, &CommandRunner.run/3)

    case runner.(Keyword.get(opts, String.to_atom("#{binary}_binary"), binary), args,
           timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
           require_absolute_binary?: Keyword.get(opts, :require_absolute_binary?, false),
           scrub_env?: true,
           posix_port?: true
         ) do
      {:ok, %{status: 0, stdout: stdout}} -> {:ok, stdout}
      {:ok, %{status: status} = result} -> {:error, %{status: status, output: result.stdout}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp command(args, opts) do
    with {:ok, _signature} <- verify_cli_signature(opts) do
      command_verified(args, opts)
    end
  end

  defp command_verified(args, opts) do
    runner = Keyword.get(opts, :command_runner, &CommandRunner.run/3)

    case resolve_container_binary(opts) do
      binary when is_binary(binary) ->
        case runner.(binary, args,
               timeout_ms: Keyword.get(opts, :timeout_ms, 30_000),
               require_absolute_binary?: true,
               scrub_env?: true,
               posix_port?: true
             ) do
          {:ok, %{status: 0, stdout: stdout}} ->
            {:ok, stdout}

          {:ok, %{status: status} = result} ->
            {:error, %{status: status, output: result.stdout <> result.stderr}}

          {:error, reason} ->
            {:error, reason}
        end

      nil ->
        {:error, :apple_container_binary_not_found}
    end
  end

  defp idempotent_result(output) do
    if Regex.match?(~r/(not found|does not exist|no such|not running|already stopped)/i, output),
      do: :ok,
      else: {:error, output}
  end

  defp one_record([record | _]) when is_map(record), do: {:ok, record}
  defp one_record(record) when is_map(record), do: {:ok, record}
  defp one_record(_other), do: {:error, :apple_container_json_invalid}

  defp records(records) when is_list(records), do: records
  defp records(record) when is_map(record), do: [record]
  defp records(_other), do: []

  defp parse_user(user) do
    case String.split(to_string(user), ":", parts: 2) do
      [uid, gid] -> [parse_integer(uid), parse_integer(gid)]
      [uid] -> [parse_integer(uid), nil]
    end
  end

  defp digest_from_reference(reference) when is_binary(reference) do
    case String.split(reference, "@", parts: 2) do
      [_name, "sha256:" <> digest] -> "sha256:" <> digest
      _other -> reference
    end
  end

  defp digest_from_reference(_reference), do: nil

  defp integer_value(map, keys) do
    Enum.find_value(keys, fn key ->
      case value(map, key) do
        integer when is_integer(integer) -> integer
        float when is_float(float) -> trunc(float)
        binary when is_binary(binary) -> parse_integer(binary)
        _other -> nil
      end
    end)
  end

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp expected_labels(labels, %LaunchManifest{labels: expected}),
    do: Map.take(labels, Map.keys(expected))

  defp expected_labels(labels, _manifest), do: labels

  defp normalize_status(status) when status in ["running", :running], do: :running
  defp normalize_status(status) when status in ["stopped", :stopped, "exited"], do: :stopped
  defp normalize_status(%{} = status), do: status |> value("state") |> normalize_status()
  defp normalize_status(status), do: status

  defp sample_memory(%{memory_bytes: memory}) when is_integer(memory), do: memory
  defp sample_memory(%{"memory_bytes" => memory}) when is_integer(memory), do: memory
  defp sample_memory(memory) when is_integer(memory), do: memory
  defp sample_memory(_sample), do: 0

  defp get_in_flexible(map, keys) do
    Enum.reduce_while(keys, map, fn key, current ->
      case value(current, key, :missing) do
        :missing -> {:halt, nil}
        next -> {:cont, next}
      end
    end)
  end

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, alternate_key(key), default))

  defp value(_map, _key, default), do: default

  defp alternate_key(key) when is_atom(key), do: Atom.to_string(key)

  defp alternate_key(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end
end
