defmodule Twelvgaige.Round.State do
  @moduledoc """
  Live round coordinator state.

  Runtime-only fields such as task refs and timeout refs stay here and are
  deliberately excluded from `Twelvgaige.Round.Snapshot`.
  """

  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Shot

  @statuses [
    :queued,
    :chambered,
    :firing,
    :awaiting_safety,
    :awaiting_reconciliation,
    :complete,
    :failed,
    :halted,
    :cancelled,
    :blocked_on_store
  ]

  @terminal_statuses [:complete, :failed, :halted, :cancelled]

  @type status ::
          :queued
          | :chambered
          | :firing
          | :awaiting_safety
          | :awaiting_reconciliation
          | :complete
          | :failed
          | :halted
          | :cancelled
          | :blocked_on_store

  @type t :: %__MODULE__{
          id: String.t(),
          shell_id: String.t(),
          shell_version: String.t(),
          pattern: term(),
          manifest: term(),
          policy: map(),
          status: status(),
          version: non_neg_integer(),
          input: map(),
          shot_states: %{String.t() => Shot.State.t()},
          inflight: map(),
          awaiting_safety: [map()],
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          error: Twelvgaige.Error.t() | nil,
          round_timeout_ref: reference() | nil,
          pending_transition: term(),
          store_status: term()
        }

  @enforce_keys [:id, :shell_id, :shell_version]
  defstruct [
    :id,
    :shell_id,
    :shell_version,
    :pattern,
    :manifest,
    policy: %{},
    status: :queued,
    version: 0,
    input: %{},
    shot_states: %{},
    inflight: %{},
    awaiting_safety: [],
    started_at: nil,
    completed_at: nil,
    error: nil,
    round_timeout_ref: nil,
    pending_transition: nil,
    store_status: :ok
  ]

  @doc "Returns all observable round statuses."
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc "Returns terminal round statuses."
  @spec terminal_statuses() :: [status()]
  def terminal_statuses, do: @terminal_statuses

  @doc "Builds a round state from atom-key or string-key attributes."
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    status = value(attrs, :status, :queued)
    validate_status!(status)

    %__MODULE__{
      id: required!(attrs, :id),
      shell_id: required!(attrs, :shell_id),
      shell_version: required!(attrs, :shell_version),
      pattern: value(attrs, :pattern, nil),
      manifest: value(attrs, :manifest, nil),
      policy: value(attrs, :policy, %{}),
      status: status,
      version: value(attrs, :version, 0),
      input: value(attrs, :input, %{}),
      shot_states: build_shot_states(attrs),
      inflight: value(attrs, :inflight, %{}),
      awaiting_safety: value(attrs, :awaiting_safety, []),
      started_at: value(attrs, :started_at, nil),
      completed_at: value(attrs, :completed_at, nil),
      error: value(attrs, :error, nil),
      round_timeout_ref: value(attrs, :round_timeout_ref, nil),
      pending_transition: value(attrs, :pending_transition, nil),
      store_status: value(attrs, :store_status, :ok)
    }
  end

  @doc "Rebuilds live state from a recovery-safe snapshot and runtime options."
  @spec from_snapshot(Snapshot.t(), keyword()) :: t()
  def from_snapshot(%Snapshot{} = snapshot, opts \\ []) do
    new(
      [
        id: snapshot.id,
        shell_id: snapshot.shell_id,
        shell_version: snapshot.shell_version,
        status: snapshot.status,
        version: snapshot.version,
        input: snapshot.input,
        shots: snapshot.shots,
        awaiting_safety: snapshot.awaiting_safety,
        started_at: snapshot.started_at,
        completed_at: snapshot.completed_at,
        error: snapshot.error,
        policy: snapshot.policy,
        store_status: snapshot.store_status
      ] ++ opts
    )
  end

  @doc "Returns true when `status` is a known round status."
  @spec valid_status?(atom()) :: boolean()
  def valid_status?(status), do: status in @statuses

  @doc "Returns true when a round status is terminal."
  @spec terminal?(t() | status()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: terminal?(status)
  def terminal?(status), do: status in @terminal_statuses

  @doc "Returns true when all shots are terminal-successful."
  @spec all_shots_successful?(t()) :: boolean()
  def all_shots_successful?(%__MODULE__{shot_states: shot_states}) do
    shot_states
    |> Map.values()
    |> Enum.all?(&Shot.State.terminal_success?/1)
  end

  @doc "Fetches a shot state by shot ID."
  @spec fetch_shot(t(), String.t()) :: {:ok, Shot.State.t()} | :error
  def fetch_shot(%__MODULE__{shot_states: shot_states}, shot_id) do
    Map.fetch(shot_states, shot_id)
  end

  @doc "Puts a shot state by its own ID."
  @spec put_shot(t(), Shot.State.t()) :: t()
  def put_shot(%__MODULE__{} = state, %Shot.State{} = shot_state) do
    %{state | shot_states: Map.put(state.shot_states, shot_state.id, shot_state)}
  end

  @doc "Returns true when a round transition is allowed by the spec transition table."
  @spec transition_allowed?(status(), status()) :: boolean()
  def transition_allowed?(from, to) do
    validate_status!(from)
    validate_status!(to)

    cond do
      terminal?(from) ->
        false

      to == :cancelled ->
        true

      to == :blocked_on_store ->
        true

      from == :blocked_on_store and not terminal?(to) ->
        true

      true ->
        {from, to} in [
          {:queued, :chambered},
          {:chambered, :firing},
          {:firing, :awaiting_safety},
          {:awaiting_safety, :firing},
          {:awaiting_safety, :halted},
          {:firing, :awaiting_reconciliation},
          {:firing, :failed},
          {:firing, :complete}
        ]
    end
  end

  @doc "Converts live state to a recovery-safe snapshot."
  @spec to_snapshot(t()) :: Snapshot.t()
  def to_snapshot(%__MODULE__{} = state), do: Snapshot.from_state(state)

  defp build_shot_states(attrs) do
    attrs
    |> value(:shot_states, nil)
    |> case do
      nil -> value(attrs, :shots, [])
      shot_states -> shot_states
    end
    |> normalize_shot_states()
  end

  defp normalize_shot_states(%{} = shot_states) do
    Map.new(shot_states, fn
      {id, %Shot.State{} = shot_state} -> {id, shot_state}
      {id, attrs} -> {id, Shot.State.new(Map.put_new(attrs, :id, id))}
    end)
  end

  defp normalize_shot_states(shots) when is_list(shots) do
    Map.new(shots, fn
      %Shot.State{} = shot_state ->
        {shot_state.id, shot_state}

      attrs ->
        shot_state = Shot.State.new(attrs)
        {shot_state.id, shot_state}
    end)
  end

  defp validate_status!(status) do
    unless valid_status?(status) do
      raise ArgumentError, "unknown Twelvgaige round status: #{inspect(status)}"
    end
  end

  defp required!(attrs, key) do
    case value(attrs, key, :__missing__) do
      :__missing__ -> raise ArgumentError, "missing required round state field: #{key}"
      value -> value
    end
  end

  defp value(attrs, key, default) when is_list(attrs) do
    Keyword.get(attrs, key, default)
  end

  defp value(attrs, key, default) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
