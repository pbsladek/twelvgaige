defmodule Twelvgaige.Sandbox.Manager do
  @moduledoc "Coordinates admission, backend creation, start, cancellation, and cleanup."

  use GenServer

  alias Twelvgaige.Lifecycle.FaultMatrix
  alias Twelvgaige.Operations.Store, as: OperationsStore

  @proxy_environment_names ~w(HTTP_PROXY HTTPS_PROXY NO_PROXY)
  @completion_phases [:available, :intent_recorded, :quiesced, :exported]

  defstruct [
    :backend,
    :admission,
    :credential_broker,
    :egress_broker,
    :egress_boundary,
    :egress_boundary_backend,
    :operations_store,
    :recovery_opts,
    :fault_checkpoint_fun,
    resources: %{}
  ]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def launch(spec, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:launch, spec, opts}, :infinity)

  @doc "Creates an admitted sandbox and returns its attached stdio transport without starting it twice."
  def launch_attached(spec, opts \\ []),
    do:
      GenServer.call(
        Keyword.get(opts, :server, __MODULE__),
        {:launch_attached, spec, opts},
        :infinity
      )

  def cancel(resource_id, opts \\ []),
    do:
      GenServer.call(
        Keyword.get(opts, :server, __MODULE__),
        {:cancel, resource_id, opts},
        :infinity
      )

  @doc "Revokes external authority and stops the worker while retaining its result volume."
  def quiesce(resource_id, opts \\ []),
    do:
      GenServer.call(
        Keyword.get(opts, :server, __MODULE__),
        {:quiesce, resource_id, opts},
        :infinity
      )

  @doc "Exports a stopped attached worker's full workspace, then destroys its exact resources."
  def complete_workspace(resource_id, destination, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:complete_workspace, resource_id, destination, opts},
      :infinity
    )
  end

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
    state =
      %__MODULE__{
        backend: Keyword.get(opts, :backend, Twelvgaige.Sandbox.Backend.Podman),
        admission: Keyword.fetch!(opts, :admission),
        credential_broker: Keyword.get(opts, :credential_broker),
        egress_broker: Keyword.get(opts, :egress_broker),
        egress_boundary: Keyword.get(opts, :egress_boundary, Twelvgaige.Egress.Boundary),
        egress_boundary_backend: Keyword.get(opts, :egress_boundary_backend),
        operations_store: Keyword.get(opts, :operations_store),
        recovery_opts: Keyword.get(opts, :recovery_opts, []),
        fault_checkpoint_fun: Keyword.get(opts, :fault_checkpoint_fun)
      }

    with :ok <- recover_durable_resources(state), do: {:ok, state}
  end

  @impl true
  def handle_call({:launch, spec, opts}, _from, state) do
    reserve_and_launch(spec, opts, :started, state)
  end

  def handle_call({:launch_attached, spec, opts}, _from, state) do
    reserve_and_launch(spec, opts, :attached, state)
  end

  def handle_call({:cancel, resource_id, opts}, _from, state) do
    case Map.fetch(state.resources, resource_id) do
      {:ok, record} ->
        credential_result =
          sandbox_boundary(state, :credential_revoke, resource_id, fn ->
            revoke_credential(record, state)
          end)

        egress_result =
          sandbox_boundary(state, :egress_revoke, resource_id, fn ->
            revoke_egress(record, state)
          end)

        boundary_revoke_result =
          sandbox_boundary(state, :boundary_revoke, resource_id, fn ->
            revoke_boundary(record.egress_boundary, opts, state)
          end)

        stop_result =
          sandbox_boundary(state, :worker_stop, resource_id, fn ->
            state.backend.stop(resource_id, opts)
          end)

        destroy_result =
          sandbox_boundary(state, :worker_destroy, resource_id, fn ->
            state.backend.destroy(resource_id, opts)
          end)

        boundary_result =
          sandbox_boundary(state, :boundary_destroy, resource_id, fn ->
            destroy_boundary(record.egress_boundary, opts, state)
          end)

        release_result =
          if revoked?(credential_result) and revoked?(egress_result) and
               boundary_revoke_result == :ok and stop_result == :ok and destroy_result == :ok and
               boundary_result == :ok,
             do:
               sandbox_boundary(state, :admission_release, resource_id, fn ->
                 Twelvgaige.Sandbox.Admission.release(record.admission_lease_id,
                   server: state.admission
                 )
               end),
             else: :not_attempted

        durable_result =
          if release_result in [:ok, :already_released],
            do:
              sandbox_boundary(state, :resource_record_delete, resource_id, fn ->
                delete_resource(resource_id, state)
              end),
            else: :not_attempted

        result =
          case {credential_result, egress_result, boundary_revoke_result, stop_result,
                destroy_result, boundary_result, release_result, durable_result} do
            {credential, egress, :ok, :ok, :ok, :ok, admission, :ok}
            when credential in [:ok, :already_revoked] and egress in [:ok, :already_revoked] ->
              if admission in [:ok, :already_released], do: :ok, else: {:error, admission}

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

  def handle_call({:quiesce, resource_id, opts}, _from, state) do
    case Map.fetch(state.resources, resource_id) do
      {:ok, record} ->
        case quiesce_record(resource_id, record, opts, state) do
          {:ok, evidence, record} ->
            {:reply, {:ok, evidence}, put_in(state.resources[resource_id], record)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, :already_stopped, state}
    end
  end

  def handle_call({:complete_workspace, resource_id, destination, opts}, _from, state) do
    case Map.fetch(state.resources, resource_id) do
      {:ok, record} ->
        complete_workspace_resource(resource_id, destination, opts, record, state)

      :error ->
        {:reply, :already_stopped, state}
    end
  end

  def handle_call({:complete, resource_id, destination, declared_paths, opts}, _from, state) do
    case Map.fetch(state.resources, resource_id) do
      {:ok, record} ->
        complete_resource(resource_id, destination, declared_paths, opts, record, state)

      :error ->
        {:reply, {:error, :sandbox_resource_not_found}, state}
    end
  end

  defp reserve_and_launch(spec, opts, mode, state) do
    request = Map.get(spec, :reservation, %{})

    with :ok <- validate_result_destination_spec(spec, opts),
         {:ok, resource_id, admission_lease_id} <- preallocated_identities(spec, state),
         :ok <- persist_admission_intent(resource_id, spec, admission_lease_id, state) do
      reserve_opts =
        [server: state.admission]
        |> maybe_put(:lease_id, admission_lease_id)

      case sandbox_boundary(state, :admission_reserve, resource_id || "ephemeral", fn ->
             Twelvgaige.Sandbox.Admission.reserve(request, reserve_opts)
           end) do
        {:ok, reserved_lease_id} ->
          launch_reserved(spec, opts, reserved_lease_id, mode, state)

        {:error, reason} ->
          _ = delete_resource(resource_id, state)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp launch_reserved(spec, opts, admission_lease_id, mode, state) do
    launch_spec =
      spec
      |> Map.drop([
        :reservation,
        :egress_access_token,
        :egress_lease_id,
        :result_destination
      ])
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
              mode,
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

  defp create_reserved(spec, manifest, boundary, opts, admission_lease_id, mode, state) do
    with :ok <- validate_result_destination_spec(spec, opts),
         {:ok, pending_resource_id} <- persistent_resource_id(manifest, state),
         :ok <-
           persist_pending_resource(
             pending_resource_id,
             spec,
             manifest,
             boundary,
             admission_lease_id,
             state
           ) do
      create_persisted_resource(
        spec,
        manifest,
        boundary,
        opts,
        admission_lease_id,
        mode,
        pending_resource_id,
        state
      )
    else
      {:error, reason} ->
        _ = destroy_boundary(boundary, opts, state)
        cleanup_failed_launch(spec, admission_lease_id, state)
        {:reply, {:error, reason}, state}
    end
  end

  defp create_persisted_resource(
         spec,
         manifest,
         boundary,
         opts,
         admission_lease_id,
         mode,
         pending_resource_id,
         state
       ) do
    case state.backend.create(manifest, opts) do
      {:ok, resource_id, resource} ->
        if is_binary(pending_resource_id) and resource_id != pending_resource_id do
          _ = state.backend.destroy(resource_id, opts)
          _ = destroy_boundary(boundary, opts, state)
          _ = delete_resource(pending_resource_id, state)
          cleanup_failed_launch(spec, admission_lease_id, state)
          {:reply, {:error, :sandbox_resource_identity_mismatch}, state}
        else
          case mode do
            :started ->
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

            :attached ->
              attach_created(
                spec,
                manifest,
                resource_id,
                resource,
                boundary,
                opts,
                admission_lease_id,
                state
              )
          end
        end

      {:error, reason} ->
        _ = delete_resource(pending_resource_id, state)
        _ = destroy_boundary(boundary, opts, state)
        cleanup_failed_launch(spec, admission_lease_id, state)
        {:reply, {:error, reason}, state}
    end
  end

  defp attach_created(
         spec,
         manifest,
         resource_id,
         resource,
         boundary,
         opts,
         admission_lease_id,
         state
       ) do
    if function_exported?(state.backend, :stdio_transport, 2) do
      case state.backend.stdio_transport(resource_id, opts) do
        {:ok, transport} ->
          durable_manifest = Map.get(resource, :manifest, manifest)

          record =
            resource_record(
              spec,
              resource,
              durable_manifest,
              admission_lease_id,
              boundary,
              %{resource_id: resource_id, status: :attach_pending}
            )

          case persist_resource(resource_id, record, :attach_pending, state) do
            :ok ->
              {:reply, {:ok, resource_id, record, transport},
               put_in(state.resources[resource_id], record)}

            {:error, reason} ->
              cleanup_created_failure(
                spec,
                resource_id,
                boundary,
                opts,
                admission_lease_id,
                {:sandbox_resource_persistence_failed, reason},
                state
              )
          end

        {:error, reason} ->
          cleanup_created_failure(
            spec,
            resource_id,
            boundary,
            opts,
            admission_lease_id,
            reason,
            state
          )
      end
    else
      cleanup_created_failure(
        spec,
        resource_id,
        boundary,
        opts,
        admission_lease_id,
        :sandbox_attached_transport_unsupported,
        state
      )
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

        record =
          resource_record(
            spec,
            resource,
            durable_manifest,
            admission_lease_id,
            boundary,
            process
          )

        case persist_resource(resource_id, record, :running, state) do
          :ok ->
            {:reply, {:ok, resource_id, record}, put_in(state.resources[resource_id], record)}

          {:error, reason} ->
            cleanup_created_failure(
              spec,
              resource_id,
              boundary,
              opts,
              admission_lease_id,
              {:sandbox_resource_persistence_failed, reason},
              state
            )
        end

      {:error, reason} ->
        destroy_result = state.backend.destroy(resource_id, opts)
        boundary_result = destroy_boundary(boundary, opts, state)
        durable_result = delete_resource(resource_id, state)
        cleanup_failed_launch(spec, admission_lease_id, state)

        reply_reason =
          case {destroy_result, boundary_result, durable_result} do
            {:ok, :ok, :ok} -> reason
            cleanup -> {:sandbox_start_failed, reason, cleanup}
          end

        {:reply, {:error, reply_reason}, state}
    end
  end

  defp resource_record(spec, resource, manifest, admission_lease_id, boundary, process) do
    %{
      resource: resource,
      process: process,
      manifest: manifest,
      admission_lease_id: admission_lease_id,
      reservation: Map.get(spec, :reservation, %{}),
      credential_lease_id: Map.get(spec, :credential_lease_id),
      egress_lease_id: Map.get(spec, :egress_lease_id) || Map.get(spec, :proxy_lease_id),
      egress_boundary: boundary,
      completion: completion_from_spec(spec)
    }
  end

  defp cleanup_created_failure(
         spec,
         resource_id,
         boundary,
         opts,
         admission_lease_id,
         reason,
         state
       ) do
    destroy_result = state.backend.destroy(resource_id, opts)
    boundary_result = destroy_boundary(boundary, opts, state)
    durable_result = delete_resource(resource_id, state)
    cleanup_failed_launch(spec, admission_lease_id, state)

    reply_reason =
      case {destroy_result, boundary_result, durable_result} do
        {:ok, :ok, :ok} -> reason
        cleanup -> {:sandbox_attach_prepare_failed, reason, cleanup}
      end

    {:reply, {:error, reply_reason}, state}
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

    _ = delete_resource(Map.get(spec, :resource_id), state)

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

  defp prepare_proxy_manifest(%{network_mode: :broker_only} = spec) do
    Map.update(
      spec,
      :environment_names,
      @proxy_environment_names,
      &Enum.uniq(&1 ++ @proxy_environment_names)
    )
  end

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
    credential_result =
      sandbox_boundary(state, :credential_revoke, resource_id, fn ->
        revoke_credential(record, state)
      end)

    egress_result =
      sandbox_boundary(state, :egress_revoke, resource_id, fn ->
        revoke_egress(record, state)
      end)

    boundary_revoke_result =
      sandbox_boundary(state, :boundary_revoke, resource_id, fn ->
        revoke_boundary(record.egress_boundary, opts, state)
      end)

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
        do:
          sandbox_boundary(state, :worker_stop, resource_id, fn ->
            state.backend.stop(resource_id, opts)
          end),
        else: :not_attempted

    export_result =
      if stop_result == :ok do
        sandbox_boundary(state, :workspace_export, resource_id, fn ->
          export_resource(state.backend, resource_id, destination, declared_paths, export_opts)
        end)
      else
        :not_attempted
      end

    case {credential_result, egress_result, boundary_revoke_result, stop_result, export_result} do
      {credential, egress, :ok, :ok, {:ok, report}}
      when credential in [:ok, :already_revoked] and egress in [:ok, :already_revoked] ->
        with :ok <-
               sandbox_boundary(state, :boundary_destroy, resource_id, fn ->
                 destroy_boundary(record.egress_boundary, opts, state)
               end),
             :ok <-
               sandbox_boundary(state, :worker_destroy, resource_id, fn ->
                 state.backend.destroy(resource_id, opts)
               end),
             admission when admission in [:ok, :already_released] <-
               sandbox_boundary(state, :admission_release, resource_id, fn ->
                 Twelvgaige.Sandbox.Admission.release(record.admission_lease_id,
                   server: state.admission
                 )
               end),
             :ok <-
               sandbox_boundary(state, :resource_record_delete, resource_id, fn ->
                 delete_resource(resource_id, state)
               end) do
          {:reply, {:ok, report}, update_in(state.resources, &Map.delete(&1, resource_id))}
        else
          {:error, reason} ->
            {:reply, {:error, {:sandbox_cleanup_failed, reason}}, state}

          other ->
            {:reply, {:error, {:sandbox_cleanup_failed, other}}, state}
        end

      {_credential, _egress, _boundary, _stop, _export} = results ->
        {:reply, {:error, {:sandbox_finalize_failed, results}}, state}
    end
  end

  defp complete_workspace_resource(resource_id, destination, opts, record, state) do
    record = sync_durable_completion(resource_id, record, state)

    case run_workspace_completion(resource_id, destination, opts, record, state) do
      {:ok, report} ->
        {:reply, {:ok, report}, update_in(state.resources, &Map.delete(&1, resource_id))}

      {:error, reason} ->
        next_record = sync_durable_completion(resource_id, record, state)
        next_state = put_in(state.resources[resource_id], next_record)
        {:reply, {:error, {:sandbox_workspace_completion_failed, reason}}, next_state}
    end
  end

  defp run_workspace_completion(resource_id, destination, opts, record, state) do
    with true <-
           function_exported?(state.backend, :export_workspace, 3) or
             {:error, :sandbox_workspace_export_unsupported},
         {:ok, record} <- persist_completion_intent(resource_id, destination, opts, record, state),
         {:ok, quiescence, record} <- ensure_quiesced(resource_id, record, opts, state),
         {:ok, report, record} <- ensure_workspace_exported(resource_id, record, opts, state),
         :ok <- destroy_completed_resource(resource_id, record, opts, state) do
      {:ok, Map.put(report, :runtime_quiescence, quiescence)}
    else
      false -> {:error, :sandbox_workspace_export_unsupported}
      {:error, _reason} = error -> error
    end
  end

  defp persist_completion_intent(resource_id, destination, opts, record, state) do
    destination = Path.expand(destination)
    completion = Map.get(record, :completion)

    with :ok <- allowed_completion_destination(destination, opts),
         :ok <- durable_completion_bound(completion, state),
         :ok <- completion_destination_matches(completion, destination) do
      completion =
        (completion || %{})
        |> Map.merge(%{
          mode: :full_workspace,
          destination: destination,
          phase: max_completion_phase(completion, :intent_recorded),
          quiescence: completion_value(completion, :quiescence),
          export_report: completion_value(completion, :export_report)
        })

      record = Map.put(record, :completion, completion)

      with :ok <-
             sandbox_boundary(state, :completion_intent_persist, resource_id, fn ->
               persist_resource(resource_id, record, :completion_pending, state)
             end) do
        {:ok, record}
      end
    end
  end

  defp ensure_quiesced(resource_id, record, opts, state) do
    completion = Map.fetch!(record, :completion)

    if completion_phase_at_least?(completion.phase, :quiesced) do
      {:ok, completion.quiescence, record}
    else
      with {:ok, evidence, record} <- quiesce_record(resource_id, record, opts, state),
           completion <- %{completion | phase: :quiesced, quiescence: evidence},
           record <- Map.put(record, :completion, completion),
           :ok <-
             sandbox_boundary(state, :quiescence_persist, resource_id, fn ->
               persist_resource(resource_id, record, :completion_pending, state)
             end) do
        {:ok, evidence, record}
      end
    end
  end

  defp ensure_workspace_exported(resource_id, record, opts, state) do
    completion = Map.fetch!(record, :completion)

    if completion_phase_at_least?(completion.phase, :exported) do
      {:ok, completion.export_report || %{destination: completion.destination}, record}
    else
      export_opts =
        opts
        |> Keyword.put(:manifest, record.manifest)
        |> Keyword.put(:allowed_export_roots, [completion.destination])
        |> Keyword.put_new(
          :max_export_bytes,
          reservation_value(record.reservation, :workspace_bytes)
        )

      with {:ok, report} <-
             sandbox_boundary(state, :workspace_export, resource_id, fn ->
               state.backend.export_workspace(resource_id, completion.destination, export_opts)
             end),
           completion <- %{completion | phase: :exported, export_report: report},
           record <- Map.put(record, :completion, completion),
           :ok <-
             sandbox_boundary(state, :workspace_export_persist, resource_id, fn ->
               persist_resource(resource_id, record, :completion_pending, state)
             end) do
        {:ok, report, record}
      end
    end
  end

  defp destroy_completed_resource(resource_id, record, opts, state) do
    with :ok <-
           sandbox_boundary(state, :boundary_destroy, resource_id, fn ->
             destroy_boundary(record.egress_boundary, opts, state)
           end),
         :ok <-
           sandbox_boundary(state, :worker_destroy, resource_id, fn ->
             state.backend.destroy(resource_id, opts)
           end),
         admission when admission in [:ok, :already_released] <-
           sandbox_boundary(state, :admission_release, resource_id, fn ->
             Twelvgaige.Sandbox.Admission.release(record.admission_lease_id,
               server: state.admission
             )
           end),
         :ok <-
           sandbox_boundary(state, :resource_record_delete, resource_id, fn ->
             delete_resource(resource_id, state)
           end) do
      :ok
    else
      {:error, _reason} = error -> error
      other -> {:error, {:sandbox_cleanup_failed, other}}
    end
  end

  defp quiesce_record(
         resource_id,
         %{process: %{status: :stopped, stopped_at: stopped_at}} = record,
         _opts,
         _state
       ) do
    {:ok, %{runtime_stopped: true, runtime_identity: resource_id, stopped_at: stopped_at}, record}
  end

  defp quiesce_record(resource_id, record, opts, state) do
    credential_result =
      sandbox_boundary(state, :credential_revoke, resource_id, fn ->
        revoke_credential(record, state)
      end)

    egress_result =
      sandbox_boundary(state, :egress_revoke, resource_id, fn ->
        revoke_egress(record, state)
      end)

    boundary_result =
      sandbox_boundary(state, :boundary_revoke, resource_id, fn ->
        revoke_boundary(record.egress_boundary, opts, state)
      end)

    stop_result =
      if revoked?(credential_result) and revoked?(egress_result) and boundary_result == :ok,
        do:
          sandbox_boundary(state, :worker_stop, resource_id, fn ->
            state.backend.stop(resource_id, opts)
          end),
        else: :not_attempted

    case {credential_result, egress_result, boundary_result, stop_result} do
      {credential, egress, :ok, :ok}
      when credential in [:ok, :already_revoked] and egress in [:ok, :already_revoked] ->
        evidence = %{
          runtime_stopped: true,
          runtime_identity: resource_id,
          stopped_at: Twelvgaige.Clock.utc_now()
        }

        process = Map.merge(evidence, %{resource_id: resource_id, status: :stopped})
        {:ok, evidence, Map.put(record, :process, process)}

      results ->
        {:error, {:sandbox_quiescence_failed, results}}
    end
  end

  defp revoked?(result), do: result in [:ok, :already_revoked]

  defp persistent_resource_id(_manifest, %{operations_store: nil}), do: {:ok, nil}

  defp persistent_resource_id(manifest, _state) do
    case Map.get(manifest, :resource_id) do
      resource_id when is_binary(resource_id) and resource_id != "" -> {:ok, resource_id}
      _missing -> {:error, :sandbox_persistent_resource_id_required}
    end
  end

  defp persist_pending_resource(
         nil,
         _spec,
         _manifest,
         _boundary,
         _admission_lease_id,
         _state
       ),
       do: :ok

  defp persist_pending_resource(resource_id, spec, manifest, boundary, admission_lease_id, state) do
    record = %{
      manifest: manifest,
      admission_lease_id: admission_lease_id,
      reservation: Map.get(spec, :reservation, %{}),
      credential_lease_id: Map.get(spec, :credential_lease_id),
      egress_lease_id: Map.get(spec, :egress_lease_id) || Map.get(spec, :proxy_lease_id),
      egress_boundary: boundary,
      completion: completion_from_spec(spec)
    }

    sandbox_boundary(state, :creation_intent_persist, resource_id, fn ->
      persist_resource(resource_id, record, :creation_pending, state)
    end)
  end

  defp preallocated_identities(_spec, %{operations_store: nil}), do: {:ok, nil, nil}

  defp preallocated_identities(spec, _state) do
    case Map.get(spec, :resource_id) do
      resource_id when is_binary(resource_id) and resource_id != "" ->
        digest =
          :crypto.hash(:sha256, resource_id)
          |> Base.url_encode64(padding: false)
          |> binary_part(0, 24)

        {:ok, resource_id, "reservation_" <> digest}

      _missing ->
        {:error, :sandbox_persistent_resource_id_required}
    end
  end

  defp persist_admission_intent(nil, _spec, _admission_lease_id, _state), do: :ok

  defp persist_admission_intent(resource_id, spec, admission_lease_id, state) do
    record = %{
      manifest: nil,
      admission_lease_id: admission_lease_id,
      reservation: Map.get(spec, :reservation, %{}),
      credential_lease_id: Map.get(spec, :credential_lease_id),
      egress_lease_id: Map.get(spec, :egress_lease_id) || Map.get(spec, :proxy_lease_id),
      egress_boundary: nil,
      completion: completion_from_spec(spec)
    }

    sandbox_boundary(state, :resource_intent_persist, resource_id, fn ->
      persist_resource(resource_id, record, :admission_pending, state)
    end)
  end

  defp persist_resource(_resource_id, _record, _status, %{operations_store: nil}), do: :ok

  defp persist_resource(resource_id, record, status, state) do
    durable = %{
      schema_version: 2,
      resource_id: resource_id,
      status: status,
      manifest: Map.get(record, :manifest),
      reservation: Map.get(record, :reservation, %{}),
      admission_lease_id: Map.get(record, :admission_lease_id),
      credential_lease_id: Map.get(record, :credential_lease_id),
      egress_lease_id: Map.get(record, :egress_lease_id),
      egress_boundary: sanitize_boundary(Map.get(record, :egress_boundary)),
      completion: sanitize_completion(Map.get(record, :completion)),
      updated_at: Twelvgaige.Clock.utc_now()
    }

    OperationsStore.put(:sandbox_resource, resource_id, durable,
      server: state.operations_store,
      retention_class: :security
    )
  end

  defp delete_resource(_resource_id, %{operations_store: nil}), do: :ok
  defp delete_resource(nil, _state), do: :ok

  defp delete_resource(resource_id, state) do
    OperationsStore.delete(:sandbox_resource, resource_id, server: state.operations_store)
  end

  defp sanitize_boundary(nil), do: nil

  defp sanitize_boundary(boundary) when is_map(boundary) do
    boundary
    |> Map.put(:access_token, nil)
    |> Map.delete("access_token")
    |> Map.delete(:token)
    |> Map.delete("token")
  end

  defp completion_from_spec(spec) do
    case Map.get(spec, :result_destination) do
      destination when is_binary(destination) and destination != "" ->
        %{
          mode: :full_workspace,
          destination: Path.expand(destination),
          phase: :available,
          quiescence: nil,
          export_report: nil
        }

      _missing ->
        nil
    end
  end

  defp sanitize_completion(nil), do: nil

  defp sanitize_completion(completion) when is_map(completion) do
    %{
      mode: Map.get(completion, :mode),
      destination: Map.get(completion, :destination),
      phase: Map.get(completion, :phase),
      quiescence: sanitize_quiescence(Map.get(completion, :quiescence)),
      export_report: sanitize_export_report(Map.get(completion, :export_report))
    }
  end

  defp sanitize_quiescence(nil), do: nil

  defp sanitize_quiescence(evidence) when is_map(evidence) do
    Map.take(evidence, [:runtime_stopped, :runtime_identity, :stopped_at])
  end

  defp sanitize_export_report(nil), do: nil

  defp sanitize_export_report(report) when is_map(report) do
    Map.take(report, [:transport, :destination, :bytes, :entries, :files, :duration_ms])
  end

  defp validate_result_destination_spec(spec, opts) do
    if Map.has_key?(spec, :result_destination) do
      case Map.get(spec, :result_destination) do
        destination when is_binary(destination) and destination != "" ->
          allowed_completion_destination(Path.expand(destination), opts)

        _invalid ->
          {:error, :sandbox_result_destination_invalid}
      end
    else
      :ok
    end
  end

  defp allowed_completion_destination(destination, opts) do
    roots =
      opts
      |> Keyword.get(:allowed_export_roots, [destination])
      |> Enum.map(&Path.expand/1)

    if Enum.any?(roots, &(destination == &1 or String.starts_with?(destination, &1 <> "/"))),
      do: :ok,
      else: {:error, :export_destination_denied}
  end

  defp completion_destination_matches(nil, _destination), do: :ok

  defp completion_destination_matches(%{destination: destination}, destination), do: :ok

  defp completion_destination_matches(_completion, _destination),
    do: {:error, :sandbox_completion_destination_conflict}

  defp durable_completion_bound(nil, %{operations_store: store}) when not is_nil(store),
    do: {:error, :sandbox_completion_destination_not_bound}

  defp durable_completion_bound(_completion, _state), do: :ok

  defp completion_value(nil, _key), do: nil
  defp completion_value(completion, key), do: Map.get(completion, key)

  defp max_completion_phase(nil, minimum), do: minimum

  defp max_completion_phase(%{phase: current}, minimum) do
    if completion_phase_at_least?(current, minimum), do: current, else: minimum
  end

  defp completion_phase_at_least?(phase, minimum) do
    phase_index = Enum.find_index(@completion_phases, &(&1 == phase))
    minimum_index = Enum.find_index(@completion_phases, &(&1 == minimum))
    is_integer(phase_index) and phase_index >= minimum_index
  end

  defp sync_durable_completion(_resource_id, record, %{operations_store: nil}), do: record

  defp sync_durable_completion(resource_id, record, state) do
    case OperationsStore.get(:sandbox_resource, resource_id, server: state.operations_store) do
      {:ok, %{value: %{schema_version: 2} = durable}} ->
        Map.put(record, :completion, Map.get(durable, :completion))

      _missing_or_legacy ->
        record
    end
  end

  defp recover_durable_resources(%{operations_store: nil}), do: :ok

  defp recover_durable_resources(state) do
    with {:ok, records} <- OperationsStore.list(:sandbox_resource, server: state.operations_store) do
      Enum.reduce_while(records, :ok, fn stored, :ok ->
        case cleanup_durable_resource(stored.key, stored.value, state) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp cleanup_durable_resource(
         resource_id,
         %{schema_version: 2, resource_id: resource_id, status: :admission_pending} = record,
         state
       ) do
    cleanup_admission_intent(resource_id, record, state)
  end

  defp cleanup_durable_resource(
         resource_id,
         %{
           schema_version: 2,
           resource_id: resource_id,
           status: status,
           completion: %{mode: :full_workspace, destination: destination} = completion
         } = record,
         state
       )
       when status != :creation_pending and is_binary(destination) and destination != "" do
    if completion_phase_at_least?(Map.get(completion, :phase), :available) do
      case run_workspace_completion(resource_id, destination, state.recovery_opts, record, state) do
        {:ok, _report} -> :ok
        {:error, reason} -> {:error, {:sandbox_restart_completion_failed, resource_id, reason}}
      end
    else
      {:error, {:sandbox_durable_completion_invalid, resource_id}}
    end
  end

  defp cleanup_durable_resource(
         resource_id,
         %{schema_version: 2, resource_id: resource_id} = record,
         state
       ) do
    cleanup_durable_resource_v1(resource_id, record, state)
  end

  defp cleanup_durable_resource(
         resource_id,
         %{schema_version: 1, resource_id: resource_id} = record,
         state
       ) do
    cleanup_durable_resource_v1(resource_id, record, state)
  end

  defp cleanup_durable_resource(resource_id, _record, _state),
    do: {:error, {:sandbox_durable_record_invalid, resource_id}}

  defp cleanup_durable_resource_v1(resource_id, record, state) do
    credential_result =
      sandbox_boundary(state, :credential_revoke, resource_id, fn ->
        revoke_credential(record, state)
      end)

    egress_result =
      sandbox_boundary(state, :egress_revoke, resource_id, fn ->
        revoke_egress(record, state)
      end)

    boundary_revoke_result =
      sandbox_boundary(state, :boundary_revoke, resource_id, fn ->
        revoke_boundary(Map.get(record, :egress_boundary), state.recovery_opts, state)
      end)

    destroy_result =
      sandbox_boundary(state, :worker_destroy, resource_id, fn ->
        state.backend.destroy(resource_id, state.recovery_opts)
      end)

    boundary_result =
      sandbox_boundary(state, :boundary_destroy, resource_id, fn ->
        destroy_boundary(Map.get(record, :egress_boundary), state.recovery_opts, state)
      end)

    admission_result =
      sandbox_boundary(state, :admission_release, resource_id, fn ->
        case Map.get(record, :admission_lease_id) do
          lease_id when is_binary(lease_id) ->
            Twelvgaige.Sandbox.Admission.release(lease_id, server: state.admission)

          _missing ->
            :already_released
        end
      end)

    case {credential_result, egress_result, boundary_revoke_result, destroy_result,
          boundary_result, admission_result} do
      {credential, egress, :ok, :ok, :ok, admission}
      when credential in [:ok, :already_revoked] and egress in [:ok, :already_revoked] and
             admission in [:ok, :already_released] ->
        sandbox_boundary(state, :resource_record_delete, resource_id, fn ->
          delete_resource(resource_id, state)
        end)

      results ->
        {:error, {:sandbox_restart_cleanup_failed, resource_id, results}}
    end
  end

  defp cleanup_admission_intent(resource_id, record, state) do
    credential_result =
      sandbox_boundary(state, :credential_revoke, resource_id, fn ->
        revoke_credential(record, state)
      end)

    egress_result =
      sandbox_boundary(state, :egress_revoke, resource_id, fn ->
        revoke_egress(record, state)
      end)

    admission_result =
      sandbox_boundary(state, :admission_release, resource_id, fn ->
        Twelvgaige.Sandbox.Admission.release(record.admission_lease_id,
          server: state.admission
        )
      end)

    case {credential_result, egress_result, admission_result} do
      {credential, egress, admission}
      when credential in [:ok, :already_revoked] and egress in [:ok, :already_revoked] and
             admission in [:ok, :already_released] ->
        sandbox_boundary(state, :resource_record_delete, resource_id, fn ->
          delete_resource(resource_id, state)
        end)

      results ->
        {:error, {:sandbox_restart_admission_cleanup_failed, resource_id, results}}
    end
  end

  defp sandbox_boundary(state, boundary, resource_id, fun) do
    FaultMatrix.around(
      [fault_checkpoint_fun: state.fault_checkpoint_fun],
      :sandbox_resource_cleanup,
      boundary,
      %{resource_id: resource_id},
      fun
    )
  end

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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
