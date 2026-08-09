defmodule Twelvgaige.Operations.RetentionEnforcer do
  @moduledoc "Periodic retention enforcement with active-session holds and visible health."

  use GenServer

  alias Twelvgaige.Operations.Store

  defstruct [
    :store,
    :artifact_store,
    :now_fun,
    :timer,
    :last_run_at,
    :last_result,
    interval_ms: 3_600_000
  ]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, opts),
      else: GenServer.start_link(__MODULE__, opts, name: name)
  end

  def run(opts \\ []), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :run, :infinity)
  def status(opts \\ []), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :status)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      store: Keyword.get(opts, :store, Store),
      artifact_store: Keyword.get(opts, :artifact_store),
      now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
      interval_ms: Keyword.get(opts, :interval_ms, 3_600_000)
    }

    send(self(), :enforce)
    {:ok, state}
  end

  @impl true
  def handle_call(:run, _from, state) do
    {result, state} = enforce(state)
    {:reply, result, schedule(state)}
  end

  def handle_call(:status, _from, state) do
    lag_seconds =
      case state.last_run_at do
        nil -> nil
        last -> DateTime.diff(state.now_fun.(), last, :second)
      end

    {:reply,
     %{
       status: retention_status(state, lag_seconds),
       last_run_at: state.last_run_at,
       last_result: result_view(state.last_result),
       lag_seconds: lag_seconds,
       interval_ms: state.interval_ms
     }, state}
  end

  @impl true
  def handle_info(:enforce, state) do
    {_result, state} = enforce(state)
    {:noreply, schedule(state)}
  end

  defp enforce(state) do
    now = state.now_fun.()
    store_result = Store.prune(server: state.store, now: now)

    artifact_result =
      case state.artifact_store do
        nil -> {:ok, 0}
        server -> Twelvgaige.Artifact.Store.prune(server: server, now: now)
      end

    result =
      case {store_result, artifact_result} do
        {{:ok, records}, {:ok, artifacts}} ->
          {:ok, %{records_removed: records, artifacts_removed: artifacts}}

        other ->
          {:error, {:retention_enforcement_failed, other}}
      end

    _ =
      Store.append_audit(
        %{
          event_type: :retention_enforced,
          occurred_at: now,
          details: inspect(result)
        },
        server: state.store
      )

    {result, %{state | last_run_at: now, last_result: result}}
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :enforce, state.interval_ms)}
  end

  defp retention_status(%{last_result: {:error, _reason}}, _lag), do: :unhealthy
  defp retention_status(_state, nil), do: :starting
  defp retention_status(state, lag) when lag * 1_000 > state.interval_ms * 2, do: :stale
  defp retention_status(_state, _lag), do: :healthy

  defp result_view(nil), do: nil
  defp result_view({:ok, report}), do: %{status: :ok, report: report}
  defp result_view({:error, reason}), do: %{status: :error, reason: inspect(reason)}
end
