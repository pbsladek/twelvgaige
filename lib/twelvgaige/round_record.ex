defmodule Twelvgaige.RoundRecord do
  @moduledoc "Regenerates a human-readable record solely from immutable normalized events."

  def render(events, opts \\ []) when is_list(events) do
    title = Keyword.get(opts, :title, "Twelvgaige round record")

    lines =
      events
      |> Enum.sort_by(&value(&1, :seq, 0))
      |> Enum.map(fn event ->
        seq = value(event, :seq, "?")
        type = value(event, :event_type, "unknown")
        occurred_at = value(event, :occurred_at, "unknown time")
        payload = value(event, :payload, %{})
        "- #{seq}. `#{type}` at #{format_time(occurred_at)} — #{payload_summary(payload)}"
      end)

    (["# #{title}", "", "Generated from #{length(events)} immutable events.", ""] ++ lines)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp payload_summary(payload) when map_size(payload) == 0, do: "no payload"

  defp payload_summary(payload) do
    payload
    |> Map.take([:status, "status", :message, "message", :summary, "summary"])
    |> case do
      values when map_size(values) == 0 -> "payload digest recorded"
      values -> Jason.encode!(values)
    end
  end

  defp format_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp format_time(value), do: to_string(value)

  defp value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, to_string(key), default))
end
