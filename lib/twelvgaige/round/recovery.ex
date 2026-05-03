defmodule Twelvgaige.Round.Recovery do
  @moduledoc """
  Pure restart reconciliation for durable round snapshots.

  Recovery never assumes old BEAM processes are alive. This module decides
  whether a durable incomplete snapshot may be resumed by the current Phase 4
  runner or must be held for manual reconciliation.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Shot

  @type decision ::
          {:resume, Snapshot.t()}
          | {:commit_and_resume, Snapshot.t()}
          | {:keep, Snapshot.t()}
          | {:commit, Snapshot.t()}

  @spec reconcile(Snapshot.t() | map(), keyword()) :: decision()
  def reconcile(snapshot, opts \\ [])

  def reconcile(%Snapshot{} = snapshot, opts) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
    journals = Keyword.get(opts, :journals, %{})

    cond do
      Snapshot.terminal?(snapshot) ->
        {:keep, snapshot}

      snapshot.status == :awaiting_safety ->
        {:keep, snapshot}

      resumable_from_start?(snapshot) ->
        {:resume, snapshot}

      retryable_recovery?(snapshot, journals) ->
        {:commit_and_resume, retry_snapshot(snapshot, now, journals)}

      true ->
        {:commit, reconciliation_snapshot(snapshot, now, journals)}
    end
  end

  def reconcile(%{} = snapshot, opts) do
    snapshot |> Snapshot.new() |> reconcile(opts)
  end

  defp resumable_from_start?(%Snapshot{} = snapshot) do
    snapshot.status in [:queued, :chambered, :firing] and
      snapshot.version == 0 and
      Enum.all?(snapshot.shots, &(&1.status == :pending))
  end

  defp retryable_recovery?(%Snapshot{} = snapshot, journals) do
    interrupted = interrupted_shots(snapshot)

    interrupted != [] and
      Enum.all?(interrupted, &(shot_recovery_action(&1, journals) in retryable_actions()))
  end

  defp retry_snapshot(%Snapshot{} = snapshot, now, journals) do
    %{
      snapshot
      | status: :firing,
        error: nil,
        awaiting_safety: [],
        shots: Enum.map(snapshot.shots, &retry_recoverable_shot(&1, now, journals))
    }
  end

  defp retry_recoverable_shot(%Shot.State{status: status} = shot, now, journals)
       when status in [:running, :interrupted, :awaiting_reconciliation] do
    case shot_recovery_action(shot, journals) do
      action when action in [:retry_no_tool, :retry_read_only, :retry_idempotent_write] ->
        %{
          shot
          | status: :retrying,
            error: retry_recovery_error(shot, action, now),
            next_retry_at: now,
            completed_at: nil,
            history: recovery_history(shot, action, now)
        }

      _other ->
        shot
    end
  end

  defp retry_recoverable_shot(%Shot.State{} = shot, _now, _journals), do: shot

  defp reconciliation_snapshot(%Snapshot{} = snapshot, now, journals) do
    error = recovery_error(snapshot, now, journals)

    %{
      snapshot
      | status: :awaiting_reconciliation,
        error: error,
        awaiting_safety: [],
        shots: Enum.map(snapshot.shots, &reconcile_shot(&1, error, now))
    }
  end

  defp reconcile_shot(%Shot.State{status: status} = shot, error, now)
       when status in [:running, :interrupted, :awaiting_reconciliation] do
    %{shot | status: :awaiting_reconciliation, error: error, completed_at: now}
  end

  defp reconcile_shot(%Shot.State{} = shot, _error, _now), do: shot

  defp recovery_error(%Snapshot{} = snapshot, now, journals) do
    Error.new(
      :crash_error,
      :shot_crash,
      "round requires reconciliation after daemon restart",
      safety_required: true,
      details: %{
        round_id: snapshot.id,
        previous_status: Atom.to_string(snapshot.status),
        recovered_at: DateTime.to_iso8601(now),
        journal_summary: journal_summary(snapshot, journals)
      }
    )
  end

  defp retry_recovery_error(%Shot.State{} = shot, action, now) do
    Error.new(:crash_error, :shot_crash, "shot interrupted by daemon restart",
      retryable: true,
      details: %{
        shot_id: shot.id,
        recovery_action: action,
        recovered_at: DateTime.to_iso8601(now)
      }
    )
  end

  defp recovery_history(%Shot.State{} = shot, action, now) do
    [
      %{
        status: :interrupted,
        attempt: shot.attempt,
        recovery_action: action,
        recovered_at: DateTime.to_iso8601(now)
      }
      | shot.history
    ]
  end

  defp journal_summary(snapshot, journals) do
    attempts = Map.get(journals, :attempts, Map.get(journals, "attempts", []))
    tools = Map.get(journals, :tools, Map.get(journals, "tools", []))

    %{
      attempt_count: length(attempts),
      tool_journal_count: length(tools),
      observed_tool_results: Enum.count(tools, &(journal_status(&1) == :observed_result)),
      failed_tool_results: Enum.count(tools, &(journal_status(&1) == :failed)),
      write_intents: Enum.count(tools, &write_intent?/1),
      affected_shots: affected_shots(attempts, tools),
      shot_recovery: shot_recovery(snapshot, journals)
    }
  end

  defp shot_recovery(%Snapshot{} = snapshot, journals) do
    snapshot
    |> interrupted_shots()
    |> Enum.map(fn shot ->
      %{
        shot_id: shot.id,
        attempt: shot.attempt,
        action: shot_recovery_action(shot, journals),
        reason: shot_recovery_reason(shot, journals)
      }
    end)
  end

  defp interrupted_shots(%Snapshot{} = snapshot) do
    Enum.filter(
      snapshot.shots,
      &(&1.status in [:running, :interrupted, :awaiting_reconciliation])
    )
  end

  defp shot_recovery_action(%Shot.State{} = shot, journals) do
    tools = journals |> tools_for_shot(shot) |> Enum.filter(&same_attempt?(&1, shot))

    cond do
      tools == [] ->
        :retry_no_tool

      Enum.all?(tools, &read_only_tool?/1) ->
        :retry_read_only

      Enum.all?(tools, &idempotent_retryable_tool?/1) ->
        :retry_idempotent_write

      true ->
        :manual_reconciliation
    end
  end

  defp shot_recovery_reason(%Shot.State{} = shot, journals) do
    tools = journals |> tools_for_shot(shot) |> Enum.filter(&same_attempt?(&1, shot))

    cond do
      tools == [] -> "no tool intents were recorded for the interrupted attempt"
      Enum.all?(tools, &read_only_tool?/1) -> "all recorded tools are read-only"
      Enum.all?(tools, &idempotent_retryable_tool?/1) -> "all write tools have idempotency keys"
      true -> "one or more recorded tool intents require manual reconciliation"
    end
  end

  defp retryable_actions, do: [:retry_no_tool, :retry_read_only, :retry_idempotent_write]

  defp tools_for_shot(journals, %Shot.State{} = shot) do
    journals
    |> Map.get(:tools, Map.get(journals, "tools", []))
    |> Enum.filter(&(journal_shot_id(&1) == shot.id))
  end

  defp same_attempt?(journal, %Shot.State{} = shot),
    do: journal_value(journal, :attempt) == shot.attempt

  defp read_only_tool?(journal) do
    safety = journal_value(journal, :safety_level)
    idempotency = journal_value(journal, :idempotency) || %{}
    class = journal_value(idempotency, :class)

    safety in [:read_only, "read_only"] or class in [:read_only, "read_only"]
  end

  defp idempotent_retryable_tool?(journal) do
    idempotency = journal_value(journal, :idempotency) || %{}
    class = journal_value(idempotency, :class)
    key = journal_value(journal, :idempotency_key)
    safety = journal_value(journal, :safety_level)

    class in [:idempotent, "idempotent"] and present?(key) and
      safety not in [:destructive, "destructive", :irreversible, "irreversible"]
  end

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true

  defp affected_shots(attempts, tools) do
    (attempts ++ tools)
    |> Enum.map(&journal_shot_id/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp write_intent?(journal) do
    safety = journal_value(journal, :safety_level)
    idempotency = journal_value(journal, :idempotency) || %{}
    class = journal_value(idempotency, :class)

    safety not in [nil, :read_only, "read_only"] or class not in [nil, :read_only, "read_only"]
  end

  defp journal_status(journal), do: normalize_atom(journal_value(journal, :status))
  defp journal_shot_id(journal), do: journal_value(journal, :shot_id)

  defp journal_value(journal, key) when is_map(journal) do
    Map.get(journal, key) || Map.get(journal, Atom.to_string(key))
  end

  defp normalize_atom(value) when is_atom(value), do: value

  defp normalize_atom(value) when is_binary(value) do
    case value do
      "started" -> :started
      "completed" -> :completed
      "failed" -> :failed
      "intent_recorded" -> :intent_recorded
      "observed_result" -> :observed_result
      "reconcile_required" -> :reconcile_required
      _other -> value
    end
  end

  defp normalize_atom(value), do: value
end
