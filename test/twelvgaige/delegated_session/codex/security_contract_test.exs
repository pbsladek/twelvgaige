defmodule Twelvgaige.DelegatedSession.Codex.SecurityContractTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession.Codex.{Approval, EventCodec}
  alias Twelvgaige.Integration.Codex

  @key "codex-security-contract-key"
  @now ~U[2026-08-09 00:00:00Z]

  test "approval receipts fail closed for every identity, decision, expiry, and MAC mismatch" do
    intent =
      Approval.intent(
        %{
          "id" => "approval-1",
          "method" => "item/commandExecution/requestApproval",
          "session_id" => "session-1",
          "thread_id" => "thread-1",
          "turn_id" => "turn-1",
          "native_request_id" => "rpc-1",
          "params" => %{"command" => ["mix", "test"]},
          "expires_at" => DateTime.add(@now, 60, :second)
        },
        @key
      )

    receipt = Approval.receipt(intent, :accept_for_session, "operator", @key, now: @now)
    assert :ok = Approval.verify(intent, receipt, @key, now: @now)

    assert {:error, :approval_intent_invalid} =
             Approval.verify(%{intent | intent_mac: :invalid}, receipt, @key, now: @now)

    assert {:error, :approval_digest_mismatch} =
             Approval.verify(intent, %{receipt | intent_id: "other"}, @key, now: @now)

    assert {:error, :approval_decision_invalid} =
             Approval.verify(intent, %{receipt | decision: :invalid}, @key, now: @now)

    assert {:error, :approval_expired} =
             Approval.verify(intent, receipt, @key, now: intent.expires_at)

    assert {:error, :approval_receipt_invalid} =
             Approval.verify(intent, %{receipt | receipt_mac: "invalid"}, @key, now: @now)

    assert Approval.native_decision(:accept) == "accept"
    assert Approval.native_decision(:accept_for_session) == "acceptForSession"
    assert Approval.native_decision(:decline) == "decline"
    assert Approval.native_decision(:cancel) == "cancel"
  end

  test "stable notifications normalize every lifecycle class and redact nested secrets" do
    context = %{session_id: "session-1", thread_id: "thread-1", emitted_at_ms: 1_000}

    cases = [
      {"error", %{}, :session_failed, :critical},
      {"thread/started", %{"thread" => %{"id" => "thread-2"}}, :session_started, :operational},
      {"thread/closed", %{}, :session_stopped, :critical},
      {"turn/started", %{"turn" => %{"id" => "turn-1"}}, :turn_started, :operational},
      {"turn/completed", %{}, :turn_completed, :critical},
      {"turn/plan/updated", %{}, :plan_updated, :operational},
      {"item/plan/delta", %{}, :plan_updated, :presentation},
      {"item/agentMessage/delta", %{}, :message_delta, :presentation},
      {"thread/tokenUsage/updated", %{}, :usage_updated, :operational},
      {"turn/diff/updated", %{}, :artifact_created, :operational},
      {"item/commandExecution/requestApproval", %{"itemId" => "approval"}, :approval_required,
       :critical},
      {"item/fileChange/requestApproval", %{"itemId" => "approval"}, :approval_required,
       :critical},
      {"item/permissions/requestApproval", %{"itemId" => "approval"}, :approval_required,
       :critical},
      {"mcpServer/elicitation/request", %{"itemId" => "approval"}, :approval_required, :critical},
      {"item/started", %{"item" => %{"id" => "sub", "type" => "subAgentActivity"}},
       :subagent_started, :operational},
      {"item/completed", %{"item" => %{"id" => "sub", "type" => "collabAgentToolCall"}},
       :subagent_finished, :operational},
      {"item/started", %{"item" => %{"id" => "tool", "type" => "commandExecution"}},
       :tool_started, :operational},
      {"item/completed", %{"item" => %{"id" => "tool", "type" => "commandExecution"}},
       :tool_finished, :operational},
      {"process/exited", %{}, :tool_finished, :operational}
    ]

    Enum.each(cases, fn {method, params, expected_type, expected_class} ->
      assert {:ok, event} = EventCodec.decode(method, params, context)
      assert event.event_type == expected_type
      assert event.event_class == expected_class
      assert DateTime.to_unix(event.occurred_at, :millisecond) == 1_000
      assert is_binary(event.native_event_id)
    end)

    assert :ignore = EventCodec.decode("unknown/notification", %{}, context)

    assert {:ok, redacted} =
             EventCodec.decode(
               "turn/completed",
               %{
                 "turnId" => "turn-2",
                 "authorization" => "Bearer secret",
                 "nested" => [%{"api_key" => "secret", "at" => @now}]
               },
               %{session_id: "session-1"}
             )

    assert redacted.native_turn_id == "turn-2"
    assert redacted.payload["authorization"] == "[REDACTED]"
    assert get_in(redacted.payload, ["nested", Access.at(0), "api_key"]) == "[REDACTED]"
    assert get_in(redacted.payload, ["nested", Access.at(0), "at"]) == DateTime.to_iso8601(@now)
  end

  test "Codex integration descriptor is pinned and artifact verification fails closed" do
    descriptor = Codex.descriptor()
    assert descriptor.support_status == :supported
    assert descriptor.capabilities.structured_protocol
    assert descriptor.capabilities.experimental_api == false

    path = Path.join(System.tmp_dir!(), "codex-artifact-#{System.unique_integer([:positive])}")
    File.write!(path, "not-the-pinned-codex-binary")
    on_exit(fn -> File.rm(path) end)

    assert {:error, :codex_artifact_digest_mismatch} = Codex.verify_artifact(path)

    assert {:error, {:codex_artifact_unreadable, :enoent}} =
             Codex.verify_artifact(path <> ".missing")
  end
end
