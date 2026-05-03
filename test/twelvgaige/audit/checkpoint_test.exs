defmodule Twelvgaige.Audit.CheckpointTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Audit.Checkpoint

  test "exports and verifies a deterministic audit hash chain" do
    events = [
      %{
        seq: 1,
        event_type: :round_created,
        round_id: "round_1",
        payload: %{status: :queued},
        occurred_at: ~U[2026-05-01 12:00:00Z]
      },
      %{
        seq: 2,
        event_type: :round_completed,
        round_id: "round_1",
        payload: %{status: :complete}
      }
    ]

    checkpoint = Checkpoint.export(events, now: ~U[2026-05-01 12:01:00Z])

    assert checkpoint["kind"] == "twelvgaige.audit.checkpoint"
    assert checkpoint["algorithm"] == "sha256-chain-v1"
    assert checkpoint["round_id"] == "round_1"
    assert checkpoint["event_count"] == 2
    assert checkpoint["first_seq"] == 1
    assert checkpoint["last_seq"] == 2
    assert checkpoint["generated_at"] == "2026-05-01T12:01:00Z"
    assert is_binary(checkpoint["root_hash"])

    assert [%{"previous_hash" => first_previous, "event_hash" => first_hash}, second] =
             checkpoint["events"]

    assert first_previous == String.duplicate("0", 64)
    assert second["previous_hash"] == first_hash
    assert :ok = Checkpoint.verify(checkpoint)
  end

  test "verification detects event mutation after export" do
    checkpoint =
      Checkpoint.export([
        %{seq: 1, event_type: :round_created, round_id: "round_1", payload: %{status: :queued}}
      ])

    mutated = put_in(checkpoint, ["events", Access.at(0), "payload", "status"], "complete")

    assert {:error, {:event_hash_mismatch, 1}} = Checkpoint.verify(mutated)
  end

  test "verification detects removed events" do
    checkpoint =
      Checkpoint.export([
        %{seq: 1, event_type: :round_created, round_id: "round_1"},
        %{seq: 2, event_type: :round_completed, round_id: "round_1"}
      ])

    mutated = %{checkpoint | "events" => [List.first(checkpoint["events"])]}

    assert {:error, :event_count_mismatch} = Checkpoint.verify(mutated)
  end

  test "export redacts canary secrets before hashing and output" do
    checkpoint =
      Checkpoint.export([
        %{
          seq: 1,
          event_type: :tool_result_recorded,
          round_id: "round_1",
          payload: %{token: "canary-secret", stdout: "Authorization: Bearer canary-secret"}
        }
      ])

    assert [event] = checkpoint["events"]
    assert event["payload"]["token"] == "[REDACTED]"
    assert event["payload"]["stdout"] == "Authorization: Bearer [REDACTED]"
    assert :ok = Checkpoint.verify(checkpoint)
    refute inspect(checkpoint) =~ "canary-secret"
  end
end
