defmodule Twelvgaige.API.EventStreamTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.API.EventStream

  test "encodes one json object per lf-terminated line" do
    body =
      EventStream.ndjson([
        %{seq: 1, event_type: "round_started"},
        %{seq: 2, event_type: "round_completed"}
      ])

    assert String.ends_with?(body, "\n")

    assert body
           |> String.split("\n", trim: true)
           |> Enum.map(&Jason.decode!/1) == [
             %{"seq" => 1, "event_type" => "round_started"},
             %{"seq" => 2, "event_type" => "round_completed"}
           ]
  end

  test "empty streams encode to an empty body" do
    assert EventStream.ndjson([]) == ""
  end

  test "encodes server-sent events with id, event, and json data" do
    body =
      EventStream.sse([
        %{"seq" => 7, "event_type" => "round_completed", "payload" => %{"status" => "complete"}}
      ])

    assert body =~ "id: 7\n"
    assert body =~ "event: round_completed\n"
    assert body =~ ~s(data: {"event_type":"round_completed")
    assert String.ends_with?(body, "\n\n")
  end

  test "encodes heartbeat comments for idle sse streams" do
    assert EventStream.heartbeat() == ": heartbeat\n\n"
  end

  test "maps replay events to CloudEvents batch records" do
    [event] =
      EventStream.cloud_events(
        [
          %{
            "round_id" => "round_1",
            "seq" => 2,
            "event_type" => "round_completed",
            "occurred_at" => "2026-05-02T00:00:00Z",
            "payload" => %{"status" => "complete"}
          }
        ],
        kind: :round
      )

    assert event["specversion"] == "1.0"
    assert event["id"] == "round_1:2"
    assert event["source"] == "/twelvgaige/rounds/round_1"
    assert event["type"] == "dev.twelvgaige.round.round_completed"
    assert event["time"] == "2026-05-02T00:00:00Z"
    assert event["datacontenttype"] == "application/json"
    assert event["data"]["payload"]["status"] == "complete"
  end
end
