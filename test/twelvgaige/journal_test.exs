defmodule Twelvgaige.JournalTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shot.Attempt
  alias Twelvgaige.Shot.AttemptJournal
  alias Twelvgaige.Error
  alias Twelvgaige.Tool.Idempotency
  alias Twelvgaige.Tool.IntentJournal

  defmodule WriteTool do
    @behaviour Twelvgaige.Tool

    def name, do: "write_test"
    def description, do: "write test"
    def input_schema, do: %{"type" => "object"}
    def safety_level, do: :idempotent_write

    def idempotency,
      do:
        Idempotency.idempotent(
          requires_key?: true,
          reconciliation_strategy: :external_id,
          side_effect_phase: :before_result
        )

    def execute(_input, _opts), do: {:ok, %{}}
  end

  defmodule KubeExecTool do
    @behaviour Twelvgaige.Tool

    def name, do: "kubectl_exec"
    def description, do: "exec test"
    def input_schema, do: %{"type" => "object"}
    def safety_level, do: :irreversible

    def idempotency,
      do:
        Idempotency.non_idempotent(
          reconciliation_strategy: :manual,
          side_effect_phase: :unknown
        )

    def execute(_input, _opts), do: {:ok, %{}}
  end

  test "builds deterministic shot attempt journals" do
    attempt =
      Attempt.new(
        round_id: "round_1",
        shot_id: "apply",
        attempt: 2,
        definition: %{choke: %{tool_safety: :idempotent_write}},
        loadout: %{provider: :mock},
        input: %{},
        dependency_outputs: %{}
      )

    journal = AttemptJournal.new(attempt, now: ~U[2026-05-01 12:00:00Z])

    assert journal.round_id == "round_1"
    assert journal.shot_id == "apply"
    assert journal.attempt == 2
    assert journal.status == :started
    assert journal.safety_level == :idempotent_write
    assert journal.idempotency_metadata.requires_tool_intents

    assert %{
             event_type: :shot_attempt_started,
             payload: %{attempt: 2, safety_level: :idempotent_write}
           } = AttemptJournal.audit_event(journal)

    finished =
      AttemptJournal.finish(attempt, :completed, {:ok, %{tool_calls: [%{}], usage: %{total: 4}}},
        now: ~U[2026-05-01 12:01:00Z]
      )

    assert finished.status == :completed
    assert finished.result.tool_call_count == 1
    assert finished.result.usage == %{total: 4}

    assert %{
             event_type: :shot_attempt_finished,
             payload: %{attempt: 2, status: :completed}
           } = AttemptJournal.audit_event(finished)
  end

  test "builds deterministic tool intent journals" do
    journal =
      IntentJournal.new(WriteTool, %{"idempotency_key" => "key-1", "password" => "secret"},
        context: %{
          round_id: "round_1",
          shot_id: "apply",
          attempt: 2,
          tool_call_id: "call_1"
        },
        now: ~U[2026-05-01 12:00:00Z]
      )

    assert journal.id == "call_1"
    assert journal.round_id == "round_1"
    assert journal.shot_id == "apply"
    assert journal.attempt == 2
    assert journal.tool_name == "write_test"
    assert journal.safety_level == :idempotent_write
    assert journal.idempotency_key == "key-1"
    assert journal.input["password"] == "[REDACTED]"
    assert journal.idempotency.class == :idempotent
    assert journal.reconciliation_strategy == :external_id

    assert %{
             event_type: :tool_intent_recorded,
             payload: %{
               tool_call_id: "call_1",
               tool_name: "write_test",
               idempotency_key: "key-1"
             }
           } = IntentJournal.audit_event(journal)

    result =
      IntentJournal.result(
        WriteTool,
        %{"idempotency_key" => "key-1"},
        {:ok, %{"ok" => true, "token" => "secret"}},
        context: %{
          round_id: "round_1",
          shot_id: "apply",
          attempt: 2,
          tool_call_id: "call_1"
        },
        now: ~U[2026-05-01 12:01:00Z]
      )

    assert result.status == :observed_result
    assert result.output == %{"ok" => true, "token" => "[REDACTED]"}

    assert %{
             event_type: :tool_result_recorded,
             payload: %{tool_call_id: "call_1", status: :observed_result}
           } = IntentJournal.audit_event(result)
  end

  test "tool audit events include Kubernetes target metadata without raw output" do
    context = %{
      round_id: "round_1",
      shot_id: "exec",
      attempt: 1,
      tool_call_id: "call_kube"
    }

    intent =
      IntentJournal.new(
        KubeExecTool,
        %{
          "context" => "kind-dev",
          "namespace" => "payments",
          "resource" => "pods",
          "name" => "api-123",
          "container" => "api",
          "command" => ["printenv", "TOKEN=canary-secret"],
          "confirm" => true,
          "token" => "canary-secret"
        },
        context: context,
        now: ~U[2026-05-01 12:00:00Z]
      )

    assert %{
             payload: %{
               input: %{
                 "context" => "kind-dev",
                 "namespace" => "payments",
                 "resource" => "pods",
                 "name" => "api-123",
                 "container" => "api",
                 "command" => ["printenv", "TOKEN=[REDACTED]"],
                 "confirm" => true
               }
             }
           } = IntentJournal.audit_event(intent)

    result =
      IntentJournal.result(
        KubeExecTool,
        %{},
        {:ok,
         %{
           "context" => "kind-dev",
           "namespace" => "payments",
           "resource" => "pods",
           "name" => "api-123",
           "container" => "api",
           "command" => ["printenv", "TOKEN=canary-secret"],
           "verb" => "exec",
           "duration_ms" => 12,
           "exit_status" => 0,
           "truncated" => true,
           "output_bytes" => 4096,
           "text_excerpt" => "TOKEN=canary-secret"
         }},
        context: context,
        now: ~U[2026-05-01 12:01:00Z]
      )

    audit = IntentJournal.audit_event(result)

    assert audit.payload.output == %{
             "command" => ["printenv", "TOKEN=[REDACTED]"],
             "container" => "api",
             "context" => "kind-dev",
             "duration_ms" => 12,
             "exit_status" => 0,
             "name" => "api-123",
             "namespace" => "payments",
             "output_bytes" => 4096,
             "resource" => "pods",
             "truncated" => true,
             "verb" => "exec"
           }

    refute inspect(audit) =~ "text_excerpt"
    refute inspect(audit) =~ "canary-secret"
  end

  test "redacts sensitive attempt failure summaries" do
    attempt =
      Attempt.new(
        round_id: "round_1",
        shot_id: "apply",
        attempt: 1,
        definition: %{},
        loadout: %{provider: :mock},
        input: %{},
        dependency_outputs: %{}
      )

    error =
      Error.new(:tool_error, :tool_non_retryable, "token=secret", details: %{password: "secret"})

    journal = AttemptJournal.finish(attempt, :failed, {:error, error})

    assert journal.result.error.message == "token=[REDACTED]"
    assert journal.result.error.details.password == "[REDACTED]"
  end
end
