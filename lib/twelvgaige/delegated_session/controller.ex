defmodule Twelvgaige.DelegatedSession.Controller do
  @moduledoc "Owns one delegated session, its bounded event ingress, and typed lifecycle."

  use GenServer

  alias Twelvgaige.DelegatedSession
  alias Twelvgaige.DelegatedSession.Event
  alias Twelvgaige.Event.Buffer
  alias Twelvgaige.Operations.SessionControl

  defstruct [
    :session,
    :adapter,
    :adapter_handle,
    :sandbox_backend,
    :sandbox_resource_id,
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
    with {:ok, session} <- advance(state.session, :authenticating),
         {:ok, prepared} <- state.adapter.prepare(session_spec(session)),
         {:ok, authenticated} <-
           state.adapter.authenticate(prepared, %{profile: session.auth_profile_id}),
         {:ok, session} <- advance(session, :creating_sandbox),
         {:ok, manifest} <- state.sandbox_backend.prepare(sandbox_spec(session), []),
         {:ok, resource_id, _resource} <- state.sandbox_backend.create(manifest, []),
         session <- %{session | sandbox_resource_id: resource_id},
         :ok <- persist_session(state, session),
         {:ok, _process} <- state.sandbox_backend.start(resource_id, []),
         {:ok, session} <- advance(session, :starting),
         :ok <- persist_session(state, session),
         {:ok, handle, identity} <- state.adapter.start(authenticated, session_spec(session)),
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

  def handle_call({:cancel, reason}, _from, state) do
    with {:ok, session} <- advance(state.session, :cancelling),
         :ok <- state.adapter.cancel(state.adapter_handle, reason),
         :ok <- state.sandbox_backend.stop(state.sandbox_resource_id, []),
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
    with {:ok, session} <- ensure_finalizing(state.session),
         {:ok, result} <- state.adapter.finalize(state.adapter_handle),
         :ok <- state.sandbox_backend.destroy(state.sandbox_resource_id, []),
         {:ok, session} <- advance(session, :finalized, result: result),
         :ok <- persist_session(state, session) do
      {:reply, {:ok, session}, %{state | session: session}}
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

  defp advance(session, status, opts \\ []),
    do: DelegatedSession.transition(session, status, opts)

  defp ensure_finalizing(%DelegatedSession{status: :finalizing} = session), do: {:ok, session}

  defp ensure_finalizing(%DelegatedSession{} = session) do
    with {:ok, session} <- advance(session, :finalizing), do: {:ok, session}
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

  defp session_spec(session), do: Map.from_struct(session)

  defp sandbox_spec(session) do
    %{
      session_id: session.id,
      profile: session.sandbox_profile,
      manifest_digest: session.sandbox_manifest_digest,
      workspace_id: session.workspace_id,
      deadline: session.deadline,
      budgets: session.budgets
    }
  end
end
