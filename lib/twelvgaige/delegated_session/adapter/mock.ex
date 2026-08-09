defmodule Twelvgaige.DelegatedSession.Adapter.Mock do
  @moduledoc "Deterministic demand-driven adapter for contract and recovery tests."
  @behaviour Twelvgaige.DelegatedSession.Adapter

  @impl true
  def capabilities(config),
    do: {:ok, Map.get(config, :capabilities, %{streaming: true, resume: true})}

  @impl true
  def prepare(spec), do: {:ok, %{spec: spec, events: Map.get(spec, :mock_events, [])}}

  @impl true
  def authenticate(prepared, lease), do: {:ok, Map.put(prepared, :auth_lease, lease)}

  @impl true
  def start(prepared, _spec) do
    external_id = "mock_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    {:ok, Map.put(prepared, :external_session_id, external_id),
     %{external_session_id: external_id}}
  end

  @impl true
  def resume(external_id, prepared, _spec),
    do:
      {:ok, Map.put(prepared, :external_session_id, external_id),
       %{external_session_id: external_id}}

  @impl true
  def send_input(_handle, _input), do: :ok

  @impl true
  def decide(_handle, _approval_id, _decision), do: :ok

  @impl true
  def cancel(_handle, _reason), do: :ok

  @impl true
  def snapshot(handle), do: {:ok, Map.take(handle, [:external_session_id, :events])}

  @impl true
  def reconcile(durable, observed) do
    if durable.external_session_id == observed.external_session_id,
      do: {:ok, :resume, observed},
      else: {:ok, :awaiting_reconciliation, observed}
  end

  @impl true
  def finalize(handle), do: {:ok, %{external_session_id: handle.external_session_id}}

  @spec next_event(map()) :: {:ok, term(), map()} | :done
  def next_event(%{events: [event | rest]} = handle), do: {:ok, event, %{handle | events: rest}}
  def next_event(%{events: []}), do: :done
end
