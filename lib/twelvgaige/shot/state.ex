defmodule Twelvgaige.Shot.State do
  @moduledoc """
  Recovery-safe state for one shot inside a round.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor

  @statuses [
    :pending,
    :running,
    :complete,
    :retrying,
    :failed,
    :skipped,
    :awaiting_safety,
    :interrupted,
    :awaiting_reconciliation,
    :cancelled
  ]

  @terminal_statuses [:complete, :failed, :skipped, :cancelled]
  @terminal_success_statuses [:complete, :skipped]

  @type status ::
          :pending
          | :running
          | :complete
          | :retrying
          | :failed
          | :skipped
          | :awaiting_safety
          | :interrupted
          | :awaiting_reconciliation
          | :cancelled

  @type t :: %__MODULE__{
          id: String.t(),
          kind: atom() | String.t(),
          status: status(),
          attempt: non_neg_integer(),
          depends_on: [String.t()],
          condition: term(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          output: term(),
          error: Error.t() | nil,
          next_retry_at: DateTime.t() | nil,
          history: [term()]
        }

  @enforce_keys [:id, :kind]
  defstruct [
    :id,
    :kind,
    status: :pending,
    attempt: 0,
    depends_on: [],
    condition: true,
    started_at: nil,
    completed_at: nil,
    output: nil,
    error: nil,
    next_retry_at: nil,
    history: []
  ]

  @doc "Returns all observable shot statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns terminal shot statuses."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Returns terminal-successful shot statuses."
  @spec terminal_success_statuses() :: [status()]
  def terminal_success_statuses, do: @terminal_success_statuses

  @doc "Builds a shot state from atom-key or string-key attributes."
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    id = required!(attrs, :id)
    kind = required!(attrs, :kind)
    status = normalize_status(value(attrs, :status, :pending))

    validate_status!(status)

    %__MODULE__{
      id: id,
      kind: kind,
      status: status,
      attempt: value(attrs, :attempt, 0),
      depends_on: value(attrs, :depends_on, []),
      condition: value(attrs, :condition, true),
      started_at: value(attrs, :started_at, nil),
      completed_at: value(attrs, :completed_at, nil),
      output: value(attrs, :output, nil),
      error: value(attrs, :error, nil),
      next_retry_at: value(attrs, :next_retry_at, nil),
      history: value(attrs, :history, [])
    }
  end

  @doc "Returns true when `status` is a known shot status."
  @spec valid_status?(atom()) :: boolean()
  def valid_status?(status), do: status in @statuses

  @doc "Returns true when a shot status is terminal."
  @spec terminal?(t() | status()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: terminal?(status)
  def terminal?(status), do: status in @terminal_statuses

  @doc "Returns true when dependencies may treat this shot as successful."
  @spec terminal_success?(t() | status()) :: boolean()
  def terminal_success?(%__MODULE__{status: status}), do: terminal_success?(status)
  def terminal_success?(status), do: status in @terminal_success_statuses

  @doc """
  Returns true when the shot's current status permits a start attempt.

  `:pending` shots are always startable. `:retrying` shots are startable only
  when their retry timestamp is absent or not later than `now`.
  """
  @spec startable?(t(), DateTime.t() | nil) :: boolean()
  def startable?(state, now \\ nil)

  def startable?(%__MODULE__{status: :pending}, _now), do: true

  def startable?(%__MODULE__{status: :retrying, next_retry_at: nil}, _now), do: true

  def startable?(%__MODULE__{status: :retrying, next_retry_at: next_retry_at}, %DateTime{} = now) do
    DateTime.compare(next_retry_at, now) in [:lt, :eq]
  end

  def startable?(%__MODULE__{}, _now), do: false

  @doc "Converts a shot state to the stable JSON-safe snapshot map shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = state) do
    %{
      id: state.id,
      kind: stringify_kind(state.kind),
      status: Atom.to_string(state.status),
      attempt: state.attempt,
      started_at: format_time(state.started_at),
      completed_at: format_time(state.completed_at),
      error: Error.to_map(state.error),
      output: state.output,
      next_retry_at: format_time(state.next_retry_at)
    }
    |> Redactor.redact_json()
  end

  defp validate_status!(status) do
    unless valid_status?(status) do
      raise ArgumentError, "unknown Twelvgaige shot status: #{inspect(status)}"
    end
  end

  defp required!(attrs, key) do
    case value(attrs, key, :__missing__) do
      :__missing__ -> raise ArgumentError, "missing required shot state field: #{key}"
      value -> value
    end
  end

  defp value(attrs, key, default) when is_list(attrs) do
    Keyword.get(attrs, key, default)
  end

  defp value(attrs, key, default) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp stringify_kind(kind) when is_atom(kind), do: Atom.to_string(kind)
  defp stringify_kind(kind), do: kind

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp format_time(time), do: time

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    if status in Enum.map(@statuses, &Atom.to_string/1) do
      String.to_existing_atom(status)
    else
      status
    end
  end

  defp normalize_status(status), do: status
end
