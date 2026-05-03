defmodule Twelvgaige.Audit.EventTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Audit.Event
  alias Twelvgaige.Error

  test "sanitizes audit records before persistence while preserving audit shape" do
    event = %{
      event_type: :tool_result_recorded,
      round_id: "round_1",
      payload: %{
        authorization: "Bearer abc123",
        stdout: "password=secret",
        nested: %{client_secret: "raw"}
      },
      occurred_at: ~U[2026-05-01 12:00:00Z]
    }

    assert %{
             event_type: :tool_result_recorded,
             payload: %{
               authorization: "[REDACTED]",
               stdout: "password=[REDACTED]",
               nested: %{client_secret: "[REDACTED]"}
             },
             occurred_at: ~U[2026-05-01 12:00:00Z]
           } = Event.sanitize(event)
  end

  test "redacts errors and emits JSON-safe maps for CLI and API output" do
    error =
      Error.new(:tool_error, :tool_non_retryable, "api_key=abc",
        details: %{token: "raw", note: "Bearer xyz"}
      )

    event = %{
      event_type: :shot_failed,
      error: error,
      occurred_at: ~U[2026-05-01 12:00:00Z]
    }

    assert %{
             "event_type" => "shot_failed",
             "error" => %{
               "message" => "api_key=[REDACTED]",
               "details" => %{"token" => "[REDACTED]", "note" => "Bearer [REDACTED]"}
             },
             "occurred_at" => "2026-05-01T12:00:00Z"
           } = Event.to_map(event)
  end
end
