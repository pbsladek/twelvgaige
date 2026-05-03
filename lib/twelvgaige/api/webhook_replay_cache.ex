defmodule Twelvgaige.API.WebhookReplayCache do
  @moduledoc """
  Small in-memory replay cache for webhook nonces.

  It is intentionally local to the daemon process. Durable webhook replay
  protection can be added later if remote multi-node listeners are introduced.
  """

  use GenServer

  defstruct entries: %{}

  @type reserve_result :: :ok | {:error, :replay_detected}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec reserve(GenServer.server(), String.t(), pos_integer()) :: reserve_result()
  def reserve(server \\ __MODULE__, key, ttl_ms) when is_binary(key) and is_integer(ttl_ms) do
    GenServer.call(server, {:reserve, key, ttl_ms})
  end

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_call({:reserve, key, ttl_ms}, _from, state) do
    now = monotonic_ms()
    entries = purge_expired(state.entries, now)

    if Map.has_key?(entries, key) do
      {:reply, {:error, :replay_detected}, %{state | entries: entries}}
    else
      expires_at = now + max(ttl_ms, 1)
      {:reply, :ok, %{state | entries: Map.put(entries, key, expires_at)}}
    end
  end

  defp purge_expired(entries, now) do
    Map.reject(entries, fn {_key, expires_at} -> expires_at <= now end)
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
