defmodule Twelvgaige.DelegatedSession.Controller do
  @moduledoc "Owns one delegated session, its bounded event ingress, and typed lifecycle."

  use GenServer

  alias Twelvgaige.DelegatedSession
  alias Twelvgaige.DelegatedSession.Event
  alias Twelvgaige.Event.Buffer
  alias Twelvgaige.Operations.SessionControl
  alias Twelvgaige.Sandbox.Manager, as: SandboxManager

  defstruct [
    :session,
    :adapter,
    :adapter_handle,
    :sandbox_backend,
    :sandbox_manager,
    :sandbox_resource_id,
    :sandbox_launch_spec,
    :sandbox_opts,
    :runtime_command,
    :result_destination,
    :adapter_config,
    :session_control,
    buffer: nil,
    events: [],
    dedupe: MapSet.new(),
    session_registered?: false
  ]

  def start_link(opts) do
    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def start(server), do: GenServer.call(server, :start, :infinity)
  def ingest(server, event), do: GenServer.call(server, {:ingest, event})
  def drain(server, limit \\ 100), do: GenServer.call(server, {:drain, limit})
  def poll(server, limit \\ 100), do: GenServer.call(server, {:poll, limit}, :infinity)

  def decide(server, approval_id, receipt),
    do: GenServer.call(server, {:decide, approval_id, receipt}, :infinity)

  def cancel(server, reason), do: GenServer.call(server, {:cancel, reason}, :infinity)
  def reconcile(server, durable), do: GenServer.call(server, {:reconcile, durable}, :infinity)
  def finalize(server), do: GenServer.call(server, :finalize, :infinity)
  def snapshot(server), do: GenServer.call(server, :snapshot)

  @impl true
  def init(opts) do
    state =
      %__MODULE__{
        session: Keyword.fetch!(opts, :session),
        adapter: Keyword.get(opts, :adapter, Twelvgaige.DelegatedSession.Adapter.Mock),
        sandbox_backend: Keyword.get(opts, :sandbox_backend, Twelvgaige.Sandbox.Backend.Mock),
        sandbox_manager: Keyword.get(opts, :sandbox_manager),
        sandbox_launch_spec: Keyword.get(opts, :sandbox_launch_spec),
        sandbox_opts: Keyword.get(opts, :sandbox_opts, []),
        runtime_command: Keyword.get(opts, :runtime_command, []),
        result_destination: Keyword.get(opts, :result_destination),
        adapter_config: Keyword.get(opts, :adapter_config, %{}),
        session_control:
          Keyword.get_lazy(opts, :session_control, fn -> Process.whereis(SessionControl) end),
        buffer:
          Buffer.new(
            capacity: Keyword.get(opts, :event_capacity, 256),
            critical_reserve: Keyword.get(opts, :critical_event_reserve, 32)
          )
      }

    case register_session(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, {:session_inventory_registration_failed, reason}}
    end
  end

  @impl true
  def handle_call(:start, _from, state) do
    if is_nil(state.sandbox_manager),
      do: start_legacy(state),
      else: start_attached(state)
  end

  def handle_call({:ingest, %Event{} = event}, _from, state) do
    key = Event.dedupe_key(event)

    if MapSet.member?(state.dedupe, key) do
      {:reply, :duplicate, state}
    else
      event = %{event | seq: state.session.last_event_sequence + 1}

      case Buffer.push(state.buffer, event, class: event.event_class) do
        {:ok, buffer} ->
          session = %{state.session | last_event_sequence: event.seq}

          with :ok <- persist_event(state, event),
               :ok <- persist_session(state, session) do
            {:reply, :ok,
             %{state | buffer: buffer, session: session, dedupe: MapSet.put(state.dedupe, key)}}
          else
            {:error, reason} -> {:reply, {:error, reason}, state}
          end

        {:overload, buffer, reason} ->
          {:reply, {:error, {:event_overload, reason}}, %{state | buffer: buffer}}
      end
    end
  end

  def handle_call({:drain, limit}, _from, state) do
    {events, buffer} = drain_buffer(state.buffer, limit, [])
    {:reply, {:ok, events}, %{state | buffer: buffer, events: state.events ++ events}}
  end

  def handle_call({:poll, limit}, _from, state) do
    cond do
      not is_integer(limit) or limit <= 0 ->
        {:reply, {:error, :delegated_session_poll_limit_invalid}, state}

      is_nil(state.adapter_handle) ->
        {:reply, {:error, :delegated_session_not_started}, state}

      not function_exported?(state.adapter, :drain, 2) ->
        {:reply, {:error, :delegated_session_adapter_poll_unsupported}, state}

      true ->
        case state.adapter.drain(state.adapter_handle, limit) do
          {:ok, events} when is_list(events) ->
            case ingest_polled_events(events, state) do
              {:ok, state} -> {:reply, {:ok, events}, state}
              {:error, reason, state} -> {:reply, {:error, reason}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}

          _invalid ->
            {:reply, {:error, :delegated_session_adapter_poll_invalid}, state}
        end
    end
  end

  def handle_call({:decide, approval_id, receipt}, _from, state) do
    if is_nil(state.adapter_handle) do
      {:reply, {:error, :delegated_session_not_started}, state}
    else
      {:reply, state.adapter.decide(state.adapter_handle, approval_id, receipt), state}
    end
  end

  def handle_call({:cancel, reason}, _from, state) do
    with {:ok, session} <- advance(state.session, :cancelling),
         :ok <- state.adapter.cancel(state.adapter_handle, reason),
         :ok <- stop_runtime(state),
         {:ok, session} <- advance(session, :cancelled, exit_reason: reason),
         :ok <- persist_session(state, session) do
      {:reply, {:ok, session}, %{state | session: session}}
    else
      {:error, reason} -> {:reply, {:error, reason}, fail_session(state, reason)}
    end
  end

  def handle_call({:reconcile, %DelegatedSession{} = durable}, _from, state) do
    with :ok <- DelegatedSession.resume_compatible?(durable, state.session),
         {:ok, observed} <- state.adapter.snapshot(state.adapter_handle),
         {:ok, decision, _details} <- state.adapter.reconcile(durable, observed) do
      {:reply, {:ok, decision}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:finalize, _from, state) do
    with {:ok, session} <- ensure_finalizing(state.session) do
      case state.adapter.finalize(state.adapter_handle) do
        {:ok, result} ->
          finalize_after_adapter_success(session, result, state)

        {:error, reason} ->
          finalize_after_adapter_failure(session, reason, state)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, fail_session(state, reason)}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     {:ok,
      %{
        session: state.session,
        events: state.events,
        buffer: Buffer.stats(state.buffer),
        sandbox_resource_id: state.sandbox_resource_id
      }}, state}
  end

  defp start_legacy(state) do
    with {:ok, session} <- advance(state.session, :authenticating),
         {:ok, prepared} <- state.adapter.prepare(session_spec(session, state)),
         {:ok, authenticated} <-
           state.adapter.authenticate(prepared, %{profile: session.auth_profile_id}),
         {:ok, session} <- advance(session, :creating_sandbox),
         {:ok, manifest} <- state.sandbox_backend.prepare(sandbox_spec(session, state), []),
         {:ok, resource_id, _resource} <- state.sandbox_backend.create(manifest, []),
         session <- %{session | sandbox_resource_id: resource_id},
         :ok <- persist_session(state, session),
         {:ok, _process} <- state.sandbox_backend.start(resource_id, []),
         {:ok, session} <- advance(session, :starting),
         :ok <- persist_session(state, session),
         {:ok, handle, identity} <-
           state.adapter.start(authenticated, session_spec(session, state)),
         {:ok, session} <-
           advance(
             %{
               session
               | external_session_id: identity.external_session_id,
                 external_turn_id: Map.get(identity, :external_turn_id)
             },
             :running
           ),
         :ok <- persist_session(state, session) do
      {:reply, {:ok, session},
       %{
         state
         | session: session,
           adapter_handle: handle,
           sandbox_resource_id: resource_id
       }}
    else
      {:error, reason} -> {:reply, {:error, reason}, fail_session(state, reason)}
    end
  end

  defp start_attached(state) do
    with :ok <- validate_attached_configuration(state),
         {:ok, session} <- advance(state.session, :authenticating),
         {:ok, session} <- advance(session, :creating_sandbox),
         {:ok, launch_spec} <- resolve_sandbox_spec(session, state),
         launch_spec <- Map.put(launch_spec, :result_destination, state.result_destination),
         {:ok, resource_id, record, transport} <-
           SandboxManager.launch_attached(
             launch_spec,
             Keyword.merge(state.sandbox_opts,
               server: state.sandbox_manager,
               command: state.runtime_command
             )
           ) do
      session = %{session | sandbox_resource_id: resource_id}
      state = %{state | session: session, sandbox_resource_id: resource_id}

      case finish_attached_start(session, record, transport, state) do
        {:ok, session, handle} ->
          {:reply, {:ok, session}, %{state | session: session, adapter_handle: handle}}

        {:error, reason} ->
          state = cleanup_failed_attached_start(state, reason)
          {:reply, {:error, reason}, state}
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, fail_session(state, reason)}
    end
  end

  defp finish_attached_start(session, record, transport, state) do
    with :ok <- verify_manifest_identity(session, record),
         :ok <- persist_session(state, session),
         {:ok, session} <- advance(session, :starting),
         :ok <- persist_session(state, session),
         config <- attached_adapter_config(state.adapter_config, transport),
         spec <- session_spec(session, %{state | adapter_config: config}),
         {:ok, prepared} <- state.adapter.prepare(spec),
         {:ok, authenticated} <-
           state.adapter.authenticate(prepared, %{profile: session.auth_profile_id}),
         {:ok, handle, identity} <- state.adapter.start(authenticated, spec),
         {:ok, session} <-
           advance(
             %{
               session
               | external_session_id: identity.external_session_id,
                 external_turn_id: Map.get(identity, :external_turn_id)
             },
             :running
           ),
         :ok <- persist_session(state, session) do
      {:ok, session, handle}
    end
  end

  defp cleanup_failed_attached_start(state, reason) do
    cleanup =
      SandboxManager.cancel(
        state.sandbox_resource_id,
        Keyword.put(state.sandbox_opts, :server, state.sandbox_manager)
      )

    failure =
      if cleanup in [:ok, :already_stopped],
        do: reason,
        else: {:attached_session_start_cleanup_failed, reason, cleanup}

    fail_session(state, failure)
  end

  defp advance(session, status, opts \\ []),
    do: DelegatedSession.transition(session, status, opts)

  defp ensure_finalizing(%DelegatedSession{status: :finalizing} = session), do: {:ok, session}

  defp ensure_finalizing(%DelegatedSession{status: :running} = session) do
    with {:ok, session} <- advance(session, :completed),
         {:ok, session} <- advance(session, :finalizing) do
      {:ok, session}
    end
  end

  defp ensure_finalizing(%DelegatedSession{} = session) do
    with {:ok, session} <- advance(session, :finalizing), do: {:ok, session}
  end

  defp finalize_after_adapter_success(session, result, state) do
    with {:ok, evidence} <- destroy_runtime(state),
         result <- Map.put(result, :runtime_quiescence, evidence),
         {:ok, session} <- advance(session, :finalized, result: result),
         :ok <- persist_session(state, session) do
      {:reply, {:ok, session}, %{state | session: session}}
    else
      {:error, reason} -> {:reply, {:error, reason}, fail_session(state, reason)}
    end
  end

  defp finalize_after_adapter_failure(session, adapter_reason, state) do
    with {:ok, evidence} <- destroy_runtime(state),
         result <- %{runtime_quiescence: evidence, adapter_error: adapter_reason},
         {:ok, session} <- advance(session, :failed, result: result, exit_reason: adapter_reason),
         :ok <- persist_session(state, session) do
      reply_evidence = %{runtime_quiescence: evidence, session: session}
      {:reply, {:error, adapter_reason, reply_evidence}, %{state | session: session}}
    else
      {:error, reason} -> {:reply, {:error, reason}, fail_session(state, reason)}
    end
  end

  defp destroy_runtime(state) do
    case complete_runtime(state) do
      {:ok, %{runtime_quiescence: evidence} = report} ->
        {:ok, Map.put(evidence, :workspace_sync, Map.delete(report, :runtime_quiescence))}

      result when result in [:ok, :already_stopped] ->
        {:ok,
         %{
           runtime_stopped: true,
           runtime_identity: state.sandbox_resource_id,
           stopped_at: Twelvgaige.Clock.utc_now()
         }}

      {:error, reason} ->
        {:error, {:sandbox_destroy_failed, reason}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if is_binary(state.sandbox_resource_id) and state.session.status != :finalized do
      _ = cleanup_runtime(state)
    end

    :ok
  end

  defp fail_session(state, reason) do
    case advance(state.session, :failed, exit_reason: reason) do
      {:ok, session} ->
        _ = persist_session(state, session)
        %{state | session: session}

      {:error, _transition} ->
        state
    end
  end

  defp register_session(%{session_control: nil} = state), do: {:ok, state}

  defp register_session(state) do
    case SessionControl.register(state.session, server: state.session_control) do
      {:ok, _session} ->
        {:ok, %{state | session_registered?: true}}

      {:error, :session_exists} ->
        with {:ok, _session} <-
               SessionControl.update(state.session.id, state.session,
                 server: state.session_control
               ) do
          {:ok, %{state | session_registered?: true}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_session(%{session_control: nil}, _session), do: :ok

  defp persist_session(state, session) do
    case SessionControl.update(session.id, session, server: state.session_control) do
      {:ok, _stored} -> :ok
      {:error, reason} -> {:error, {:session_inventory_update_failed, reason}}
    end
  end

  defp persist_event(%{session_control: nil}, _event), do: :ok

  defp persist_event(state, event) do
    case SessionControl.append_event(state.session.id, event, server: state.session_control) do
      {:ok, _stored} -> :ok
      :duplicate -> :ok
      {:error, reason} -> {:error, {:session_event_persistence_failed, reason}}
    end
  end

  defp drain_buffer(buffer, 0, acc), do: {Enum.reverse(acc), buffer}

  defp drain_buffer(buffer, remaining, acc) do
    case Buffer.pop(buffer) do
      {:ok, event, buffer} -> drain_buffer(buffer, remaining - 1, [event | acc])
      :empty -> {Enum.reverse(acc), buffer}
    end
  end

  defp session_spec(session, state) do
    session
    |> Map.from_struct()
    |> Map.put(:adapter_config, state.adapter_config)
  end

  defp sandbox_spec(session, state) do
    case resolve_sandbox_spec(session, state) do
      {:ok, spec} -> spec
      {:error, reason} -> throw({:sandbox_spec_invalid, reason})
    end
  end

  defp resolve_sandbox_spec(session, %{sandbox_launch_spec: resolver})
       when is_function(resolver, 1),
       do: normalize_sandbox_spec(resolver.(session))

  defp resolve_sandbox_spec(_session, %{sandbox_launch_spec: spec}) when is_map(spec),
    do: {:ok, spec}

  defp resolve_sandbox_spec(session, _state) do
    %{
      session_id: session.id,
      profile: session.sandbox_profile,
      manifest_digest: session.sandbox_manifest_digest,
      workspace_id: session.workspace_id,
      deadline: session.deadline,
      budgets: session.budgets
    }
    |> then(&{:ok, &1})
  end

  defp normalize_sandbox_spec({:ok, spec}) when is_map(spec), do: {:ok, spec}
  defp normalize_sandbox_spec({:error, _reason} = error), do: error
  defp normalize_sandbox_spec(spec) when is_map(spec), do: {:ok, spec}
  defp normalize_sandbox_spec(_invalid), do: {:error, :sandbox_launch_spec_invalid}

  defp validate_attached_configuration(state) do
    cond do
      not is_list(state.runtime_command) or state.runtime_command == [] ->
        {:error, :attached_runtime_command_required}

      not Enum.all?(state.runtime_command, &(is_binary(&1) and &1 != "")) ->
        {:error, :attached_runtime_command_invalid}

      is_nil(state.sandbox_launch_spec) ->
        {:error, :attached_sandbox_launch_spec_required}

      not is_binary(state.result_destination) or state.result_destination == "" ->
        {:error, :attached_result_destination_required}

      true ->
        :ok
    end
  end

  defp attached_adapter_config(config, transport) do
    client_opts =
      config
      |> value(:client_opts, [])
      |> Keyword.drop([
        :binary,
        :arguments,
        :environment,
        :send_frame,
        :close_transport
      ])
      |> Keyword.merge(
        binary: transport.binary,
        arguments: transport.arguments,
        environment: transport.environment
      )

    config
    |> Map.new()
    |> Map.drop([:client, "client", :client_module, "client_module"])
    |> Map.put(:client_opts, client_opts)
    |> Map.put(:sandbox_authority, :outer)
  end

  defp ingest_polled_events(events, state) do
    Enum.reduce_while(events, {:ok, state}, fn
      %Event{} = event, {:ok, state} ->
        key = Event.dedupe_key(event)

        if MapSet.member?(state.dedupe, key) do
          {:cont, {:ok, state}}
        else
          event = %{event | seq: state.session.last_event_sequence + 1}

          case Buffer.push(state.buffer, event, class: event.event_class) do
            {:ok, buffer} ->
              session = %{state.session | last_event_sequence: event.seq}

              with :ok <- persist_event(state, event),
                   :ok <- persist_session(state, session) do
                next = %{
                  state
                  | buffer: buffer,
                    session: session,
                    dedupe: MapSet.put(state.dedupe, key)
                }

                {:cont, {:ok, next}}
              else
                {:error, reason} -> {:halt, {:error, reason, state}}
              end

            {:overload, buffer, reason} ->
              {:halt, {:error, {:event_overload, reason}, %{state | buffer: buffer}}}
          end
        end

      _invalid, {:ok, state} ->
        {:halt, {:error, :delegated_session_event_invalid, state}}
    end)
  end

  defp verify_manifest_identity(session, %{manifest: %{manifest_digest: digest}})
       when is_binary(digest) do
    if digest == session.sandbox_manifest_digest,
      do: :ok,
      else:
        {:error, {:sandbox_manifest_identity_mismatch, session.sandbox_manifest_digest, digest}}
  end

  defp verify_manifest_identity(_session, _record), do: :ok

  defp stop_runtime(%{sandbox_manager: nil} = state),
    do: state.sandbox_backend.stop(state.sandbox_resource_id, [])

  defp stop_runtime(state) do
    case SandboxManager.quiesce(
           state.sandbox_resource_id,
           Keyword.put(state.sandbox_opts, :server, state.sandbox_manager)
         ) do
      {:ok, _evidence} -> :ok
      :already_stopped -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp cleanup_runtime(%{sandbox_manager: nil} = state),
    do: state.sandbox_backend.destroy(state.sandbox_resource_id, [])

  defp cleanup_runtime(state),
    do:
      SandboxManager.cancel(
        state.sandbox_resource_id,
        Keyword.put(state.sandbox_opts, :server, state.sandbox_manager)
      )

  defp complete_runtime(%{sandbox_manager: nil} = state), do: cleanup_runtime(state)

  defp complete_runtime(state) do
    SandboxManager.complete_workspace(
      state.sandbox_resource_id,
      state.result_destination,
      Keyword.put(state.sandbox_opts, :server, state.sandbox_manager)
    )
  end

  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default) when is_map(attrs),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
