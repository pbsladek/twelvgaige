defmodule Twelvgaige.DelegatedSession.Event do
  @moduledoc "Normalized durable event emitted by delegated runtimes."

  @vocabulary ~w(
    session_started turn_started message_delta plan_updated tool_requested approval_required
    tool_started tool_finished subagent_started subagent_finished usage_updated artifact_created
    turn_completed transcript_mirror_failed session_failed session_stopped session_cancelled
    session_completed
  )a

  @enforce_keys [:session_id, :event_type, :native_event_id, :payload, :occurred_at]
  defstruct [
    :session_id,
    :seq,
    :event_type,
    :native_session_id,
    :native_turn_id,
    :native_event_id,
    :payload,
    :payload_digest,
    :occurred_at,
    :event_class,
    schema_version: 1,
    encoding_version: 1
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          seq: non_neg_integer() | nil,
          event_type: atom(),
          native_session_id: String.t() | nil,
          native_turn_id: String.t() | nil,
          native_event_id: String.t(),
          payload: map(),
          payload_digest: String.t(),
          occurred_at: DateTime.t(),
          event_class: :critical | :operational | :presentation,
          schema_version: pos_integer(),
          encoding_version: pos_integer()
        }

  def new(attrs) do
    event_type = Keyword.fetch!(attrs, :event_type)
    if event_type not in @vocabulary, do: raise(ArgumentError, "unknown delegated event type")
    payload = Keyword.get(attrs, :payload, %{})

    struct!(__MODULE__, %{
      session_id: Keyword.fetch!(attrs, :session_id),
      seq: Keyword.get(attrs, :seq),
      event_type: event_type,
      native_session_id: Keyword.get(attrs, :native_session_id),
      native_turn_id: Keyword.get(attrs, :native_turn_id),
      native_event_id: Keyword.fetch!(attrs, :native_event_id),
      payload: payload,
      payload_digest: Keyword.get(attrs, :payload_digest, digest(payload)),
      occurred_at: Keyword.fetch!(attrs, :occurred_at),
      event_class: Keyword.get(attrs, :event_class, Twelvgaige.Round.Event.classify(event_type)),
      schema_version: Keyword.get(attrs, :schema_version, 1),
      encoding_version: Keyword.get(attrs, :encoding_version, 1)
    })
  end

  def dedupe_key(%__MODULE__{} = event),
    do: {event.native_session_id, event.native_event_id, event.payload_digest}

  defp digest(payload) do
    :crypto.hash(:sha256, :erlang.term_to_binary(payload)) |> Base.encode16(case: :lower)
  end
end
