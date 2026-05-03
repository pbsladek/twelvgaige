defmodule Twelvgaige.Metrics do
  @moduledoc """
  Small in-process metrics collector for laptop-first deployments.

  Metrics are best-effort. Recording functions return `:ok` when the collector
  is unavailable or a label is rejected, so observability can never block round
  execution or state transitions.
  """

  use GenServer

  @duration_buckets [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10, 30, 60, 300]
  @byte_buckets [1024, 10_240, 102_400, 1_048_576, 10_485_760, 104_857_600]
  @high_cardinality_keys MapSet.new([
                           "round_id",
                           "shot_id",
                           "attempt_id",
                           "tool_call_id",
                           "request_id",
                           "trace_id",
                           "span_id",
                           "prompt_hash",
                           "input",
                           "user_input",
                           "file_path",
                           "path",
                           "error",
                           "error_message",
                           "message"
                         ])
  @max_label_bytes 128

  defstruct counters: %{}, histograms: %{}

  @type label :: {String.t(), String.t()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec counter(String.t(), map() | keyword(), number(), keyword()) :: :ok
  def counter(name, labels \\ %{}, value \\ 1, opts \\ [])
      when is_binary(name) and is_number(value) do
    with true <- value >= 0,
         {:ok, labels} <- sanitize_labels(labels),
         {:ok, server} <- resolve_server(opts) do
      GenServer.cast(server, {:counter, name, labels, value})
    else
      _ignored -> :ok
    end
  end

  @spec observe(String.t(), number(), map() | keyword(), keyword()) :: :ok
  def observe(name, value, labels \\ %{}, opts \\ [])
      when is_binary(name) and is_number(value) do
    with true <- value >= 0,
         {:ok, labels} <- sanitize_labels(labels),
         {:ok, server} <- resolve_server(opts) do
      buckets = Keyword.get(opts, :buckets, default_buckets(name))
      GenServer.cast(server, {:observe, name, labels, value, buckets})
    else
      _ignored -> :ok
    end
  end

  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    case resolve_server(server: server) do
      {:ok, server} -> GenServer.call(server, :snapshot)
      :error -> %{counters: [], histograms: []}
    end
  end

  @spec to_map(map()) :: map()
  def to_map(%{} = snapshot) do
    %{
      counters:
        snapshot
        |> Map.get(:counters, [])
        |> Enum.map(fn counter ->
          %{
            name: Map.get(counter, :name),
            labels: counter |> Map.get(:labels, []) |> Map.new(),
            value: Map.get(counter, :value, 0)
          }
        end),
      histograms:
        snapshot
        |> Map.get(:histograms, [])
        |> Enum.map(fn histogram ->
          bucket_counts = Map.get(histogram, :bucket_counts, %{})

          %{
            name: Map.get(histogram, :name),
            labels: histogram |> Map.get(:labels, []) |> Map.new(),
            buckets: Map.get(histogram, :buckets, []),
            bucket_counts:
              histogram
              |> Map.get(:buckets, [])
              |> Enum.map(fn bucket ->
                %{le: bucket, count: Map.get(bucket_counts, bucket, 0)}
              end),
            count: Map.get(histogram, :count, 0),
            sum: Map.get(histogram, :sum, 0)
          }
        end)
    }
  end

  @spec sanitize_labels(map() | keyword()) :: {:ok, [label()]} | {:error, term()}
  def sanitize_labels(labels) when is_map(labels) or is_list(labels) do
    labels
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, acc} ->
      key = normalize_label_key(key)

      cond do
        MapSet.member?(@high_cardinality_keys, key) ->
          {:halt, {:error, {:high_cardinality_label, key}}}

        key == "" ->
          {:halt, {:error, :empty_label_key}}

        true ->
          case normalize_label_value(value) do
            {:ok, value} -> {:cont, {:ok, [{key, value} | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
      end
    end)
    |> case do
      {:ok, labels} -> {:ok, Enum.sort(labels)}
      {:error, _reason} = error -> error
    end
  end

  def sanitize_labels(_labels), do: {:error, :invalid_labels}

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_cast({:counter, name, labels, value}, state) do
    key = {name, labels}
    counters = Map.update(state.counters, key, value, &(&1 + value))
    {:noreply, %{state | counters: counters}}
  end

  def handle_cast({:observe, name, labels, value, buckets}, state) do
    key = {name, labels}

    histogram =
      state.histograms
      |> Map.get(key, new_histogram(name, labels, buckets))
      |> update_histogram(value)

    {:noreply, %{state | histograms: Map.put(state.histograms, key, histogram)}}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    snapshot = %{
      counters:
        Enum.map(state.counters, fn {{name, labels}, value} ->
          %{name: name, labels: labels, value: value}
        end),
      histograms: Map.values(state.histograms)
    }

    {:reply, snapshot, state}
  end

  defp resolve_server(opts) do
    server = Keyword.get(opts, :server, Keyword.get(opts, :metrics, __MODULE__))

    cond do
      is_nil(server) ->
        :error

      is_pid(server) and Process.alive?(server) ->
        {:ok, server}

      is_atom(server) and Process.whereis(server) != nil ->
        {:ok, server}

      true ->
        :error
    end
  end

  defp new_histogram(name, labels, buckets) do
    buckets = Enum.sort(Enum.map(buckets, &(&1 / 1)))

    %{
      name: name,
      labels: labels,
      buckets: buckets,
      bucket_counts: Map.new(buckets, &{&1, 0}),
      count: 0,
      sum: 0.0
    }
  end

  defp update_histogram(histogram, value) do
    value = value / 1

    bucket_counts =
      Map.new(histogram.bucket_counts, fn {bucket, count} ->
        if value <= bucket, do: {bucket, count + 1}, else: {bucket, count}
      end)

    %{
      histogram
      | bucket_counts: bucket_counts,
        count: histogram.count + 1,
        sum: histogram.sum + value
    }
  end

  defp default_buckets(name) do
    cond do
      String.ends_with?(name, "_bytes") -> @byte_buckets
      true -> @duration_buckets
    end
  end

  defp normalize_label_key(key) when is_atom(key),
    do: key |> Atom.to_string() |> String.downcase()

  defp normalize_label_key(key) do
    key
    |> to_string()
    |> String.downcase()
  end

  defp normalize_label_value(value) when is_atom(value),
    do: normalize_label_value(Atom.to_string(value))

  defp normalize_label_value(value) when is_integer(value), do: {:ok, Integer.to_string(value)}
  defp normalize_label_value(value) when is_boolean(value), do: {:ok, to_string(value)}

  defp normalize_label_value(value) when is_binary(value) do
    if byte_size(value) <= @max_label_bytes do
      {:ok, value}
    else
      {:error, :label_value_too_large}
    end
  end

  defp normalize_label_value(_value), do: {:error, :invalid_label_value}
end
