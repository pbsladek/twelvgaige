defmodule Twelvgaige.Log.JSONTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Error
  alias Twelvgaige.Log.JSON

  @timestamp ~U[2026-05-01 12:00:00.000000Z]

  test "formats required structured log fields as a json line" do
    line =
      JSON.format(
        :info,
        :shot_completed,
        "shot completed",
        [round_id: "round_1", shot_id: "inspect", attempt: 1, status: :complete],
        timestamp: @timestamp
      )

    assert String.ends_with?(line, "\n")

    assert Jason.decode!(line) == %{
             "timestamp" => "2026-05-01T12:00:00.000000Z",
             "level" => "info",
             "event" => "shot_completed",
             "message" => "shot completed",
             "round_id" => "round_1",
             "shot_id" => "inspect",
             "attempt" => 1,
             "status" => "complete"
           }
  end

  test "redacts secrets before encoding" do
    log =
      JSON.to_map(:warn, :daemon_auth_failed, "auth failed",
        authorization: "Bearer abc123",
        nested: %{password: "secret", note: "api_key=abc123"}
      )

    assert log["authorization"] == "[REDACTED]"
    assert log["nested"]["password"] == "[REDACTED]"
    assert log["nested"]["note"] == "api_key=[REDACTED]"
  end

  test "omits raw prompt and tool output fields" do
    log =
      JSON.to_map(:debug, :shot_debug, "debug",
        prompt: "raw prompt",
        messages: [%{role: "user", content: "secret"}],
        tool_output: "raw stdout",
        safe_preview: "bounded"
      )

    assert log["prompt"] == "[OMITTED]"
    assert log["messages"] == "[OMITTED]"
    assert log["tool_output"] == "[OMITTED]"
    assert log["safe_preview"] == "bounded"
  end

  test "expands Twelvgaige errors into queryable fields" do
    error =
      Error.new(:tool_error, :tool_denied, "tool denied",
        retryable: false,
        safety_required: true
      )

    log = JSON.to_map(:error, :shot_failed, "shot failed", error: error)

    assert log["error_class"] == "tool_error"
    assert log["error_reason"] == "tool_denied"
    assert log["error_retryable"] == false
    assert log["error_safety_required"] == true
    refute Map.has_key?(log, "error")
  end
end
