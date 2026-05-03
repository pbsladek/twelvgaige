defmodule Twelvgaige.Round.RecoveryTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Round.Recovery
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Shot

  @now ~U[2026-05-01 12:00:00Z]

  test "resumes version-zero rounds that have not committed shot progress" do
    snapshot =
      snapshot(
        status: :queued,
        version: 0,
        shots: [%{id: "only", kind: :slug, status: :pending}]
      )

    assert {:resume, ^snapshot} = Recovery.reconcile(snapshot, now: @now)
  end

  test "keeps awaiting-safety rounds paused" do
    snapshot =
      snapshot(
        status: :awaiting_safety,
        awaiting_safety: [%{"shot_id" => "approval"}],
        shots: [%{id: "approval", kind: :safety, status: :awaiting_safety}]
      )

    assert {:keep, ^snapshot} = Recovery.reconcile(snapshot, now: @now)
  end

  test "marks interrupted no-tool shots retryable" do
    snapshot =
      snapshot(
        status: :firing,
        version: 1,
        shots: [
          %{id: "a", kind: :slug, status: :complete, output: %{"ok" => true}},
          %{id: "b", kind: :slug, status: :running, attempt: 1}
        ]
      )

    assert {:commit_and_resume, reconciled} = Recovery.reconcile(snapshot, now: @now)
    assert reconciled.status == :firing
    assert reconciled.awaiting_safety == []
    refute reconciled.error

    shots = Map.new(reconciled.shots, &{&1.id, &1})
    assert shots["a"].status == :complete
    assert shots["b"].status == :retrying
    assert shots["b"].error.reason == :shot_crash
    assert shots["b"].error.retryable
    assert shots["b"].next_retry_at == @now

    assert [%{status: :interrupted, attempt: 1, recovery_action: :retry_no_tool}] =
             shots["b"].history
  end

  test "idempotent write tool intents with keys are retryable" do
    snapshot =
      snapshot(
        status: :firing,
        version: 1,
        shots: [%{id: "apply", kind: :slug, status: :running, attempt: 1}]
      )

    journals = %{
      tools: [
        %{
          round_id: "round_recovery",
          shot_id: "apply",
          attempt: 1,
          id: "tool_1",
          status: :intent_recorded,
          safety_level: :idempotent_write,
          idempotency_key: "apply-round-recovery",
          idempotency: %{class: :idempotent}
        }
      ]
    }

    assert {:commit_and_resume, recovered} =
             Recovery.reconcile(snapshot, now: @now, journals: journals)

    assert [%{status: :retrying, error: %{details: %{recovery_action: :retry_idempotent_write}}}] =
             recovered.shots
  end

  test "write tool intents without idempotency keys require reconciliation" do
    snapshot =
      snapshot(
        status: :firing,
        version: 1,
        shots: [
          %{id: "a", kind: :slug, status: :complete, output: %{"ok" => true}},
          %{id: "b", kind: :slug, status: :running, attempt: 1}
        ]
      )

    journals = %{
      tools: [
        %{
          round_id: "round_recovery",
          shot_id: "b",
          attempt: 1,
          id: "tool_1",
          status: :intent_recorded,
          safety_level: :idempotent_write,
          idempotency: %{class: :idempotent}
        }
      ]
    }

    assert {:commit, reconciled} = Recovery.reconcile(snapshot, now: @now, journals: journals)
    assert reconciled.status == :awaiting_reconciliation
    assert reconciled.awaiting_safety == []
    assert reconciled.error.reason == :shot_crash
    assert reconciled.error.safety_required

    shots = Map.new(reconciled.shots, &{&1.id, &1})
    assert shots["a"].status == :complete
    assert shots["b"].status == :awaiting_reconciliation
    assert shots["b"].error.reason == :shot_crash
    assert shots["b"].completed_at == @now

    assert [%{action: :manual_reconciliation}] =
             reconciled.error.details.journal_summary.shot_recovery
  end

  test "includes journal evidence in reconciliation errors" do
    snapshot =
      snapshot(
        status: :firing,
        version: 1,
        shots: [%{id: "apply", kind: :slug, status: :running, attempt: 1}]
      )

    journals = %{
      attempts: [
        %{round_id: "round_recovery", shot_id: "apply", attempt: 1, status: :started}
      ],
      tools: [
        %{
          round_id: "round_recovery",
          shot_id: "apply",
          attempt: 1,
          id: "tool_1",
          status: :observed_result,
          safety_level: :idempotent_write,
          idempotency: %{class: :idempotent}
        }
      ]
    }

    assert {:commit, reconciled} = Recovery.reconcile(snapshot, now: @now, journals: journals)
    summary = reconciled.error.details.journal_summary

    assert summary.attempt_count == 1
    assert summary.tool_journal_count == 1
    assert summary.observed_tool_results == 1
    assert summary.write_intents == 1
    assert summary.affected_shots == ["apply"]
  end

  test "terminal snapshots are left unchanged" do
    snapshot = snapshot(status: :complete)

    assert {:keep, ^snapshot} = Recovery.reconcile(snapshot, now: @now)
  end

  defp snapshot(attrs) do
    defaults = [
      id: "round_recovery",
      shell_id: "workflow",
      shell_version: "1.0.0",
      shots: [%{id: "only", kind: :slug, status: :pending}]
    ]

    defaults
    |> Keyword.merge(attrs)
    |> Keyword.update!(:shots, &Enum.map(&1, fn attrs -> Shot.State.new(attrs) end))
    |> Snapshot.new()
  end
end
