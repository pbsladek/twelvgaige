defmodule Twelvgaige.Metrics.Prometheus do
  @moduledoc """
  Dependency-free Prometheus text exposition helpers.

  This module emits a small operational snapshot from daemon status. It is not a
  replacement for telemetry aggregation, but it gives Phase 5 a stable metrics
  endpoint and keeps resource limiter state observable on laptop deployments.
  """

  alias Twelvgaige.Breech

  @spec snapshot(keyword()) :: {:ok, String.t()} | {:error, term()}
  def snapshot(opts \\ []) do
    server = Keyword.get(opts, :server, Breech)

    with {:ok, status} <- Breech.status(server) do
      {:ok, render(status)}
    end
  end

  @spec render(map()) :: String.t()
  def render(status) when is_map(status) do
    profile = value(status, :profile, "unknown")
    resources = value(status, :resources, %{})
    store = value(status, :store, %{})
    app_metrics = value(status, :metrics, %{counters: [], histograms: []})

    []
    |> metric("gauge", "twelvgaige_up", "Breech daemon availability.", 1)
    |> metric(
      "gauge",
      "twelvgaige_breech_uptime_seconds",
      "Breech daemon uptime in seconds.",
      (value(status, :uptime_ms, 0) || 0) / 1000
    )
    |> metric(
      "gauge",
      "twelvgaige_rounds_active",
      "Active daemon-owned rounds.",
      value(status, :active_rounds, 0) || 0,
      profile: profile
    )
    |> metric(
      "gauge",
      "twelvgaige_store_incomplete_rounds",
      "Incomplete durable-store rounds.",
      value(store, :incomplete_rounds, 0) || 0,
      profile: profile
    )
    |> metric(
      "gauge",
      "twelvgaige_store_rounds_retained",
      "Round snapshots retained by the active store.",
      value(store, :rounds, 0) || 0,
      profile: profile
    )
    |> metric(
      "gauge",
      "twelvgaige_store_terminal_rounds_retained",
      "Terminal round snapshots retained by the active store.",
      value(store, :terminal_rounds, 0) || 0,
      profile: profile
    )
    |> metric(
      "gauge",
      "twelvgaige_store_round_events_retained",
      "Round events retained by the active store.",
      value(store, :round_events, 0) || 0,
      profile: profile
    )
    |> metric(
      "gauge",
      "twelvgaige_store_audit_events_retained",
      "Audit events retained by the active store.",
      value(store, :audit_events, 0) || 0,
      profile: profile
    )
    |> metric(
      "gauge",
      "twelvgaige_store_attempt_journals_retained",
      "Attempt journals retained by the active store.",
      value(store, :attempt_journals, 0) || 0,
      profile: profile
    )
    |> metric(
      "gauge",
      "twelvgaige_store_tool_journals_retained",
      "Tool journals retained by the active store.",
      value(store, :tool_journals, 0) || 0,
      profile: profile
    )
    |> metric(
      "gauge",
      "twelvgaige_store_retained_bytes",
      "Approximate bytes retained by the active store.",
      value(store, :retained_bytes, 0) || 0,
      profile: profile
    )
    |> metric(
      "gauge",
      "twelvgaige_store_retained_bytes_limit",
      "Configured retained byte limit for stores that enforce one.",
      value(store, :retained_bytes_limit, 0) || 0,
      profile: profile
    )
    |> metric(
      "gauge",
      "twelvgaige_store_retained_bytes_over_limit",
      "Whether retained store bytes currently exceed the configured limit.",
      boolean_value(value(store, :retained_bytes_over_limit, false)),
      profile: profile
    )
    |> metric(
      "counter",
      "twelvgaige_store_retention_evictions_total",
      "Terminal rounds evicted by local store retention.",
      value(store, :evicted_rounds, 0) || 0,
      profile: profile
    )
    |> resource_permit_metrics(resources, profile)
    |> resource_limit_metrics(resources, profile)
    |> resource_queue_metrics(resources, profile)
    |> resource_denial_metrics(resources, profile)
    |> counter_metrics(app_metrics)
    |> histogram_metrics(app_metrics)
    |> Enum.reverse()
    |> Enum.join("")
  end

  defp resource_permit_metrics(lines, resources, profile) do
    used = value(resources, :used, %{})

    Enum.reduce(used, lines, fn {resource_kind, count}, acc ->
      metric(
        acc,
        "gauge",
        "twelvgaige_resource_permits_active",
        "Active resource permits.",
        count || 0,
        resource_kind: resource_kind,
        profile: profile
      )
    end)
  end

  defp resource_limit_metrics(lines, resources, profile) do
    limits = value(resources, :limits, %{})

    Enum.reduce(limits, lines, fn {resource_kind, limit}, acc ->
      metric(
        acc,
        "gauge",
        "twelvgaige_resource_limit",
        "Configured resource permit limit.",
        limit || 0,
        resource_kind: resource_kind,
        profile: profile
      )
    end)
  end

  defp resource_queue_metrics(lines, resources, profile) do
    queue_depth = value(resources, :queue_depth, %{})

    Enum.reduce(queue_depth, lines, fn {resource_kind, depth}, acc ->
      metric(
        acc,
        "gauge",
        "twelvgaige_resource_queue_depth",
        "Waiting permit requests.",
        depth || 0,
        resource_kind: resource_kind,
        profile: profile
      )
    end)
  end

  defp resource_denial_metrics(lines, resources, profile) do
    denials = value(resources, :denials, [])

    Enum.reduce(denials, lines, fn denial, acc ->
      metric(
        acc,
        "counter",
        "twelvgaige_resource_denials_total",
        "Resource permit denials.",
        value(denial, :count, 0) || 0,
        resource_kind: value(denial, :resource_kind, "unknown"),
        reason: value(denial, :reason, "unknown"),
        profile: profile
      )
    end)
  end

  defp counter_metrics(lines, metrics) do
    metrics
    |> value(:counters, [])
    |> Enum.reduce(lines, fn counter, acc ->
      metric(
        acc,
        "counter",
        value(counter, :name, "twelvgaige_unknown_total"),
        metric_help(value(counter, :name, nil)),
        value(counter, :value, 0),
        value(counter, :labels, [])
      )
    end)
  end

  defp histogram_metrics(lines, metrics) do
    metrics
    |> value(:histograms, [])
    |> Enum.reduce(lines, fn histogram, acc ->
      histogram_metric(
        acc,
        value(histogram, :name, "twelvgaige_unknown"),
        metric_help(value(histogram, :name, nil)),
        histogram
      )
    end)
  end

  defp histogram_metric(lines, name, help, histogram) do
    labels = value(histogram, :labels, [])
    labels = normalize_labels(labels)
    bucket_counts = value(histogram, :bucket_counts, %{})
    count = value(histogram, :count, 0)
    sum = value(histogram, :sum, 0)

    bucket_lines =
      histogram
      |> value(:buckets, [])
      |> Enum.flat_map(fn bucket ->
        bucket_labels = labels ++ [{"le", bucket_label(bucket)}]
        [sample("#{name}_bucket", bucket_count(bucket_counts, bucket), bucket_labels)]
      end)

    [
      sample("#{name}_count", count, labels),
      sample("#{name}_sum", sum, labels),
      sample("#{name}_bucket", count, labels ++ [{"le", "+Inf"}])
      | bucket_lines
    ] ++ ["# TYPE #{name} histogram\n", "# HELP #{name} #{escape_help(help)}\n" | lines]
  end

  defp metric(lines, type, name, help, value, labels \\ []) do
    [
      sample(name, value, labels),
      "# TYPE #{name} #{type}\n",
      "# HELP #{name} #{escape_help(help)}\n"
      | lines
    ]
  end

  defp sample(name, value, []), do: "#{name} #{format_number(value)}\n"

  defp sample(name, value, labels) do
    labels = normalize_labels(labels)

    label_text =
      labels
      |> Enum.map_join(",", fn {key, label_value} ->
        ~s(#{key}="#{escape_label(label_value)}")
      end)

    "#{name}{#{label_text}} #{format_number(value)}\n"
  end

  defp normalize_labels(%{} = labels), do: labels |> Map.to_list() |> Enum.sort()
  defp normalize_labels(labels) when is_list(labels), do: labels
  defp normalize_labels(_labels), do: []

  defp bucket_label(value) when is_integer(value), do: Integer.to_string(value)

  defp bucket_label(value) when is_float(value) do
    value
    |> :erlang.float_to_binary(decimals: 6)
    |> String.trim_trailing("0")
    |> String.trim_trailing(".")
  end

  defp bucket_count(%{} = bucket_counts, bucket) do
    Map.get(bucket_counts, bucket, Map.get(bucket_counts, bucket_label(bucket), 0))
  end

  defp bucket_count(bucket_counts, bucket) when is_list(bucket_counts) do
    Enum.find_value(bucket_counts, 0, fn entry ->
      le = value(entry, :le, nil)

      if le == bucket or to_string(le) == bucket_label(bucket) do
        value(entry, :count, 0)
      end
    end)
  end

  defp bucket_count(_bucket_counts, _bucket), do: 0

  defp metric_help("twelvgaige_rounds_total"), do: "Rounds by workflow and terminal status."
  defp metric_help("twelvgaige_round_duration_seconds"), do: "Round duration in seconds."
  defp metric_help("twelvgaige_shot_attempts_total"), do: "Shot attempts by kind and status."
  defp metric_help("twelvgaige_shot_duration_seconds"), do: "Shot attempt duration in seconds."
  defp metric_help("twelvgaige_llm_calls_total"), do: "LLM calls by provider, model, and status."
  defp metric_help("twelvgaige_llm_duration_seconds"), do: "LLM call duration in seconds."
  defp metric_help("twelvgaige_llm_tokens_total"), do: "LLM tokens reported by providers."
  defp metric_help("twelvgaige_tool_calls_total"), do: "Tool calls by tool and status."
  defp metric_help("twelvgaige_tool_duration_seconds"), do: "Tool call duration in seconds."
  defp metric_help("twelvgaige_tool_output_bytes"), do: "Tool output size in bytes."

  defp metric_help("twelvgaige_resource_queue_seconds"),
    do: "Resource queue wait duration in seconds."

  defp metric_help("twelvgaige_safety_decisions_total"),
    do: "Human-in-the-loop safety decisions."

  defp metric_help(_name), do: "Twelvgaige runtime metric."

  defp boolean_value(true), do: 1
  defp boolean_value("true"), do: 1
  defp boolean_value(_value), do: 0

  defp format_number(value) when is_integer(value), do: Integer.to_string(value)

  defp format_number(value) when is_float(value) do
    :erlang.float_to_binary(value, decimals: 3)
  end

  defp format_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, ""} -> format_number(number)
      _other -> "0"
    end
  end

  defp format_number(_value), do: "0"

  defp escape_help(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\n", "\\n")
  end

  defp escape_label(value) do
    value
    |> to_string()
    |> String.replace("\\", "\\\\")
    |> String.replace("\"", "\\\"")
    |> String.replace("\n", "\\n")
  end

  defp value(%{} = attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp value(attrs, key, default) when is_list(attrs) do
    Keyword.get(attrs, key, default)
  end

  defp value(_attrs, _key, default), do: default
end
