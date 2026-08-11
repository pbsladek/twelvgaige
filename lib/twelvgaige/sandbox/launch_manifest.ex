defmodule Twelvgaige.Sandbox.LaunchManifest do
  @moduledoc "Versioned, secret-free outer sandbox launch identity and attestation policy."

  @profiles [:analysis_only, :coding_restricted, :coding_unrestricted_network, :integration_test]
  @network_modes [:none, :broker_only, :unrestricted]
  @forbidden_mount_fragments [
    "/.ssh",
    "/.aws",
    "/.config/gcloud",
    "docker.sock",
    "podman.sock",
    "container-apiserver",
    "breech",
    ".erlang.cookie"
  ]

  @enforce_keys [
    :backend,
    :backend_version,
    :profile,
    :image_reference,
    :image_digest,
    :workspace_transport,
    :mounts,
    :network_mode,
    :limits,
    :deadline,
    :policy_revision,
    :created_at
  ]
  defstruct [
    :backend,
    :backend_version,
    :profile,
    :resource_id,
    :machine_id,
    :image_reference,
    :image_digest,
    :workspace_transport,
    :mounts,
    :network_mode,
    :allowed_destinations,
    :proxy_lease_id,
    :limits,
    :deadline,
    :credential_lease_id,
    :policy_revision,
    :created_at,
    :started_at,
    :observed_state,
    :manifest_digest,
    capabilities: %{},
    uid: 65_532,
    gid: 65_532,
    rootfs_mode: :read_only,
    dropped_capabilities: ["ALL"],
    security_options: ["no-new-privileges"],
    environment_names: [],
    labels: %{},
    schema_version: 1,
    encoding_version: 1
  ]

  @type t :: %__MODULE__{}

  def new(attrs, opts \\ []) do
    manifest = struct!(__MODULE__, Map.new(attrs))

    with :ok <- validate_profile(manifest),
         :ok <- validate_image(manifest),
         {:ok, mounts} <-
           canonicalize_mounts(manifest.mounts, Keyword.fetch!(opts, :allowed_roots)),
         :ok <- validate_network(manifest, opts),
         :ok <- validate_limits(manifest.limits),
         :ok <- validate_environment_names(manifest.environment_names) do
      manifest = %{manifest | mounts: mounts}
      {:ok, %{manifest | manifest_digest: digest(manifest)}}
    end
  end

  @doc "Binds an approved launch manifest to its allocated runtime identity and reseals it."
  def bind_resource(%__MODULE__{} = manifest, resource_id, opts \\ [])
      when is_binary(resource_id) and resource_id != "" do
    machine_id = Keyword.get(opts, :machine_id, manifest.machine_id)

    labels =
      manifest.labels
      |> Map.merge(%{
        "io.twelvgaige.managed" => "true",
        "io.twelvgaige.resource" => resource_id
      })
      |> Map.delete("io.twelvgaige.manifest")

    bound = %{manifest | resource_id: resource_id, machine_id: machine_id, labels: labels}
    digest = digest(bound)

    %{
      bound
      | manifest_digest: digest,
        labels: Map.put(labels, "io.twelvgaige.manifest", digest)
    }
  end

  def attest(%__MODULE__{} = manifest, observed) do
    expected =
      %{
        image_digest: manifest.image_digest,
        mounts: expected_runtime_mounts(manifest),
        uid: manifest.uid,
        gid: manifest.gid,
        rootfs_mode: manifest.rootfs_mode,
        dropped_capabilities: Enum.sort(manifest.dropped_capabilities),
        security_options: Enum.sort(manifest.security_options),
        network_mode: manifest.network_mode,
        limits: manifest.limits,
        environment_names: Enum.sort(manifest.environment_names),
        labels: manifest.labels
      }
      |> maybe_put_vm_identity(manifest)

    actual =
      %{
        image_digest: value(observed, :image_digest),
        mounts: normalize_mount_evidence(value(observed, :mounts, [])),
        uid: value(observed, :uid),
        gid: value(observed, :gid),
        rootfs_mode: value(observed, :rootfs_mode),
        dropped_capabilities: value(observed, :dropped_capabilities, []) |> Enum.sort(),
        security_options: value(observed, :security_options, []) |> Enum.sort(),
        network_mode: value(observed, :network_mode),
        limits: value(observed, :limits),
        environment_names: value(observed, :environment_names, []) |> Enum.sort(),
        labels: value(observed, :labels, %{})
      }
      |> maybe_put_observed_vm_identity(manifest, observed)

    drift = for {key, expected_value} <- expected, actual[key] != expected_value, do: key
    if drift == [], do: :ok, else: {:error, {:sandbox_attestation_failed, Enum.sort(drift)}}
  end

  @doc "Returns the mounts that the runtime must attest after transport expansion."
  def runtime_mounts(%__MODULE__{} = manifest), do: expected_runtime_mounts(manifest)

  defp validate_profile(manifest) do
    cond do
      manifest.profile not in @profiles ->
        {:error, :unsupported_sandbox_profile}

      manifest.rootfs_mode != :read_only ->
        {:error, :rootfs_must_be_read_only}

      "ALL" not in manifest.dropped_capabilities ->
        {:error, :capabilities_must_drop_all}

      not valid_security_boundary?(manifest) ->
        {:error, :sandbox_security_boundary_required}

      manifest.uid == 0 or manifest.gid == 0 ->
        {:error, :root_user_denied}

      true ->
        :ok
    end
  end

  defp validate_image(%{image_digest: "sha256:" <> digest}) do
    if Regex.match?(~r/^[0-9a-f]{64}$/, digest), do: :ok, else: {:error, :invalid_image_digest}
  end

  defp validate_image(_manifest), do: {:error, :image_digest_required}

  # Podman relies on the Linux no-new-privileges process bit. Apple's backend
  # does not currently expose that OCI field; its outer authority is instead a
  # distinct lightweight VM for every worker. Keeping these as separate,
  # attestable contracts avoids claiming a protection the runtime cannot prove.
  defp valid_security_boundary?(%{backend: :apple_container} = manifest) do
    manifest.security_options == [] and capability?(manifest.capabilities, :vm_per_session)
  end

  defp valid_security_boundary?(manifest),
    do: "no-new-privileges" in manifest.security_options

  defp capability?(capabilities, key) when is_map(capabilities),
    do: Map.get(capabilities, key, Map.get(capabilities, Atom.to_string(key), false)) == true

  defp capability?(_capabilities, _key), do: false

  defp canonicalize_mounts(mounts, allowed_roots) do
    Enum.reduce_while(mounts, {:ok, []}, fn mount, {:ok, acc} ->
      source = value(mount, :source) |> Path.expand()
      destination = value(mount, :destination)

      with :ok <- allowed_source(source, allowed_roots),
           :ok <- reject_forbidden(source),
           :ok <- reject_symlink_components(source, allowed_roots),
           :ok <- validate_destination(destination) do
        normalized = %{
          source: source,
          destination: destination,
          mode: value(mount, :mode, :read_only)
        }

        {:cont, {:ok, [normalized | acc]}}
      else
        {:error, reason} -> {:halt, {:error, {:mount_denied, source, reason}}}
      end
    end)
    |> case do
      {:ok, mounts} -> {:ok, Enum.sort_by(mounts, & &1.destination)}
      {:error, _reason} = error -> error
    end
  end

  defp allowed_source(source, roots) do
    if Enum.any?(roots, &under_root?(source, Path.expand(&1))),
      do: :ok,
      else: {:error, :outside_owned_roots}
  end

  defp under_root?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp reject_forbidden(path) do
    if Enum.any?(@forbidden_mount_fragments, &String.contains?(path, &1)),
      do: {:error, :forbidden_mount},
      else: :ok
  end

  defp reject_symlink_components(path, allowed_roots) do
    root =
      allowed_roots
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&under_root?(path, &1))
      |> Enum.max_by(&byte_size/1)

    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while(root, fn component, current ->
      next = Path.join(current, component)

      case File.lstat(next) do
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, :symlink_component}}
        {:ok, _stat} -> {:cont, next}
        {:error, :enoent} -> {:cont, next}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:error, _reason} = error -> error
      _path -> :ok
    end
  end

  defp validate_destination("/workspace"), do: :ok
  defp validate_destination("/artifacts"), do: :ok
  defp validate_destination("/run/codex-home"), do: :ok
  defp validate_destination(_destination), do: {:error, :destination_not_allowed}

  defp validate_network(manifest, opts) do
    cond do
      manifest.network_mode not in @network_modes ->
        {:error, :unsupported_network_mode}

      manifest.network_mode == :unrestricted and
          not Keyword.get(opts, :allow_unrestricted?, false) ->
        {:error, :unrestricted_network_requires_explicit_flag}

      manifest.network_mode == :broker_only and is_nil(manifest.proxy_lease_id) ->
        {:error, :proxy_lease_required}

      true ->
        :ok
    end
  end

  defp validate_limits(limits) when is_map(limits) do
    required = [:cpu, :memory_bytes, :pids]

    if Enum.all?(required, &(is_integer(value(limits, &1)) and value(limits, &1) > 0)),
      do: :ok,
      else: {:error, :sandbox_limits_required}
  end

  defp validate_limits(_limits), do: {:error, :sandbox_limits_required}

  defp validate_environment_names(names) do
    if Enum.all?(names, &(is_binary(&1) and not secret_name?(&1))),
      do: :ok,
      else: {:error, :secret_environment_name_denied}
  end

  defp secret_name?(name),
    do: String.match?(String.upcase(name), ~r/(TOKEN|SECRET|PASSWORD|API_KEY|CREDENTIAL)/)

  defp normalize_mount_evidence(mounts) do
    mounts
    |> Enum.map(fn mount ->
      %{
        source: normalized_mount_source(mount),
        destination: value(mount, :destination),
        mode: value(mount, :mode),
        type: normalize_mount_type(value(mount, :type, :bind))
      }
    end)
    |> Enum.sort_by(& &1.destination)
  end

  defp expected_runtime_mounts(%{workspace_transport: :copy_snapshot, mounts: mounts}) do
    mounts
    |> Enum.map(fn mount ->
      %{
        source: :sandbox_owned,
        destination: value(mount, :destination),
        mode: value(mount, :mode),
        type: :volume
      }
    end)
    |> Enum.sort_by(& &1.destination)
  end

  defp expected_runtime_mounts(manifest), do: normalize_mount_evidence(manifest.mounts)

  defp normalized_mount_source(mount) do
    case normalize_mount_type(value(mount, :type, :bind)) do
      type when type in [:volume, :tmpfs] -> :sandbox_owned
      :bind -> value(mount, :source) |> Path.expand()
    end
  end

  defp normalize_mount_type(type) when type in [:bind, "bind"], do: :bind
  defp normalize_mount_type(type) when type in [:volume, "volume"], do: :volume
  defp normalize_mount_type(type) when type in [:tmpfs, "tmpfs"], do: :tmpfs
  defp normalize_mount_type(%{"volume" => _details}), do: :volume
  defp normalize_mount_type(%{"virtiofs" => _details}), do: :bind
  defp normalize_mount_type(%{volume: _details}), do: :volume
  defp normalize_mount_type(%{virtiofs: _details}), do: :bind
  defp normalize_mount_type(_type), do: :bind

  defp digest(manifest) do
    manifest
    |> Map.from_struct()
    |> Map.put(:manifest_digest, nil)
    |> Map.update!(:labels, &Map.delete(&1, "io.twelvgaige.manifest"))
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp maybe_put_vm_identity(expected, %{backend: :apple_container, machine_id: machine_id})
       when is_binary(machine_id) and machine_id != "",
       do: Map.put(expected, :machine_id, machine_id)

  defp maybe_put_vm_identity(expected, _manifest), do: expected

  defp maybe_put_observed_vm_identity(
         actual,
         %{backend: :apple_container, machine_id: machine_id},
         observed
       )
       when is_binary(machine_id) and machine_id != "",
       do: Map.put(actual, :machine_id, value(observed, :machine_id))

  defp maybe_put_observed_vm_identity(actual, _manifest, _observed), do: actual

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
