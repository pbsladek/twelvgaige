defmodule Twelvgaige.RoundRecordTest do
  use ExUnit.Case, async: true

  test "renders deterministically from immutable events" do
    events = [
      %{
        seq: 2,
        event_type: :round_completed,
        payload: %{status: :complete},
        occurred_at: "later"
      },
      %{seq: 1, event_type: :round_started, payload: %{}, occurred_at: "earlier"}
    ]

    record = Twelvgaige.RoundRecord.render(events, title: "Review")
    assert record =~ "# Review"
    assert record =~ "1. `round_started`"
    assert record =~ "2. `round_completed`"

    assert elem(:binary.match(record, "round_started"), 0) <
             elem(:binary.match(record, "round_completed"), 0)
  end
end
