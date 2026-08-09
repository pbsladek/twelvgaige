defmodule Twelvgaige.Event.BufferTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Event.Buffer

  test "coalesces delta floods and reserves capacity for cancellation" do
    buffer = Buffer.new(capacity: 8, critical_reserve: 2)

    buffer =
      Enum.reduce(1..10_000, buffer, fn index, buffer ->
        {:ok, buffer} =
          Buffer.push(buffer, %{event_type: :text_delta, shot_id: "worker", index: index})

        buffer
      end)

    assert Buffer.size(buffer) == 1

    assert {:ok, buffer} = Buffer.push(buffer, %{event_type: :round_cancelled})
    assert {:ok, %{event_type: :round_cancelled}, buffer} = Buffer.pop(buffer)
    assert {:ok, %{index: 10_000}, _buffer} = Buffer.pop(buffer)
  end

  test "signals operational overload without consuming critical reserve" do
    buffer = Buffer.new(capacity: 4, critical_reserve: 2)
    {:ok, buffer} = Buffer.push(buffer, %{event_type: :tool_started})
    {:ok, buffer} = Buffer.push(buffer, %{event_type: :tool_finished})

    assert {:overload, buffer, :operational_capacity_exhausted} =
             Buffer.push(buffer, %{event_type: :command_started})

    assert {:ok, buffer} = Buffer.push(buffer, %{event_type: :approval_requested})
    assert {:ok, %{event_type: :approval_requested}, _buffer} = Buffer.pop(buffer)
  end
end
