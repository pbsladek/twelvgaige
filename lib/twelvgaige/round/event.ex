defmodule Twelvgaige.Round.Event do
  @moduledoc """
  Durable round event projection used by store and watch APIs.
  """

  alias Twelvgaige.Error

  @type t :: %__MODULE__{
          id: String.t() | nil,
          round_id: String.t(),
          seq: non_neg_integer() | nil,
          transition_id: String.t() | nil,
          round_version: non_neg_integer() | nil,
          event_type: atom() | String.t(),
          event_class: :critical | :operational | :presentation,
          shot_id: String.t() | nil,
          payload: map(),
          occurred_at: DateTime.t() | nil
        }

  @enforce_keys [:round_id, :event_type]
  defstruct [
    :id,
    :round_id,
    :seq,
    :transition_id,
    :round_version,
    :event_type,
    :event_class,
    :shot_id,
    payload: %{},
    occurred_at: nil
  ]

  @doc "Builds an event from atom-key or string-key attributes."
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    payload = value(attrs, :payload, %{})

    unless is_map(payload) do
      raise ArgumentError, "round event payload must be a map"
    end

    event_type = normalize_event_type(required!(attrs, :event_type))

    %__MODULE__{
      id: value(attrs, :id, nil),
      round_id: required!(attrs, :round_id),
      seq: value(attrs, :seq, nil),
      transition_id: value(attrs, :transition_id, nil),
      round_version: value(attrs, :round_version, nil),
      event_type: event_type,
      event_class: value(attrs, :event_class, classify(event_type)),
      shot_id: value(attrs, :shot_id, nil),
      payload: payload,
      occurred_at: value(attrs, :occurred_at, nil)
    }
  end

  @doc "Converts an event to a JSON-safe map shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = event) do
    %{
      id: event.id,
      round_id: event.round_id,
      seq: event.seq,
      transition_id: event.transition_id,
      round_version: event.round_version,
      event_type: stringify_event_type(event.event_type),
      event_class: Atom.to_string(event.event_class),
      shot_id: event.shot_id,
      payload: normalize_value(event.payload),
      occurred_at: format_time(event.occurred_at)
    }
  end

  @doc "Classifies delivery priority independently from provider-specific event names."
  @spec classify(atom() | String.t()) :: :critical | :operational | :presentation
  def classify(event_type) when is_atom(event_type), do: classify(Atom.to_string(event_type))

  def classify(event_type) when is_binary(event_type) do
    cond do
      event_type in ~w(
        safety_awaiting safety_approved safety_rejected approval_requested approval_resolved
        round_cancelled round_completed round_failed round_halted round_awaiting_reconciliation
        session_cancelled session_completed session_failed session_awaiting_reconciliation
      ) ->
        :critical

      String.ends_with?(event_type, "_delta") or event_type in ~w(text_delta progress_delta) ->
        :presentation

      true ->
        :operational
    end
  end

  defp required!(attrs, key) do
    case value(attrs, key, :__missing__) do
      :__missing__ -> raise ArgumentError, "missing required round event field: #{key}"
      value -> value
    end
  end

  defp value(attrs, key, default) when is_list(attrs) do
    Keyword.get(attrs, key, default)
  end

  defp value(attrs, key, default) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp format_time(time), do: time

  defp normalize_value(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp normalize_value(%Error{} = error), do: error |> Error.to_map() |> normalize_value()

  defp normalize_value(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_value()
  end

  defp normalize_value(%{} = map) do
    Map.new(map, fn {key, value} -> {key, normalize_value(value)} end)
  end

  defp normalize_value(values) when is_list(values), do: Enum.map(values, &normalize_value/1)
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

  defp normalize_event_type(event_type) when is_atom(event_type), do: event_type

  defp normalize_event_type(event_type) when is_binary(event_type) do
    String.to_existing_atom(event_type)
  rescue
    ArgumentError -> event_type
  end

  defp stringify_event_type(event_type) when is_atom(event_type), do: Atom.to_string(event_type)
  defp stringify_event_type(event_type), do: event_type
end
