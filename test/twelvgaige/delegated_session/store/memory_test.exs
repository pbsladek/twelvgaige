defmodule Twelvgaige.DelegatedSession.Store.MemoryTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.DelegatedSession.Event
  alias Twelvgaige.DelegatedSession.Store.Memory

  test "deduplicates native identity plus digest and replays by cursor" do
    start_supervised!({Memory, max_events_per_session: 2})

    event =
      Event.new(
        session_id: "sess_1",
        seq: 1,
        event_type: :session_started,
        native_session_id: "native_1",
        native_event_id: "event_1",
        payload: %{},
        occurred_at: DateTime.utc_now()
      )

    assert :ok = Memory.append_event(event)
    assert :duplicate = Memory.append_event(event)
    assert {:ok, [^event]} = Memory.list_events("sess_1", after_seq: 0)
    assert {:ok, []} = Memory.list_events("sess_1", after_seq: 1)
  end
end
