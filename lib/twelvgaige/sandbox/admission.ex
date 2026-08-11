defmodule Twelvgaige.Sandbox.Admission do
  @moduledoc "Atomic reservation of sandbox count, host resources, storage, and provider quota."

  use GenServer

  @resources [
    :sandboxes,
    :cpu,
    :memory_bytes,
    :pids,
    :workspace_bytes,
    :artifact_bytes,
    :provider_tokens
  ]
  defstruct limits: %{}, used: %{}, leases: %{}

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def reserve(request, opts \\ []),
    do:
      GenServer.call(
        Keyword.get(opts, :server, __MODULE__),
        {:reserve, request, Keyword.get(opts, :lease_id)}
      )

  def release(lease_id, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:release, lease_id})

  def snapshot(opts \\ []), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :snapshot)

  @impl true
  def init(opts) do
    limits = Map.new(Keyword.fetch!(opts, :limits))
    used = Map.new(@resources, &{&1, 0})
    {:ok, %__MODULE__{limits: limits, used: used}}
  end

  @impl true
  def handle_call({:reserve, request, requested_lease_id}, _from, state) do
    request = normalize_request(request)

    with {:ok, lease_id} <- lease_id(requested_lease_id),
         :missing <- existing_lease(state, lease_id, request) do
      case overcommitted(state, request) do
        [] ->
          used = Map.merge(state.used, request, fn _key, used, amount -> used + amount end)

          {:reply, {:ok, lease_id},
           %{state | used: used, leases: Map.put(state.leases, lease_id, request)}}

        resources ->
          {:reply, {:error, {:sandbox_capacity_exceeded, resources}}, state}
      end
    else
      {:ok, lease_id} -> {:reply, {:ok, lease_id}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:release, lease_id}, _from, state) do
    case Map.pop(state.leases, lease_id) do
      {nil, _leases} ->
        {:reply, :already_released, state}

      {request, leases} ->
        used = Map.merge(state.used, request, fn _key, used, amount -> max(used - amount, 0) end)
        {:reply, :ok, %{state | used: used, leases: leases}}
    end
  end

  def handle_call(:snapshot, _from, state),
    do: {:reply, %{limits: state.limits, used: state.used}, state}

  defp normalize_request(request),
    do: Map.new(@resources, &{&1, max(value(request, &1, 0), 0)})

  defp overcommitted(state, request) do
    Enum.filter(@resources, fn resource ->
      Map.get(state.used, resource, 0) + request[resource] > Map.get(state.limits, resource, 0)
    end)
  end

  defp lease_id(nil),
    do: {:ok, "reservation_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}

  defp lease_id("reservation_" <> suffix = lease_id) when byte_size(suffix) >= 16,
    do: {:ok, lease_id}

  defp lease_id(_invalid), do: {:error, :sandbox_admission_lease_id_invalid}

  defp existing_lease(state, lease_id, request) do
    case Map.fetch(state.leases, lease_id) do
      {:ok, ^request} -> {:ok, lease_id}
      {:ok, _different} -> {:error, :sandbox_admission_lease_conflict}
      :error -> :missing
    end
  end

  defp value(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
