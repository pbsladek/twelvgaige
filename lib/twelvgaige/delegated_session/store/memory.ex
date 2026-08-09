defmodule Twelvgaige.DelegatedSession.Store.Memory do
  @moduledoc "Bounded in-memory delegated-session journal used by Phase 2 and tests."

  use GenServer
  @behaviour Twelvgaige.DelegatedSession.Store

  alias Twelvgaige.DelegatedSession.Event

  defstruct sessions: %{}, events: %{}, dedupe: MapSet.new(), max_events_per_session: 10_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts),
    do:
      {:ok,
       %__MODULE__{max_events_per_session: Keyword.get(opts, :max_events_per_session, 10_000)}}

  @impl true
  def create(session), do: GenServer.call(__MODULE__, {:create, session})
  @impl true
  def put(session), do: GenServer.call(__MODULE__, {:put, session})
  @impl true
  def get(session_id), do: GenServer.call(__MODULE__, {:get, session_id})
  @impl true
  def append_event(event), do: GenServer.call(__MODULE__, {:append_event, event})
  @impl true
  def list_events(session_id, opts \\ []),
    do: GenServer.call(__MODULE__, {:list_events, session_id, opts})

  @impl true
  def handle_call({:create, session}, _from, state) do
    if Map.has_key?(state.sessions, session.id) do
      {:reply, {:error, :session_exists}, state}
    else
      {:reply, :ok, put_in(state.sessions[session.id], session)}
    end
  end

  def handle_call({:put, session}, _from, state),
    do: {:reply, :ok, put_in(state.sessions[session.id], session)}

  def handle_call({:get, session_id}, _from, state) do
    {:reply, Map.fetch(state.sessions, session_id), state}
  end

  def handle_call({:append_event, %Event{} = event}, _from, state) do
    key = Event.dedupe_key(event)

    cond do
      MapSet.member?(state.dedupe, key) ->
        {:reply, :duplicate, state}

      length(Map.get(state.events, event.session_id, [])) >= state.max_events_per_session ->
        {:reply, {:error, :session_event_capacity_exhausted}, state}

      true ->
        state =
          state
          |> update_in([Access.key!(:events), event.session_id], &((&1 || []) ++ [event]))
          |> update_in([Access.key!(:dedupe)], &MapSet.put(&1, key))

        {:reply, :ok, state}
    end
  end

  def handle_call({:list_events, session_id, opts}, _from, state) do
    after_seq = Keyword.get(opts, :after_seq, 0)
    limit = Keyword.get(opts, :limit, 100)

    events =
      state.events
      |> Map.get(session_id, [])
      |> Enum.filter(&((&1.seq || 0) > after_seq))
      |> Enum.take(limit)

    {:reply, {:ok, events}, state}
  end
end
