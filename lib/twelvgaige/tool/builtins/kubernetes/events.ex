defmodule Twelvgaige.Tool.Builtins.Kubernetes.Events do
  @moduledoc """
  Read Kubernetes events through `kubectl get events -o json`.
  """

  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Tool.Builtins.Kubernetes.Common
  alias Twelvgaige.Tool.Idempotency

  @impl true
  def name, do: "kubectl_events"

  @impl true
  def description, do: "Read Kubernetes events as normalized objects."

  @impl true
  def input_schema, do: Common.common_schema(["context", "namespace"])

  @impl true
  def safety_level, do: :read_only

  @impl true
  def idempotency, do: Idempotency.read_only()

  @impl true
  def execute(input, opts) do
    input = Map.put(input, "resource", "events")

    with {:ok, target} <- Common.target(input, opts),
         {:ok, max_bytes} <- Common.max_bytes(input, opts),
         {:ok, result} <- Common.run_kubectl(args(target), target, opts),
         {excerpt, truncated} <- Common.bounded_excerpt(result.stdout, max_bytes),
         {:ok, decoded} <- maybe_decode_json(result.stdout, truncated, target) do
      events =
        decoded
        |> Map.get("items", [])
        |> Common.limit_items(input)
        |> Enum.map(&normalize_event/1)
        |> Enum.sort_by(&Map.get(&1, "timestamp", ""), :desc)

      {:ok,
       Common.output_base(target, "events", result.duration_ms)
       |> Map.merge(%{
         items: events,
         summary: %{"event_count" => length(events)},
         raw_excerpt: if(truncated, do: excerpt, else: nil),
         truncated: truncated,
         output_bytes: byte_size(excerpt),
         exit_status: result.status
       })
       |> stringify_keys()}
    end
  end

  defp args(target) do
    Common.base_args(target) ++
      ["get", "events"] ++
      Common.selector_args(target) ++
      ["-o", "json"]
  end

  defp maybe_decode_json(_stdout, true, _target), do: {:ok, %{"items" => []}}
  defp maybe_decode_json(stdout, false, target), do: Common.decode_json(stdout, target)

  defp normalize_event(event) do
    %{
      "type" => event["type"],
      "reason" => event["reason"],
      "message" => event["message"],
      "count" => event["count"],
      "timestamp" =>
        event["eventTime"] ||
          event["lastTimestamp"] ||
          get_in(event, ["metadata", "creationTimestamp"]),
      "involved_object" => event["involvedObject"] || event["regarding"]
    }
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
