defmodule Twelvgaige.Round.ServerMetrics do
  @moduledoc false

  alias Twelvgaige.Error
  alias Twelvgaige.Metrics
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Round.State, as: RoundState

  @spec record_round({:ok, Snapshot.t()} | {:error, Error.t()}, String.t(), integer(), keyword()) ::
          :ok
  def record_round({:ok, %Snapshot{} = snapshot}, workflow_id, started_mono, opts) do
    labels = %{workflow_id: workflow_id, status: snapshot.status}
    metrics = metrics_opts(opts)

    Metrics.counter("twelvgaige_rounds_total", labels, 1, metrics)

    Metrics.observe(
      "twelvgaige_round_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics
    )
  end

  def record_round({:error, %Error{} = error}, workflow_id, started_mono, opts) do
    labels = %{workflow_id: workflow_id, status: :failed, error_class: error.class}
    metrics = metrics_opts(opts)

    Metrics.counter("twelvgaige_rounds_total", labels, 1, metrics)

    Metrics.observe(
      "twelvgaige_round_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics
    )
  end

  @spec record_shot(map(), {:ok, term()} | {:error, term()}, integer(), keyword()) :: :ok
  def record_shot(shot, result, started_mono, opts) do
    labels =
      %{
        kind: Map.get(shot, :kind, :slug),
        status: shot_status(result)
      }
      |> maybe_error_class(result)

    metrics = metrics_opts(opts)

    Metrics.counter("twelvgaige_shot_attempts_total", labels, 1, metrics)

    Metrics.observe(
      "twelvgaige_shot_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics
    )
  end

  @spec record_safety_decision(atom(), keyword()) :: :ok
  def record_safety_decision(decision, opts) do
    Metrics.counter(
      "twelvgaige_safety_decisions_total",
      %{decision: decision},
      1,
      metrics_opts(opts)
    )
  end

  @spec started_mono_from_round(RoundState.t()) :: integer()
  def started_mono_from_round(%RoundState{started_at: %DateTime{} = started_at}) do
    max(monotonic_ms() - DateTime.diff(Twelvgaige.Clock.utc_now(), started_at, :millisecond), 0)
  end

  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  defp maybe_error_class(labels, {:error, %Error{} = error}),
    do: Map.put(labels, :error_class, error.class)

  defp maybe_error_class(labels, _result), do: labels

  defp shot_status({:ok, _result}), do: :complete
  defp shot_status({:error, _error}), do: :failed

  defp metrics_opts(opts), do: [metrics: Keyword.get(opts, :metrics, Metrics)]
  defp duration_seconds(started_mono), do: max(monotonic_ms() - started_mono, 0) / 1000
end
