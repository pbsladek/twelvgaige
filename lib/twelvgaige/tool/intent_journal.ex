defmodule Twelvgaige.Tool.IntentJournal do
  @moduledoc """
  Durable journal record for a tool call intent.

  The identity is deterministic:
  `{round_id, shot_id, attempt, provider_tool_call_id || tool_call_index || id}`.
  Store backends use that identity to avoid duplicate side-effect records when
  recovery repeats the same intent write.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor
  alias Twelvgaige.Tool.Idempotency

  @audit_input_keys ~w(
    allow_cluster_scope
    command
    confirm
    container
    context
    field_selector
    name
    namespace
    path
    replicas
    resource
    selector
  )
  @audit_output_keys ~w(
    command
    container
    context
    duration_ms
    exit_status
    field_selector
    name
    namespace
    output_bytes
    replicas
    resource
    selector
    truncated
    verb
  )

  @type t :: map()

  @spec new(module(), map(), keyword()) :: t()
  def new(tool, input, opts) when is_atom(tool) and is_map(input) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
    idempotency = tool.idempotency()

    %{
      id: intent_id(context),
      round_id: fetch_context!(context, :round_id),
      shot_id: fetch_context!(context, :shot_id),
      attempt: fetch_context!(context, :attempt),
      provider_tool_call_id: context_value(context, :tool_call_id),
      tool_call_index: context_value(context, :tool_call_index),
      tool_name: tool.name(),
      status: :intent_recorded,
      safety_level: tool.safety_level(),
      idempotency_key: idempotency_key(input),
      idempotency: idempotency_to_map(idempotency),
      reconciliation_strategy: idempotency.reconciliation_strategy,
      input: Redactor.redact_json(input),
      recorded_at: now
    }
  end

  @spec result(module(), map(), {:ok, map()} | {:error, Error.t()}, keyword()) :: t()
  def result(tool, input, outcome, opts) when is_atom(tool) and is_map(input) and is_list(opts) do
    context = Keyword.get(opts, :context, %{})
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

    %{
      id: intent_id(context),
      round_id: fetch_context!(context, :round_id),
      shot_id: fetch_context!(context, :shot_id),
      attempt: fetch_context!(context, :attempt),
      provider_tool_call_id: context_value(context, :tool_call_id),
      tool_call_index: context_value(context, :tool_call_index),
      tool_name: tool.name(),
      status: outcome_status(outcome),
      output: outcome_output(outcome),
      error: outcome_error(outcome),
      completed_at: now
    }
  end

  @spec audit_event(t()) :: map()
  def audit_event(%{status: :intent_recorded} = journal) do
    %{
      event_type: :tool_intent_recorded,
      round_id: Map.fetch!(journal, :round_id),
      shot_id: Map.fetch!(journal, :shot_id),
      actor: "system",
      payload: %{
        attempt: Map.fetch!(journal, :attempt),
        tool_call_id: Map.fetch!(journal, :id),
        tool_name: Map.fetch!(journal, :tool_name),
        safety_level: Map.fetch!(journal, :safety_level),
        idempotency_key: Map.get(journal, :idempotency_key),
        reconciliation_strategy: Map.fetch!(journal, :reconciliation_strategy),
        input: audit_projection(Map.get(journal, :input), @audit_input_keys)
      },
      occurred_at: Map.fetch!(journal, :recorded_at)
    }
  end

  def audit_event(%{} = journal) do
    %{
      event_type: :tool_result_recorded,
      round_id: Map.fetch!(journal, :round_id),
      shot_id: Map.fetch!(journal, :shot_id),
      actor: "system",
      payload: %{
        attempt: Map.fetch!(journal, :attempt),
        tool_call_id: Map.fetch!(journal, :id),
        tool_name: Map.fetch!(journal, :tool_name),
        status: Map.fetch!(journal, :status),
        error: Map.get(journal, :error),
        output: audit_projection(Map.get(journal, :output), @audit_output_keys)
      },
      occurred_at: Map.fetch!(journal, :completed_at)
    }
  end

  defp audit_projection(nil, _keys), do: nil

  defp audit_projection(%{} = value, keys) do
    keys
    |> Enum.reduce(%{}, fn key, acc ->
      case fetch_key(value, key) do
        {:ok, nil} -> acc
        {:ok, found} -> Map.put(acc, key, Redactor.redact_json(found))
        :error -> acc
      end
    end)
    |> empty_to_nil()
  end

  defp audit_projection(_value, _keys), do: nil

  defp fetch_key(map, key) do
    cond do
      Map.has_key?(map, key) -> {:ok, Map.fetch!(map, key)}
      Map.has_key?(map, String.to_atom(key)) -> {:ok, Map.fetch!(map, String.to_atom(key))}
      true -> :error
    end
  rescue
    ArgumentError -> :error
  end

  defp empty_to_nil(map) when map == %{}, do: nil
  defp empty_to_nil(map), do: map

  defp outcome_status({:ok, _output}), do: :observed_result
  defp outcome_status({:error, _error}), do: :failed

  defp outcome_output({:ok, output}), do: Redactor.redact_json(output)
  defp outcome_output({:error, _error}), do: nil

  defp outcome_error({:ok, _output}), do: nil

  defp outcome_error({:error, %Error{} = error}),
    do: error |> Error.to_map() |> Redactor.redact_json()

  defp outcome_error({:error, reason}), do: %{reason: inspect(reason)}

  defp intent_id(context) do
    context_value(context, :tool_call_id) ||
      context_value(context, :tool_call_index) ||
      context_value(context, :id) ||
      raise ArgumentError, "missing tool call identity"
  end

  defp idempotency_to_map(%Idempotency{} = idempotency) do
    %{
      class: idempotency.class,
      requires_key?: idempotency.requires_key?,
      reconciliation_strategy: idempotency.reconciliation_strategy,
      side_effect_phase: idempotency.side_effect_phase
    }
  end

  defp idempotency_key(input) do
    Map.get(input, "idempotency_key") ||
      Map.get(input, :idempotency_key) ||
      Map.get(input, "client_request_id") ||
      Map.get(input, :client_request_id)
  end

  defp fetch_context!(context, key) do
    context_value(context, key) || raise ArgumentError, "missing tool context #{key}"
  end

  defp context_value(context, key) do
    Map.get(context, key) || Map.get(context, Atom.to_string(key))
  end
end
