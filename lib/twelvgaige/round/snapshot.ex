defmodule Twelvgaige.Round.Snapshot do
  @moduledoc """
  Recovery-safe projection of a round.

  Snapshots intentionally omit live BEAM values such as pids, monitors, timers,
  permits, and process-local pending transitions.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor
  alias Twelvgaige.Round
  alias Twelvgaige.Shot

  @schema_version 1
  @encoding_version 1

  @type t :: %__MODULE__{
          id: String.t(),
          schema_version: pos_integer(),
          encoding_version: pos_integer(),
          shell_id: String.t(),
          shell_version: String.t(),
          status: Round.State.status(),
          version: non_neg_integer(),
          input: map(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil,
          error: Error.t() | nil,
          shots: [Shot.State.t()],
          awaiting_safety: [map()],
          policy: map(),
          resource_profile: atom() | String.t() | nil,
          store_status: term()
        }

  @enforce_keys [:id, :shell_id, :shell_version]
  defstruct [
    :id,
    :shell_id,
    :shell_version,
    schema_version: @schema_version,
    encoding_version: @encoding_version,
    status: :queued,
    version: 0,
    input: %{},
    started_at: nil,
    completed_at: nil,
    error: nil,
    shots: [],
    awaiting_safety: [],
    policy: %{},
    resource_profile: nil,
    store_status: :ok
  ]

  @doc "Builds a snapshot from atom-key or string-key attributes."
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    status = normalize_status(value(attrs, :status, :queued))

    unless Round.State.valid_status?(status) do
      raise ArgumentError, "unknown Twelvgaige round status: #{inspect(status)}"
    end

    %__MODULE__{
      id: required!(attrs, :id),
      schema_version: value(attrs, :schema_version, @schema_version),
      encoding_version: value(attrs, :encoding_version, @encoding_version),
      shell_id: required!(attrs, :shell_id),
      shell_version: required!(attrs, :shell_version),
      status: status,
      version: value(attrs, :version, 0),
      input: value(attrs, :input, %{}),
      started_at: value(attrs, :started_at, nil),
      completed_at: value(attrs, :completed_at, nil),
      error: value(attrs, :error, nil),
      shots: normalize_shots(value(attrs, :shots, [])),
      awaiting_safety: value(attrs, :awaiting_safety, []),
      policy: value(attrs, :policy, %{}),
      resource_profile: value(attrs, :resource_profile, nil),
      store_status: value(attrs, :store_status, :ok)
    }
  end

  @doc "Upgrades a decoded versioned snapshot while preserving legacy map records."
  @spec upgrade(t() | map()) :: t() | map()
  def upgrade(%__MODULE__{} = snapshot), do: new(snapshot)
  def upgrade(snapshot) when is_map(snapshot), do: snapshot

  @doc "Projects live round state into recovery-safe data."
  @spec from_state(Round.State.t()) :: t()
  def from_state(%Round.State{} = state) do
    new(
      id: state.id,
      shell_id: state.shell_id,
      shell_version: state.shell_version,
      status: state.status,
      version: state.version,
      input: state.input,
      started_at: state.started_at,
      completed_at: state.completed_at,
      error: state.error,
      shots: sorted_shots(state.shot_states),
      awaiting_safety: state.awaiting_safety,
      policy: state.policy,
      resource_profile: Map.get(state.policy || %{}, :resource_profile),
      store_status: state.store_status
    )
  end

  @doc "Returns true when the snapshot has a terminal round status."
  @spec terminal?(t()) :: boolean()
  def terminal?(%__MODULE__{status: status}), do: Round.State.terminal?(status)

  @doc "Converts a snapshot to the stable JSON-safe map shape."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    %{
      schema_version: snapshot.schema_version,
      encoding_version: snapshot.encoding_version,
      id: snapshot.id,
      shell_id: snapshot.shell_id,
      shell_version: snapshot.shell_version,
      status: Atom.to_string(snapshot.status),
      version: snapshot.version,
      input: snapshot.input,
      started_at: format_time(snapshot.started_at),
      completed_at: format_time(snapshot.completed_at),
      error: Error.to_map(snapshot.error),
      shots: Enum.map(snapshot.shots, &Shot.State.to_map/1),
      awaiting_safety: snapshot.awaiting_safety,
      policy: snapshot.policy,
      resource_profile: stringify_profile(snapshot.resource_profile),
      store_status: stringify_status(snapshot.store_status)
    }
    |> Redactor.redact_json()
  end

  @doc "Returns the canonical recovery snapshot accepted by a store boundary."
  @spec persistable(t() | map()) :: t()
  def persistable(%__MODULE__{} = snapshot) do
    snapshot = upgrade(snapshot)

    %{
      snapshot
      | input: Redactor.redact_json(snapshot.input),
        error: Redactor.redact_json(snapshot.error),
        awaiting_safety: Redactor.redact_json(snapshot.awaiting_safety),
        policy: Redactor.redact_json(snapshot.policy),
        shots: Enum.map(snapshot.shots, &persistable_shot/1)
    }
  end

  def persistable(snapshot) when is_map(snapshot), do: Redactor.redact_json(snapshot)

  defp persistable_shot(%Shot.State{} = shot) do
    %{
      shot
      | condition: Redactor.redact_json(shot.condition),
        output: Redactor.redact_json(shot.output),
        error: Redactor.redact_json(shot.error),
        history: Redactor.redact_json(shot.history)
    }
  end

  defp normalize_shots(shots) do
    Enum.map(shots, fn
      %Shot.State{} = shot -> shot
      attrs -> Shot.State.new(attrs)
    end)
  end

  defp sorted_shots(shot_states) do
    shot_states
    |> Map.values()
    |> Enum.sort_by(& &1.id)
  end

  defp required!(attrs, key) do
    case value(attrs, key, :__missing__) do
      :__missing__ -> raise ArgumentError, "missing required round snapshot field: #{key}"
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

  defp stringify_profile(nil), do: nil
  defp stringify_profile(profile) when is_atom(profile), do: Atom.to_string(profile)
  defp stringify_profile(profile), do: profile

  defp stringify_status(status) when is_atom(status), do: Atom.to_string(status)
  defp stringify_status(status), do: status

  defp normalize_status(status) when is_atom(status), do: status

  defp normalize_status(status) when is_binary(status) do
    if status in Enum.map(Round.State.statuses(), &Atom.to_string/1) do
      String.to_existing_atom(status)
    else
      status
    end
  end

  defp normalize_status(status), do: status
end
