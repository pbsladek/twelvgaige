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

  test "verification detects reordered events" do
    checkpoint =
      Checkpoint.export([
        %{seq: 1, event_type: :round_created, round_id: "round_1"},
        %{seq: 2, event_type: :shot_attempt_started, round_id: "round_1"},
        %{seq: 3, event_type: :round_completed, round_id: "round_1"}
      ])

    mutated = %{checkpoint | "events" => Enum.reverse(checkpoint["events"])}

    assert {:error, {:previous_hash_mismatch, 3}} = Checkpoint.verify(mutated)
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

  test "signs checkpoint exports with an optional HMAC block" do
    checkpoint =
      Checkpoint.export([
        %{seq: 1, event_type: :round_created, round_id: "round_1", payload: %{status: :queued}}
      ])

    assert {:ok, signed} =
             Checkpoint.sign_hmac(checkpoint, "secret",
               key_ref: "TWELVGAIGE_AUDIT_HMAC_KEY",
               now: ~U[2026-05-01 12:02:00Z]
             )

    assert signed["signature"]["algorithm"] == "hmac-sha256-v1"
    assert signed["signature"]["key_ref"] == "TWELVGAIGE_AUDIT_HMAC_KEY"
    assert signed["signature"]["signed_at"] == "2026-05-01T12:02:00Z"
    assert signed["signature"]["signature"] =~ "base64:"
    assert :ok = Checkpoint.verify(signed)
    assert :ok = Checkpoint.verify_hmac(signed, "secret")
    assert {:error, :hmac_signature_mismatch} = Checkpoint.verify_hmac(signed, "wrong")
  end

  test "HMAC verification detects signature removal and signed content mutation" do
    checkpoint =
      Checkpoint.export([
        %{seq: 1, event_type: :round_created, round_id: "round_1", payload: %{status: :queued}}
      ])

    assert {:ok, signed} = Checkpoint.sign_hmac(checkpoint, "secret")

    assert {:error, :missing_signature} =
             Checkpoint.verify_hmac(Map.delete(signed, "signature"), "secret")

    mutated = %{signed | "generated_at" => "2026-05-01T00:00:00Z"}

    assert :ok = Checkpoint.verify(mutated)
    assert {:error, :hmac_signature_mismatch} = Checkpoint.verify_hmac(mutated, "secret")
  end
end
