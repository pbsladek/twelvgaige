defmodule Twelvgaige.Operations.Keyring do
  @moduledoc "Host-only operational key custody and restart-safe artifact rotation."

  use GenServer

  alias Twelvgaige.Operations.Keys

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      keys: Keyword.fetch!(opts, :keys),
      artifact_store: Keyword.get(opts, :artifact_store)
    }

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, state),
      else: GenServer.start_link(__MODULE__, state, name: name)
  end

  def fetch(purpose, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:fetch, purpose})

  def status(opts \\ []), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :status)

  def rotate_artifact(opts \\ []),
    do:
      GenServer.call(Keyword.get(opts, :server, __MODULE__), {:rotate_artifact, opts}, :infinity)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:fetch, :audit_export}, _from, state),
    do: {:reply, {:ok, state.keys.audit_export_key}, state}

  def handle_call({:fetch, :session_signing}, _from, state),
    do: {:reply, {:ok, state.keys.session_signing_key}, state}

  def handle_call({:fetch, _purpose}, _from, state),
    do: {:reply, {:error, :operations_key_purpose_unknown}, state}

  def handle_call(:status, _from, state), do: {:reply, Keys.metadata(state.keys), state}

  def handle_call({:rotate_artifact, _opts}, _from, %{artifact_store: nil} = state),
    do: {:reply, {:error, :artifact_store_unavailable}, state}

  def handle_call({:rotate_artifact, opts}, _from, state) do
    case Keys.rotate_artifact(state.keys, state.artifact_store, opts) do
      {:ok, report, keys} -> {:reply, {:ok, report}, %{state | keys: keys}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end
end
