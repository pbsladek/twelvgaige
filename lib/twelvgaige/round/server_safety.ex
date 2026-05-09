defmodule Twelvgaige.Round.ServerSafety do
  @moduledoc false

  alias Twelvgaige.Round.State, as: RoundState

  @type decision ::
          :await
          | {:approved, String.t() | nil, String.t()}
          | {:rejected, String.t() | nil, String.t()}

  @spec request(RoundState.t(), map()) :: map()
  def request(%RoundState{} = round_state, shot) do
    %{
      "round_id" => round_state.id,
      "shot_id" => shot.id,
      "status" => "awaiting",
      "scope" => Atom.to_string(safety_scope(round_state)),
      "reason" => shot.description,
      "requested_at" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }
  end

  @spec decision(map(), keyword()) :: decision()
  def decision(request, opts) do
    cond do
      Keyword.get(opts, :approve_all_safety?, false) ->
        {:approved, "approved by foreground option", "system"}

      decisions = Keyword.get(opts, :safety_decisions) ->
        decisions
        |> lookup_decision(request["shot_id"])
        |> normalize_decision()

      handler = Keyword.get(opts, :safety_handler) ->
        handler
        |> call_handler(request)
        |> normalize_decision()

      true ->
        :await
    end
  end

  @spec rejected_round_status(RoundState.t()) :: :failed | :halted
  def rejected_round_status(%RoundState{} = round_state) do
    case Map.get(round_state.policy || %{}, :on_safety_reject, :halt_round) do
      :fail_round -> :failed
      _halt_round -> :halted
    end
  end

  @spec output(String.t(), String.t() | nil, String.t() | nil) :: map()
  def output(decision, reason, actor) do
    %{
      "decision" => decision,
      "reason" => reason,
      "actor" => actor,
      "decided_at" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }
  end

  @spec drop_awaiting([map()], String.t()) :: [map()]
  def drop_awaiting(awaiting, shot_id) when is_list(awaiting) and is_binary(shot_id) do
    Enum.reject(awaiting, &(Map.get(&1, "shot_id") == shot_id))
  end

  @spec normalize_decision(term()) :: decision()
  def normalize_decision(value)
      when value in [:approve, :approved, "approve", "approved"] do
    {:approved, nil, "system"}
  end

  def normalize_decision(value)
      when value in [:reject, :rejected, "reject", "rejected"] do
    {:rejected, nil, "system"}
  end

  def normalize_decision({decision, reason}) when decision in [:approve, :approved] do
    {:approved, reason, "system"}
  end

  def normalize_decision({decision, reason}) when decision in [:reject, :rejected] do
    {:rejected, reason, "system"}
  end

  def normalize_decision(%{} = decision) do
    normalized =
      decision
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()

    case normalize_decision(Map.get(normalized, "decision")) do
      {:approved, _reason, _actor} ->
        {:approved, Map.get(normalized, "reason"), Map.get(normalized, "actor", "system")}

      {:rejected, _reason, _actor} ->
        {:rejected, Map.get(normalized, "reason"), Map.get(normalized, "actor", "system")}

      :await ->
        :await
    end
  end

  def normalize_decision(_value), do: :await

  defp safety_scope(round_state),
    do: Map.get(round_state.policy || %{}, :safety_scope, :dependency)

  defp lookup_decision(decisions, shot_id) when is_map(decisions) do
    Enum.find_value(decisions, fn {key, value} ->
      if to_string(key) == shot_id, do: value
    end)
  end

  defp lookup_decision(decisions, shot_id) when is_list(decisions) do
    Enum.find_value(decisions, fn
      {key, value} when is_atom(key) or is_binary(key) ->
        if to_string(key) == shot_id, do: value

      _other ->
        nil
    end)
  end

  defp lookup_decision(_decisions, _shot_id), do: nil

  defp call_handler(handler, request) when is_function(handler, 1), do: handler.(request)

  defp call_handler(handler, request) when is_function(handler, 2),
    do: handler.(request["shot_id"], request)

  defp call_handler(_handler, _request), do: nil
end
