defmodule Twelvgaige.TestSupport.FakeResourceLimiter do
  @moduledoc """
  Controllable GenServer backend for `Twelvgaige.ResourceLimiter` tests.

  Production code calls `Twelvgaige.ResourceLimiter.acquire/3` with a `:server`
  option. This fake implements the GenServer call protocol behind that API so
  tests can force admission success, queueing, or denial deterministically.
  """

  use GenServer

  alias Twelvgaige.ResourceLimiter.Permit
  alias Twelvgaige.ResourceLimiter.Waiter

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      next_id: 1,
      requests: [],
      responses: Keyword.get(opts, :responses, []),
      permits: %{},
      waiters: %{}
    }

    GenServer.start_link(__MODULE__, state, name: name)
  end

  def push_response(response, server \\ __MODULE__) do
    GenServer.call(server, {:push_response, response})
  end

  def requests(server \\ __MODULE__) do
    GenServer.call(server, :requests)
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:push_response, response}, _from, state) do
    {:reply, :ok, update_in(state.responses, &(&1 ++ [response]))}
  end

  def handle_call(:requests, _from, state) do
    {:reply, Enum.reverse(state.requests), state}
  end

  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      permits: Map.values(state.permits),
      queue_depth: %{active_shot: map_size(state.waiters)},
      requests: Enum.reverse(state.requests)
    }

    {:reply, snapshot, state}
  end

  def handle_call({:acquire, resource_kind, context, owner_pid, opts}, _from, state) do
    request = %{resource_kind: resource_kind, context: context, owner_pid: owner_pid, opts: opts}
    {response, state} = next_response(state)
    state = update_in(state.requests, &[request | &1])

    case response do
      {:error, reason} ->
        {:reply, {:error, reason}, state}

      :queued ->
        {waiter, state} = new_waiter(resource_kind, context, owner_pid, state)
        {:reply, {:queued, waiter}, state}

      _ok ->
        {permit, state} = new_permit(resource_kind, context, owner_pid, state)
        {:reply, {:ok, permit}, state}
    end
  end

  def handle_call({:release, %Permit{} = permit}, _from, state) do
    {:reply, :ok, update_in(state.permits, &Map.delete(&1, permit.id))}
  end

  def handle_call({:cancel_waiter, waiter}, _from, state) do
    waiter_id =
      case waiter do
        %Waiter{id: id} -> id
        id -> id
      end

    {:reply, :ok, update_in(state.waiters, &Map.delete(&1, waiter_id))}
  end

  defp next_response(%{responses: [response | rest]} = state) do
    {response, %{state | responses: rest}}
  end

  defp next_response(state), do: {:ok, state}

  defp new_permit(resource_kind, context, owner_pid, state) do
    id = state.next_id

    permit = %Permit{
      id: id,
      resource_kind: resource_kind,
      round_id: Map.get(context, :round_id),
      shot_id: Map.get(context, :shot_id),
      attempt: Map.get(context, :attempt),
      owner_pid: owner_pid,
      bytes: Map.get(context, :bytes),
      acquired_at: System.monotonic_time(:millisecond),
      server: __MODULE__
    }

    {permit, %{state | next_id: id + 1, permits: Map.put(state.permits, id, permit)}}
  end

  defp new_waiter(resource_kind, context, owner_pid, state) do
    id = state.next_id

    waiter = %Waiter{
      id: id,
      resource_kind: resource_kind,
      round_id: Map.get(context, :round_id),
      shot_id: Map.get(context, :shot_id),
      attempt: Map.get(context, :attempt),
      owner_pid: owner_pid,
      queued_at: System.monotonic_time(:millisecond),
      queue_timeout_ms: Map.get(context, :queue_timeout_ms),
      server: __MODULE__
    }

    {waiter, %{state | next_id: id + 1, waiters: Map.put(state.waiters, id, waiter)}}
  end
end
