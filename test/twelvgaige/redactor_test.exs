defmodule Twelvgaige.RedactorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor

  test "redacts common secret text and structured keys" do
    assert Redactor.redact_text("Authorization: Bearer abc123") ==
             "Authorization: Bearer [REDACTED]"

    assert Redactor.redact_json(%{"token" => "abc", "nested" => %{"password" => "secret"}}) ==
             %{"token" => "[REDACTED]", "nested" => %{"password" => "[REDACTED]"}}

    assert Redactor.redact_json(%{"cookie" => "session", "credential" => "raw"}) ==
             %{"cookie" => "[REDACTED]", "credential" => "[REDACTED]"}
  end

  test "redacts JSON-shaped secrets inside text without hiding token counters" do
    text = ~s(Context: {"token":"canary-secret","cluster":"dev"})

    assert Redactor.redact_text(text) ==
             ~s(Context: {"token":"[REDACTED]","cluster":"dev"})

    assert Redactor.redact_json(%{
             "usage" => %{"input_tokens" => 12, "output_tokens" => 4, "total_tokens" => 16}
           }) == %{
             "usage" => %{"input_tokens" => 12, "output_tokens" => 4, "total_tokens" => 16}
           }
  end

  test "summarizes sensitive payload fields after redaction" do
    summarized =
      Redactor.summarize_sensitive_payloads(%{
        id: "journal_1",
        input: %{token: "canary-secret", command: "run"},
        output: "Bearer canary-secret",
        metadata: %{safe: true}
      })

    assert summarized.id == "journal_1"

    assert summarized.input == %{
             "summary" => "omitted",
             "type" => "object",
             "keys" => ["command", "token"]
           }

    assert summarized.output == %{
             "summary" => "omitted",
             "type" => "string",
             "bytes" => byte_size("Bearer [REDACTED]")
           }

    assert summarized.metadata == %{safe: true}
    refute inspect(summarized) =~ "canary-secret"
  end

  test "redacts error details while preserving non-secret structs and token counters" do
    now = DateTime.utc_now()

    redacted =
      Error.new(:tool_error, :tool_non_retryable, "token=raw-secret",
        details: %{
          "authorization" => "Bearer raw-secret",
          "usage" => %{"tokens" => 10, "token_budget" => 50},
          "occurred_at" => now
        }
      )
      |> Redactor.redact_json()

    assert redacted.message == "token=[REDACTED]"
    assert redacted.details["authorization"] == "[REDACTED]"
    assert redacted.details["usage"] == %{"tokens" => 10, "token_budget" => 50}
    assert redacted.details["occurred_at"] == now
  end

  test "summarizes arrays and scalar payload fields with stable type metadata" do
    assert Redactor.summarize_sensitive_payloads(%{messages: [%{role: "user"}]}) == %{
             messages: %{"summary" => "omitted", "type" => "array", "items" => 1}
           }

    assert Redactor.summarize_sensitive_payloads(%{"raw" => 123}) == %{
             "raw" => %{"summary" => "omitted", "type" => "integer"}
           }

    assert Redactor.summarize_sensitive_payloads(%{stdout: nil}) == %{stdout: nil}
  end
end
