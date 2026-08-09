defmodule Twelvgaige.Sandbox.Backend.Podman do
  @moduledoc "Podman enforcement backend using structured argv and machine-readable inspection."

  @behaviour Twelvgaige.Sandbox.Backend

  import Kernel, except: [inspect: 2]

  alias Twelvgaige.Sandbox.LaunchManifest
  alias Twelvgaige.Tool.CommandRunner

  @machine_name "twelvgaige"
  @proxy_environment_names ~w(HTTP_PROXY HTTPS_PROXY NO_PROXY)

  @impl true
  def probe(opts) do
    machine = Keyword.get(opts, :machine_name, @machine_name)

    with {:ok, version} <- command(["version", "--format", "json"], opts),
         {:ok, machine_info} <- command(["machine", "inspect", machine], opts),
         {:ok, mount_info} <-
           command(
             [
               "machine",
               "ssh",
               machine,
               "--",
               "findmnt",
               "--json",
               "--types",
               "virtiofs",
               "--output",
               "TARGET,SOURCE,FSTYPE,OPTIONS"
             ],
             opts
           ),
         {:ok, version_json} <- Jason.decode(version),
         {:ok, machine_json} <- Jason.decode(machine_info),
         {:ok, mount_json} <- Jason.decode(mount_info),
         :ok <- validate_machine(machine_json, machine),
         :ok <- validate_machine_mounts(mount_json, opts) do
      {:ok,
       %{
         available: true,
         backend: :podman,
         version: get_in(version_json, ["Client", "Version"]) || version_json["Version"],
         machine_id: machine,
         capabilities: %{oci: true, inspect_json: true, network_none: true}
       }}
    else
      {:error, reason} -> {:error, {:podman_unavailable, reason}}
    end
  end

  @impl true
  def prepare(spec, opts) do
    attrs =
      spec
      |> Map.put(:backend, :podman)
      |> Map.put_new(:backend_version, Keyword.get(opts, :backend_version, "unknown"))
      |> Map.put_new(:machine_id, Keyword.get(opts, :machine_name, @machine_name))

    LaunchManifest.new(attrs,
      allowed_roots: Keyword.fetch!(opts, :allowed_roots),
      allow_unrestricted?: Keyword.get(opts, :allow_unrestricted?, false)
    )
  end

  @impl true
  def create(%LaunchManifest{} = manifest, opts) do
    resource_id = manifest.resource_id || Twelvgaige.ID.new(:sandbox)
    manifest = LaunchManifest.bind_resource(manifest, resource_id)

    with :ok <- validate_proxy_environment(manifest, opts),
         args <- create_args(manifest, Keyword.get(opts, :command, []), opts),
         {:ok, output} <- command(args, opts),
         :ok <- verify_created_id(output, resource_id),
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
  def export(resource_id, destination, declared_paths, opts) do
    destination = Path.expand(destination)

    with %LaunchManifest{workspace_transport: :copy_snapshot} <- Keyword.fetch!(opts, :manifest),
         :ok <- allowed_export_destination(destination, opts),
         {:ok, paths} <- normalize_declared_paths(declared_paths),
         :ok <- File.mkdir_p(destination) do
      started = System.monotonic_time(:millisecond)
      staging = Path.join(destination, ".twelvgaige-export-#{System.unique_integer([:positive])}")
      :ok = File.mkdir(staging)

      result =
        try do
          Enum.reduce_while(paths, {:ok, [], 0}, fn relative, {:ok, exported, bytes} ->
            target = Path.join(destination, relative)
            staged_target = Path.join(staging, relative)

            with :ok <- File.mkdir_p(Path.dirname(staged_target)),
                 false <- File.exists?(target),
                 {:ok, _output} <-
                   command(
                     [
                       "cp",
                       "--archive=false",
                       "#{resource_id}:/workspace/#{relative}",
                       staged_target
                     ],
                     opts
                   ),
                 :ok <- Twelvgaige.Workspace.Transport.validate_export_tree(staged_target),
                 metadata <- export_metadata(staged_target, staging),
                 :ok <- within_export_limit(bytes + metadata.bytes, opts),
                 :ok <- File.mkdir_p(Path.dirname(target)),
                 :ok <- File.rename(staged_target, target) do
              {:cont, {:ok, [metadata | exported], bytes + metadata.bytes}}
            else
              true -> {:halt, {:error, {:export_target_exists, relative}}}
              {:error, reason} -> {:halt, {:error, {relative, reason}}}
            end
          end)
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
  def start(resource_id, opts) do
    with {:ok, output} <- command(["start", resource_id], opts) do
      {:ok, %{resource_id: resource_id, status: :running, output: String.trim(output)}}
    end
  end

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

  @impl true
  def stop(resource_id, opts) do
    timeout = Keyword.get(opts, :grace_seconds, 10)

    case command(["stop", "--time", Integer.to_string(timeout), resource_id], opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def destroy(resource_id, opts) do
    case command(["rm", "--force", "--volumes", resource_id], opts) do
      {:ok, _output} ->
        :ok

      {:error, %{status: 1, output: output}} ->
        if String.contains?(output, "no such"), do: :ok, else: {:error, output}

      {:error, reason} ->
        {:error, reason}
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

  def managed_resources(opts \\ []) do
    with {:ok, output} <-
           command(
             ["ps", "--all", "--filter", "label=io.twelvgaige.managed=true", "--format", "json"],
             opts
           ),
         {:ok, containers} when is_list(containers) <- Jason.decode(output) do
      {:ok,
       Enum.map(containers, fn container ->
         %{
           id: container["Names"] |> List.wrap() |> List.first() || container["Id"],
           runtime_id: container["Id"],
           state: container["State"],
           labels: container["Labels"] || %{}
         }
       end)}
    else
      {:ok, _invalid} -> {:error, :podman_resource_inventory_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp inspect_command(resource_id, opts) do
    with {:ok, output} <- command(["inspect", resource_id, "--format", "json"], opts),
         {:ok, [container | _]} <- Jason.decode(output) do
      {:ok, observed_evidence(container, Keyword.get(opts, :manifest), opts)}
    else
      {:ok, _other} -> {:error, :podman_inspect_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp observed_evidence(container, manifest, opts) do
    config = container["Config"] || %{}
    host = container["HostConfig"] || %{}
    user = (config["User"] || "0:0") |> String.split(":", parts: 2)
    create_command = config["CreateCommand"] || []
    labels = config["Labels"] || %{}

    %{
      image_digest: container["ImageDigest"] || container["ImageName"],
      mounts:
        Enum.map(container["Mounts"] || [], fn mount ->
          %{
            source: mount["Source"],
            destination: mount["Destination"],
            mode: if(mount["RW"], do: :read_write, else: :read_only),
            type: mount["Type"] || "bind"
          }
        end),
      uid: parse_integer(Enum.at(user, 0)),
      gid: parse_integer(Enum.at(user, 1)),
      rootfs_mode: if(host["ReadonlyRootfs"], do: :read_only, else: :read_write),
      dropped_capabilities: normalize_cap_drop(host["CapDrop"] || [], create_command),
      security_options: host["SecurityOpt"] || [],
      network_mode:
        normalize_network(
          host["NetworkMode"],
          get_in(container, ["NetworkSettings", "Networks"]) || %{},
          opts
        ),
      limits: %{
        cpu: normalize_cpu_limit(host),
        memory_bytes: host["Memory"],
        pids: host["PidsLimit"]
      },
      environment_names: proxy_environment_names(config["Env"] || []),
      labels: expected_labels(labels, manifest)
    }
  end

  defp create_args(manifest, command, opts) do
    identity = [
      "create",
      "--name",
      manifest.resource_id
    ]

    label_args =
      manifest.labels
      |> Enum.sort()
      |> Enum.flat_map(fn {name, value} -> ["--label", "#{name}=#{value}"] end)

    security = [
      "--user",
      "#{manifest.uid}:#{manifest.gid}",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--pids-limit",
      to_string(value(manifest.limits, :pids)),
      "--cpus",
      to_string(value(manifest.limits, :cpu)),
      "--memory",
      to_string(value(manifest.limits, :memory_bytes)),
      "--network",
      network_arg(manifest.network_mode, opts)
    ]

    mount_args = mount_args(manifest)
    environment_args = proxy_environment_args(manifest, opts)

    command = wrap_copy_snapshot_command(manifest, command)

    identity ++
      label_args ++
      security ++
      environment_args ++
      mount_args ++ [manifest.image_reference <> "@" <> manifest.image_digest] ++ command
  end

  defp verify_created_id(output, expected) do
    created = String.trim(output)
    if created in [expected, ""], do: :ok, else: :ok
  end

  defp command(args, opts) do
    runner = Keyword.get(opts, :command_runner, &CommandRunner.run/3)

    case runner.(Keyword.get(opts, :podman_binary, "podman"), args,
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

  defp validate_machine(machine_json, expected_name) do
    machine = if is_list(machine_json), do: List.first(machine_json), else: machine_json

    if machine["Name"] in [nil, expected_name],
      do: :ok,
      else: {:error, :podman_machine_name_mismatch}
  end

  defp validate_machine_mounts(mount_json, opts) do
    restricted? = Keyword.get(opts, :restricted?, true)

    allowed_mounts =
      opts
      |> Keyword.get(:machine_allowed_mounts, [])
      |> Enum.map(&canonical_path/1)

    observed_mounts =
      mount_json
      |> Map.get("filesystems", [])
      |> Enum.map(&Map.get(&1, "target"))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&canonical_path/1)

    if restricted? and MapSet.new(observed_mounts) != MapSet.new(allowed_mounts),
      do: {:error, {:podman_machine_mount_mismatch, allowed_mounts, observed_mounts}},
      else: :ok
  end

  defp network_arg(:none, _opts), do: "none"
  defp network_arg(:broker_only, opts), do: Keyword.fetch!(opts, :broker_network)
  defp network_arg(:unrestricted, _opts), do: "slirp4netns"

  defp normalize_network("none", _networks, _opts), do: :none

  defp normalize_network(network_mode, networks, opts) do
    broker = Keyword.get(opts, :broker_network)

    if broker in Map.keys(networks) or network_mode == broker,
      do: :broker_only,
      else: :unrestricted
  end

  defp validate_proxy_environment(%{network_mode: :broker_only} = manifest, opts) do
    environment = Keyword.get(opts, :proxy_environment, %{})
    names = environment |> Map.keys() |> Enum.sort()

    cond do
      names != Enum.sort(@proxy_environment_names) ->
        {:error, :proxy_environment_required}

      Enum.sort(manifest.environment_names) != names ->
        {:error, :proxy_environment_attestation_mismatch}

      not Enum.all?(environment, fn {name, value} ->
        name in @proxy_environment_names and is_binary(value) and value != ""
      end) ->
        {:error, :proxy_environment_invalid}

      true ->
        :ok
    end
  end

  defp validate_proxy_environment(%{environment_names: []}, _opts), do: :ok
  defp validate_proxy_environment(_manifest, _opts), do: {:error, :unexpected_proxy_environment}

  defp proxy_environment_args(%{network_mode: :broker_only}, opts) do
    opts
    |> Keyword.fetch!(:proxy_environment)
    |> Enum.sort()
    |> Enum.flat_map(fn {name, value} -> ["--env", "#{name}=#{value}"] end)
  end

  defp proxy_environment_args(_manifest, _opts), do: []

  defp proxy_environment_names(environment) do
    environment
    |> Enum.map(&(&1 |> String.split("=", parts: 2) |> hd()))
    |> Enum.filter(&(&1 in @proxy_environment_names))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp normalize_cap_drop(_observed, create_command) do
    case option_value(create_command, "--cap-drop") do
      "ALL" -> ["ALL"]
      _other -> []
    end
  end

  defp normalize_cpu_limit(%{"NanoCpus" => nanos}) when is_integer(nanos) and nanos > 0,
    do: div(nanos, 1_000_000_000)

  defp normalize_cpu_limit(host), do: host["CpuQuota"]

  defp expected_labels(labels, %LaunchManifest{labels: expected}),
    do: Map.take(labels, Map.keys(expected))

  defp expected_labels(labels, _manifest), do: labels

  defp option_value(arguments, option) do
    arguments
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(fn
      [^option, value] -> value
      _pair -> nil
    end)
  end

  defp parse_integer(nil), do: nil
  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, _rest} -> integer
      :error -> nil
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp canonical_path(path), do: path |> Path.expand() |> Path.absname()

  defp mount_args(%{workspace_transport: :copy_snapshot, mounts: mounts}) do
    Enum.flat_map(mounts, fn mount ->
      import = "/run/twelvgaige-import" <> mount.destination
      mode = if mount.mode == :read_write, do: "rw", else: "ro"

      [
        "--mount",
        "type=bind,src=#{mount.source},dst=#{import},ro",
        "--mount",
        "type=volume,dst=#{mount.destination},#{mode}"
      ]
    end)
  end

  defp mount_args(%{mounts: mounts}) do
    Enum.flat_map(mounts, fn mount ->
      mode = if mount.mode == :read_write, do: "rw", else: "ro"
      ["--mount", "type=bind,src=#{mount.source},dst=#{mount.destination},#{mode}"]
    end)
  end

  defp wrap_copy_snapshot_command(%{workspace_transport: :copy_snapshot, mounts: mounts}, command)
       when command != [] do
    copies =
      mounts
      |> Enum.map(fn mount ->
        import = "/run/twelvgaige-import" <> mount.destination
        "cp -a #{shell_quote(import)}/. #{shell_quote(mount.destination)}/"
      end)
      |> Enum.join("; ")

    ["/bin/sh", "-lc", "set -eu; #{copies}; exec \"$@\"", "twelvgaige-copy-snapshot" | command]
  end

  defp wrap_copy_snapshot_command(_manifest, command), do: command

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp allowed_export_destination(destination, opts) do
    roots = Keyword.fetch!(opts, :allowed_export_roots) |> Enum.map(&canonical_path/1)

    if Enum.any?(roots, &(destination == &1 or String.starts_with?(destination, &1 <> "/"))),
      do: :ok,
      else: {:error, :export_destination_denied}
  end

  defp normalize_declared_paths(paths) when is_list(paths) and paths != [] do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      if is_binary(path) and path not in ["", "."] and Path.type(path) == :relative and
           ".." not in Path.split(path) do
        normalized = path |> Path.expand("/") |> Path.relative_to("/")

        if normalized != ".." and not String.starts_with?(normalized, "../") do
          {:cont, {:ok, [normalized | acc]}}
        else
          {:halt, {:error, :export_path_invalid}}
        end
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

  defp export_metadata(path, root) do
    %{path: Path.relative_to(path, root), bytes: tree_bytes(path)}
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
end
