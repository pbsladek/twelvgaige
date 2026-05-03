defmodule Twelvgaige.Shot.AttemptJournal do
  @moduledoc """
  Durable journal record for the start of one shot attempt.

  The identity is deterministic: `{round_id, shot_id, attempt}`. Store
  backends use that identity to make repeated writes idempotent across
  crashes and retries.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor
  alias Twelvgaige.Shot.Attempt

  @type t :: map()

  @spec new(Attempt.t(), keyword()) :: t()
  def new(%Attempt{} = attempt, opts \\ []) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

    %{
      round_id: attempt.round_id,
      shot_id: attempt.shot_id,
      attempt: attempt.attempt,
      status: :started,
      safety_level: tool_safety(attempt),
      idempotency_metadata: %{
        requires_tool_intents: tool_safety(attempt) != :read_only
      },
      started_at: now
    }
  end

  @spec finish(Attempt.t(), :completed | :failed, term(), keyword()) :: t()
  def finish(%Attempt{} = attempt, status, result, opts \\ [])
      when status in [:completed, :failed] do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

    %{
      round_id: attempt.round_id,
      shot_id: attempt.shot_id,
      attempt: attempt.attempt,
      status: status,
      completed_at: now,
      result: result_summary(result)
    }
  end

  @spec audit_event(t()) :: map()
  def audit_event(%{status: :started} = journal) do
    %{
      event_type: :shot_attempt_started,
      round_id: Map.fetch!(journal, :round_id),
      shot_id: Map.fetch!(journal, :shot_id),
      actor: "system",
      payload: %{
        attempt: Map.fetch!(journal, :attempt),
        safety_level: Map.fetch!(journal, :safety_level)
      },
      occurred_at: Map.fetch!(journal, :started_at)
    }
  end

  def audit_event(%{} = journal) do
    %{
      event_type: :shot_attempt_finished,
      round_id: Map.fetch!(journal, :round_id),
      shot_id: Map.fetch!(journal, :shot_id),
      actor: "system",
      payload: %{
        attempt: Map.fetch!(journal, :attempt),
        status: Map.fetch!(journal, :status),
        result: Map.get(journal, :result)
      },
      occurred_at: Map.fetch!(journal, :completed_at)
    }
  end

  defp result_summary({:ok, result}) when is_map(result) do
    %{
      tool_call_count: result |> Map.get(:tool_calls, []) |> length(),
      usage: Map.get(result, :usage, %{})
    }
  end

  defp result_summary({:error, %Error{} = error}),
    do: %{error: error |> Error.to_map() |> Redactor.redact_json()}

  defp result_summary(%Error{} = error),
    do: %{error: error |> Error.to_map() |> Redactor.redact_json()}

  defp result_summary(other), do: %{value: inspect(other)}

  defp tool_safety(%Attempt{definition: %{choke: %{tool_safety: tool_safety}}}), do: tool_safety
  defp tool_safety(_attempt), do: :read_only
end
