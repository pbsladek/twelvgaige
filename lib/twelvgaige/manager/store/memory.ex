defmodule Twelvgaige.Manager.Store.Memory do
  @moduledoc "Idempotent manager store, optionally persisted atomically to a local-user file."

  use GenServer
  @behaviour Twelvgaige.Manager.Store

  defstruct plans: %{}, children: %{}, events: %{}, event_ids: MapSet.new(), persistence_path: nil

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    start_opts = Keyword.delete(opts, :name)

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, start_opts),
      else: GenServer.start_link(__MODULE__, start_opts, name: name)
  end

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :persistence_path)

    case load(path) do
      {:ok, state} -> {:ok, %{state | persistence_path: path}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl Twelvgaige.Manager.Store
  def put_plan(record, opts \\ []), do: call(opts, {:put_plan, record})

  @impl Twelvgaige.Manager.Store
  def put_submission(record, children, opts \\ []),
    do: call(opts, {:put_submission, record, children})

  @impl Twelvgaige.Manager.Store
  def get_plan(plan_id, opts \\ []), do: call(opts, {:get_plan, plan_id})

  @impl Twelvgaige.Manager.Store
  def list_plans(opts \\ []), do: call(opts, :list_plans)

  @impl Twelvgaige.Manager.Store
  def update_plan(plan_id, version, attrs, opts \\ []),
    do: call(opts, {:update_plan, plan_id, version, attrs})

  @impl Twelvgaige.Manager.Store
  def put_child(child, opts \\ []), do: call(opts, {:put_child, child})

  @impl Twelvgaige.Manager.Store
  def get_child(child_id, opts \\ []), do: call(opts, {:get_child, child_id})

  @impl Twelvgaige.Manager.Store
  def list_children(plan_id, opts \\ []), do: call(opts, {:list_children, plan_id})

  @impl Twelvgaige.Manager.Store
  def update_child(child_id, version, attrs, opts \\ []),
    do: call(opts, {:update_child, child_id, version, attrs})

  @impl Twelvgaige.Manager.Store
  def append_event(plan_id, event, opts \\ []), do: call(opts, {:append_event, plan_id, event})

  @impl Twelvgaige.Manager.Store
  def list_events(plan_id, opts \\ []), do: call(opts, {:list_events, plan_id})

  def snapshot(opts \\ []), do: call(opts, :snapshot)

  @impl true
  def handle_call({:put_plan, record}, _from, state) do
    id = record.id

    case Map.fetch(state.plans, id) do
      {:ok, ^record} -> {:reply, :already_present, state}
      {:ok, _other} -> {:reply, {:error, :manager_plan_conflict}, state}
      :error -> persist_reply(:ok, %{state | plans: Map.put(state.plans, id, record)})
    end
  end

  def handle_call({:put_submission, record, children}, _from, state) do
    child_map = Map.new(children, &{&1.id, &1})

    cond do
      map_size(child_map) != length(children) ->
        {:reply, {:error, :manager_child_conflict}, state}

      conflicting?(state.plans, record.id, record) ->
        {:reply, {:error, :manager_plan_conflict}, state}

      Enum.any?(child_map, fn {id, child} -> conflicting?(state.children, id, child) end) ->
        {:reply, {:error, :manager_child_conflict}, state}

      Map.get(state.plans, record.id) == record and
          Enum.all?(child_map, fn {id, child} -> Map.get(state.children, id) == child end) ->
        {:reply, :already_present, state}

      true ->
        next = %{
          state
          | plans: Map.put(state.plans, record.id, record),
            children: Map.merge(state.children, child_map)
        }

        persist_reply(:ok, next)
    end
  end

  def handle_call({:get_plan, id}, _from, state), do: {:reply, fetch(state.plans, id), state}

  def handle_call(:list_plans, _from, state),
    do: {:reply, {:ok, state.plans |> Map.values() |> Enum.sort_by(& &1.id)}, state}

  def handle_call({:update_plan, id, version, attrs}, _from, state) do
    update_record(state, :plans, id, version, attrs)
  end

  def handle_call({:put_child, child}, _from, state) do
    case Map.fetch(state.children, child.id) do
      {:ok, ^child} -> {:reply, :already_present, state}
      {:ok, _other} -> {:reply, {:error, :manager_child_conflict}, state}
      :error -> persist_reply(:ok, %{state | children: Map.put(state.children, child.id, child)})
    end
  end

  def handle_call({:get_child, id}, _from, state), do: {:reply, fetch(state.children, id), state}

  def handle_call({:list_children, plan_id}, _from, state) do
    children =
      state.children
      |> Map.values()
      |> Enum.filter(&(&1.plan_id == plan_id))
      |> Enum.sort_by(&{&1.created_at, &1.id})

    {:reply, {:ok, children}, state}
  end

  def handle_call({:update_child, id, version, attrs}, _from, state) do
    update_record(state, :children, id, version, attrs)
  end

  def handle_call({:append_event, plan_id, event}, _from, state) do
    id = Map.get(event, :id, Map.get(event, "id"))

    cond do
      not is_binary(id) ->
        {:reply, {:error, :manager_event_id_required}, state}

      MapSet.member?(state.event_ids, {plan_id, id}) ->
        {:reply, :already_present, state}

      true ->
        events = Map.update(state.events, plan_id, [event], &(&1 ++ [event]))
        state = %{state | events: events, event_ids: MapSet.put(state.event_ids, {plan_id, id})}
        persist_reply(:ok, state)
    end
  end

  def handle_call({:list_events, plan_id}, _from, state),
    do: {:reply, {:ok, Map.get(state.events, plan_id, [])}, state}

  def handle_call(:snapshot, _from, state), do: {:reply, state, state}

  defp update_record(state, collection, id, version, attrs) do
    records = Map.fetch!(state, collection)

    case Map.fetch(records, id) do
      {:ok, %{version: ^version} = record} ->
        updated = record |> struct!(Map.new(attrs)) |> Map.put(:version, version + 1)
        state = Map.put(state, collection, Map.put(records, id, updated))
        persist_reply({:ok, updated}, state)

      {:ok, _record} ->
        {:reply, {:error, :manager_version_conflict}, state}

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp persist_reply(reply, state) do
    case persist(state) do
      :ok -> {:reply, reply, state}
      {:error, reason} -> {:reply, {:error, {:manager_store_persist_failed, reason}}, state}
    end
  end

  defp persist(%{persistence_path: nil}), do: :ok

  defp persist(%{persistence_path: path} = state) do
    directory = Path.dirname(path)
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"
    payload = state |> Map.put(:persistence_path, nil) |> :erlang.term_to_binary([:compressed])

    with :ok <- File.mkdir_p(directory),
         :ok <- File.write(temporary, payload, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, reason}
    end
  end

  defp load(nil), do: {:ok, %__MODULE__{}}

  # Persisted local state uses the restricted decoder and is shape-checked
  # immediately after decoding.
  # sobelow_skip ["Misc.BinToTerm"]
  defp load(path) do
    case File.read(path) do
      {:ok, payload} ->
        case :erlang.binary_to_term(payload, [:safe]) do
          %__MODULE__{} = state -> {:ok, state}
          _other -> {:error, :manager_store_invalid}
        end

      {:error, :enoent} ->
        {:ok, %__MODULE__{}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    ArgumentError -> {:error, :manager_store_invalid}
  end

  defp fetch(records, id) do
    case Map.fetch(records, id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  defp conflicting?(records, id, expected) do
    case Map.fetch(records, id) do
      {:ok, ^expected} -> false
      {:ok, _other} -> true
      :error -> false
    end
  end

  defp call(opts, message), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), message)
end
