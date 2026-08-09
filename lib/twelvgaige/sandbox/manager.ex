defmodule Twelvgaige.Sandbox.Manager do
  @moduledoc "Coordinates admission, backend creation, start, cancellation, and cleanup."

  use GenServer

  @proxy_environment_names ~w(HTTP_PROXY HTTPS_PROXY NO_PROXY)

  defstruct [
    :backend,
    :admission,
    :credential_broker,
    :egress_broker,
    :egress_boundary,
    :egress_boundary_backend,
    resources: %{}
  ]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def launch(spec, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:launch, spec, opts}, :infinity)

  def cancel(resource_id, opts \\ []),
    do:
      GenServer.call(
        Keyword.get(opts, :server, __MODULE__),
        {:cancel, resource_id, opts},
        :infinity
      )

  def complete(resource_id, destination, declared_paths, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:complete, resource_id, destination, declared_paths, opts},
      :infinity
    )
  end

  def get(resource_id, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:get, resource_id})

  @impl true
  def init(opts) do
    {:ok,
     %__MODULE__{
       backend: Keyword.get(opts, :backend, Twelvgaige.Sandbox.Backend.Podman),
       admission: Keyword.fetch!(opts, :admission),
       credential_broker: Keyword.get(opts, :credential_broker),
       egress_broker: Keyword.get(opts, :egress_broker),
       egress_boundary: Keyword.get(opts, :egress_boundary, Twelvgaige.Egress.Boundary),
       egress_boundary_backend: Keyword.get(opts, :egress_boundary_backend)
     }}
  end

  @impl true
  def handle_call({:launch, spec, opts}, _from, state) do
    request = Map.get(spec, :reservation, %{})

    case Twelvgaige.Sandbox.Admission.reserve(request, server: state.admission) do
      {:ok, admission_lease_id} ->
        launch_reserved(spec, opts, admission_lease_id, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:cancel, resource_id, opts}, _from, state) do
    case Map.fetch(state.resources, resource_id) do
      {:ok, record} ->
        credential_result = revoke_credential(record, state)
        egress_result = revoke_egress(record, state)
        boundary_revoke_result = revoke_boundary(record.egress_boundary, opts, state)
        stop_result = state.backend.stop(resource_id, opts)
        destroy_result = state.backend.destroy(resource_id, opts)
        boundary_result = destroy_boundary(record.egress_boundary, opts, state)

        result =
          case {credential_result, egress_result, boundary_revoke_result, stop_result,
                destroy_result, boundary_result} do
            {credential, egress, :ok, :ok, :ok, :ok}
            when credential in [:ok, :already_revoked] and egress in [:ok, :already_revoked] ->
              _ =
                Twelvgaige.Sandbox.Admission.release(record.admission_lease_id,
                  server: state.admission
                )

              :ok

            other ->
              {:error, {:sandbox_cleanup_failed, other}}
          end

        next =
          if result == :ok,
            do: update_in(state.resources, &Map.delete(&1, resource_id)),
            else: state

        {:reply, result, next}

      :error ->
        {:reply, :already_stopped, state}
    end
  end

  def handle_call({:get, resource_id}, _from, state),
    do: {:reply, Map.fetch(state.resources, resource_id), state}

  def handle_call({:complete, resource_id, destination, declared_paths, opts}, _from, state) do
    case Map.fetch(state.resources, resource_id) do
      {:ok, record} ->
        complete_resource(resource_id, destination, declared_paths, opts, record, state)

      :error ->
        {:reply, {:error, :sandbox_resource_not_found}, state}
    end
  end

  defp launch_reserved(spec, opts, admission_lease_id, state) do
    launch_spec =
      spec
      |> Map.drop([:reservation, :egress_access_token])
      |> prepare_proxy_manifest()

    opts = resource_limit_opts(spec, opts)

    case state.backend.prepare(launch_spec, opts) do
      {:ok, manifest} ->
        case provision_boundary(spec, manifest, opts, state) do
          {:ok, boundary, launch_opts} ->
            create_reserved(
              spec,
              manifest,
              boundary,
              launch_opts,
              admission_lease_id,
              state
            )

          {:error, reason} ->
            cleanup_failed_launch(spec, admission_lease_id, state)
            {:reply, {:error, reason}, state}
        end

      {:error, reason} ->
        cleanup_failed_launch(spec, admission_lease_id, state)
        {:reply, {:error, reason}, state}
    end
  end

  defp create_reserved(spec, manifest, boundary, opts, admission_lease_id, state) do
    case state.backend.create(manifest, opts) do
      {:ok, resource_id, resource} ->
        start_created(
          spec,
          manifest,
          resource_id,
          resource,
          boundary,
          opts,
          admission_lease_id,
          state
        )

      {:error, reason} ->
        _ = destroy_boundary(boundary, opts, state)
        cleanup_failed_launch(spec, admission_lease_id, state)
        {:reply, {:error, reason}, state}
    end
  end

  defp start_created(
         spec,
         manifest,
         resource_id,
         resource,
         boundary,
         opts,
         admission_lease_id,
         state
       ) do
    case state.backend.start(resource_id, opts) do
      {:ok, process} ->
        durable_manifest = Map.get(resource, :manifest, manifest)

        record = %{
          resource: resource,
          process: process,
          manifest: durable_manifest,
          admission_lease_id: admission_lease_id,
          reservation: Map.get(spec, :reservation, %{}),
          credential_lease_id: Map.get(spec, :credential_lease_id),
          egress_lease_id: Map.get(spec, :egress_lease_id) || Map.get(spec, :proxy_lease_id),
          egress_boundary: boundary
        }

        {:reply, {:ok, resource_id, record}, put_in(state.resources[resource_id], record)}

      {:error, reason} ->
        destroy_result = state.backend.destroy(resource_id, opts)
        boundary_result = destroy_boundary(boundary, opts, state)
        cleanup_failed_launch(spec, admission_lease_id, state)

        reply_reason =
          case {destroy_result, boundary_result} do
            {:ok, :ok} -> reason
            cleanup -> {:sandbox_start_failed, reason, cleanup}
          end

        {:reply, {:error, reply_reason}, state}
    end
  end

  defp cleanup_failed_launch(spec, admission_lease_id, state) do
    _ =
      Twelvgaige.Sandbox.Admission.release(admission_lease_id, server: state.admission)

    _ =
      revoke_credential(%{credential_lease_id: Map.get(spec, :credential_lease_id)}, state)

    _ =
      revoke_egress(
        %{egress_lease_id: Map.get(spec, :egress_lease_id) || Map.get(spec, :proxy_lease_id)},
        state
      )

    :ok
  end

  defp revoke_credential(%{credential_lease_id: nil}, _state), do: :ok
  defp revoke_credential(_record, %{credential_broker: nil}), do: :ok

  defp revoke_credential(record, state) do
    Twelvgaige.Credential.Broker.revoke(record.credential_lease_id,
      server: state.credential_broker
    )
  end

  defp revoke_egress(%{egress_lease_id: nil}, _state), do: :ok
  defp revoke_egress(_record, %{egress_broker: nil}), do: :ok

  defp revoke_egress(record, state) do
    Twelvgaige.Egress.Broker.revoke(record.egress_lease_id, server: state.egress_broker)
  end

  defp prepare_proxy_manifest(%{network_mode: :broker_only} = spec),
    do: Map.put(spec, :environment_names, @proxy_environment_names)

  defp prepare_proxy_manifest(spec), do: Map.put_new(spec, :environment_names, [])

  defp provision_boundary(spec, manifest, opts, state) do
    if Map.get(manifest, :network_mode) == :broker_only do
      provision_broker_boundary(spec, opts, state)
    else
      {:ok, nil, opts}
    end
  end

  defp provision_broker_boundary(spec, opts, state) do
    lease_id = Map.get(spec, :egress_lease_id) || Map.get(spec, :proxy_lease_id)
    token = Map.get(spec, :egress_access_token)

    with broker when not is_nil(broker) <- state.egress_broker,
         boundary_module when not is_nil(boundary_module) <- state.egress_boundary,
         lease_id when is_binary(lease_id) and lease_id != "" <- lease_id,
         token when is_binary(token) and token != "" <- token,
         {:ok, lease} <-
           Twelvgaige.Egress.Broker.materialize(lease_id, token, server: broker),
         {:ok, backend} <- boundary_backend(state.backend, state.egress_boundary_backend),
         {:ok, boundary_opts} <- boundary_options(opts),
         {:ok, boundary} <- boundary_module.provision(backend, lease, boundary_opts),
         worker_opts when is_list(worker_opts) <- boundary_module.worker_options(boundary) do
      {:ok, boundary, Keyword.merge(opts, worker_opts)}
    else
      nil -> {:error, :egress_boundary_not_configured}
      false -> {:error, :egress_boundary_credentials_required}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :egress_boundary_credentials_required}
    end
  end

  defp boundary_backend(_backend, override) when override in [:podman, :apple_container],
    do: {:ok, override}

  defp boundary_backend(Twelvgaige.Sandbox.Backend.Podman, nil), do: {:ok, :podman}

  defp boundary_backend(Twelvgaige.Sandbox.Backend.AppleContainer, nil),
    do: {:ok, :apple_container}

  defp boundary_backend(_backend, _override),
    do: {:error, :egress_boundary_backend_unsupported}

  defp boundary_options(opts) do
    with reference when is_binary(reference) <- Keyword.get(opts, :egress_image_reference),
         digest when is_binary(digest) <- Keyword.get(opts, :egress_image_digest),
         root when is_binary(root) <- Keyword.get(opts, :egress_runtime_root) do
      boundary_opts =
        opts
        |> Keyword.put(:image_reference, reference)
        |> Keyword.put(:image_digest, digest)
        |> Keyword.put(:runtime_root, root)

      {:ok, boundary_opts}
    else
      _other -> {:error, :egress_boundary_runtime_options_required}
    end
  end

  defp destroy_boundary(nil, _opts, _state), do: :ok
  defp destroy_boundary(_boundary, _opts, %{egress_boundary: nil}), do: :ok

  defp destroy_boundary(boundary, opts, state),
    do: state.egress_boundary.destroy(boundary, opts)

  defp revoke_boundary(nil, _opts, _state), do: :ok
  defp revoke_boundary(_boundary, _opts, %{egress_boundary: nil}), do: :ok

  defp revoke_boundary(boundary, opts, state),
    do: state.egress_boundary.revoke(boundary, opts)

  defp complete_resource(resource_id, destination, declared_paths, opts, record, state) do
    credential_result = revoke_credential(record, state)
    egress_result = revoke_egress(record, state)
    boundary_revoke_result = revoke_boundary(record.egress_boundary, opts, state)

    export_opts =
      opts
      |> Keyword.put(:manifest, record.manifest)
      |> Keyword.put_new(:allowed_export_roots, [destination])
      |> Keyword.put_new(
        :max_export_bytes,
        reservation_value(record.reservation, :workspace_bytes)
      )

    # Revoke external authority and stop the worker before opening the trusted
    # export path. A stopped sandbox provides a stable snapshot and prevents an
    # untrusted process from racing validation or learning about the staging
    # mount used by backends such as Apple container.
    stop_result =
      if revoked?(credential_result) and revoked?(egress_result) and boundary_revoke_result == :ok,
        do: state.backend.stop(resource_id, opts),
        else: :not_attempted

    export_result =
      if stop_result == :ok do
        export_resource(state.backend, resource_id, destination, declared_paths, export_opts)
      else
        :not_attempted
      end

    case {credential_result, egress_result, boundary_revoke_result, stop_result, export_result} do
      {credential, egress, :ok, :ok, {:ok, report}}
      when credential in [:ok, :already_revoked] and egress in [:ok, :already_revoked] ->
        with :ok <- state.backend.destroy(resource_id, opts),
             :ok <- destroy_boundary(record.egress_boundary, opts, state) do
          _ =
            Twelvgaige.Sandbox.Admission.release(record.admission_lease_id,
              server: state.admission
            )

          {:reply, {:ok, report}, update_in(state.resources, &Map.delete(&1, resource_id))}
        else
          {:error, reason} ->
            {:reply, {:error, {:sandbox_cleanup_failed, reason}}, state}
        end

      {_credential, _egress, _boundary, _stop, _export} = results ->
        {:reply, {:error, {:sandbox_finalize_failed, results}}, state}
    end
  end

  defp revoked?(result), do: result in [:ok, :already_revoked]

  defp export_resource(backend, resource_id, destination, declared_paths, opts) do
    manifest = Keyword.fetch!(opts, :manifest)

    cond do
      manifest.workspace_transport == :bind_worktree ->
        {:ok, %{transport: :bind_worktree, exported: [], destination: destination}}

      function_exported?(backend, :export, 4) ->
        backend.export(resource_id, destination, declared_paths, opts)

      true ->
        {:error, :sandbox_export_unsupported}
    end
  end

  defp reservation_value(reservation, key) when is_map(reservation),
    do: Map.get(reservation, key, Map.get(reservation, Atom.to_string(key)))

  defp reservation_value(_reservation, _key), do: nil

  defp resource_limit_opts(spec, opts) do
    reservation = Map.get(spec, :reservation, %{})

    opts
    |> put_positive_new(:workspace_volume_bytes, reservation_value(reservation, :workspace_bytes))
    |> put_positive_new(:artifact_volume_bytes, reservation_value(reservation, :artifact_bytes))
  end

  defp put_positive_new(opts, key, value) when is_integer(value) and value > 0,
    do: Keyword.put_new(opts, key, value)

  defp put_positive_new(opts, _key, _value), do: opts
end
