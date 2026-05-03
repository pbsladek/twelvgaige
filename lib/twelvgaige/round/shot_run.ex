defmodule Twelvgaige.Round.ShotRun do
  @moduledoc """
  Queryable durable projection for one shot inside a round.

  Snapshots remain the recovery source of truth. Shot runs are a read-optimized
  projection so stores can answer shot-level queries without decoding every
  round blob.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Shot

  @type t :: %{
          round_id: String.t(),
          shot_id: String.t(),
          kind: String.t(),
          status: String.t(),
          attempt: non_neg_integer(),
          started_at: String.t() | nil,
          completed_at: String.t() | nil,
          next_retry_at: String.t() | nil,
          output: term(),
          error: map() | nil
        }

  @spec from_snapshot(Snapshot.t() | map()) :: [t()]
  def from_snapshot(%Snapshot{id: round_id, shots: shots}) do
    Enum.map(shots, &from_shot(round_id, &1))
  end

  def from_snapshot(%{} = snapshot) do
    round_id = value(snapshot, :id) || value(snapshot, :round_id)

    snapshot
    |> value(:shots, [])
    |> Enum.map(&from_shot(round_id, &1))
  end

  @spec from_shot(String.t(), Shot.State.t() | map()) :: t()
  def from_shot(round_id, shot) do
    %{
      round_id: round_id,
      shot_id: value(shot, :id),
      kind: stringify(value(shot, :kind)),
      status: stringify(value(shot, :status, :pending)),
      attempt: value(shot, :attempt, 0),
      started_at: format_time(value(shot, :started_at)),
      completed_at: format_time(value(shot, :completed_at)),
      next_retry_at: format_time(value(shot, :next_retry_at)),
      output: value(shot, :output),
      error: normalize_error(value(shot, :error))
    }
  end

  defp normalize_error(nil), do: nil
  defp normalize_error(%Error{} = error), do: Error.to_map(error)
  defp normalize_error(error), do: error

  defp format_time(nil), do: nil
  defp format_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp format_time(time), do: time

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp value(attrs, key, default \\ nil)

  defp value(%{} = attrs, key, default) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end

  defp value(_attrs, _key, default), do: default
end
