defmodule Twelvgaige.API.EventStream do
  @moduledoc """
  Event stream encoding helpers for transport adapters.

  The pure router can replay stored events as NDJSON or bounded SSE responses.
  A concrete HTTP listener can reuse this framing for chunked responses and add
  slow-client handling at the socket boundary.
  """

  @ndjson_content_type "application/x-ndjson; charset=utf-8"
  @sse_content_type "text/event-stream; charset=utf-8"
  @cloud_events_content_type "application/cloudevents-batch+json; charset=utf-8"

  @spec ndjson_content_type() :: String.t()
  def ndjson_content_type, do: @ndjson_content_type

  @spec sse_content_type() :: String.t()
  def sse_content_type, do: @sse_content_type

  @spec cloud_events_content_type() :: String.t()
  def cloud_events_content_type, do: @cloud_events_content_type

  @spec ndjson([map()]) :: String.t()
  def ndjson(events) when is_list(events) do
    Enum.map_join(events, "", fn event -> Jason.encode!(event) <> "\n" end)
  end

  @spec sse([map()]) :: String.t()
  def sse(events) when is_list(events) do
    Enum.map_join(events, "", &sse_event/1)
  end

  @spec heartbeat() :: String.t()
  def heartbeat, do: ": heartbeat\n\n"

  @spec cloud_events([map()], keyword()) :: [map()]
  def cloud_events(events, opts \\ []) when is_list(events) do
    kind = Keyword.get(opts, :kind, :event)
    Enum.map(events, &cloud_event(&1, kind))
  end

  defp sse_event(%{} = event) do
    [
      sse_field("id", Map.get(event, :seq, Map.get(event, "seq"))),
      sse_field("event", Map.get(event, :event_type, Map.get(event, "event_type"))),
      sse_data(event),
      "\n"
    ]
  end

  defp sse_field(_name, nil), do: []
  defp sse_field(name, value), do: [name, ": ", to_string(value), "\n"]

  defp sse_data(event) do
    event
    |> Jason.encode!()
    |> String.split("\n")
    |> Enum.map(fn line -> ["data: ", line, "\n"] end)
  end

  defp cloud_event(%{} = event, kind) do
    round_id = value(event, :round_id)
    seq = value(event, :seq)
    event_type = value(event, :event_type, "event")
    id = value(event, :id) || value(event, :transition_id) || cloud_event_id(round_id, seq)

    %{
      "specversion" => "1.0",
      "id" => to_string(id),
      "source" => cloud_event_source(round_id, kind),
      "type" => "dev.twelvgaige.#{kind}.#{event_type}",
      "datacontenttype" => "application/json",
      "data" => event
    }
    |> maybe_put("subject", value(event, :shot_id))
    |> maybe_put("time", value(event, :occurred_at))
  end

  defp cloud_event_id(nil, nil), do: "event"
  defp cloud_event_id(round_id, nil), do: round_id
  defp cloud_event_id(nil, seq), do: seq
  defp cloud_event_id(round_id, seq), do: "#{round_id}:#{seq}"

  defp cloud_event_source(nil, kind), do: "/twelvgaige/#{kind}"
  defp cloud_event_source(round_id, _kind), do: "/twelvgaige/rounds/#{round_id}"

  defp value(map, key, default \\ nil)

  defp value(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
