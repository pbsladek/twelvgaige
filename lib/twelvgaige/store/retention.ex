defmodule Twelvgaige.Store.Retention do
  @moduledoc false

  alias Twelvgaige.RuntimeProfile

  @terminal_statuses MapSet.new([:complete, :failed, :halted, :cancelled])

  def configure(state, opts) do
    state
    |> Map.put(:max_retained_bytes, max_retained_bytes(opts))
    |> Map.put(:sensitive_retention, sensitive_retention(opts))
    |> Map.put_new(:evicted_rounds, Map.get(state, :evicted_rounds, 0) || 0)
  end

  def enforce(state) do
    case Map.get(state, :max_retained_bytes) do
      max_bytes when is_integer(max_bytes) and max_bytes > 0 ->
        evict_until_within_limit(state, max_bytes)

      _other ->
        state
    end
  end

  def stats(state, terminal_statuses \\ @terminal_statuses) do
    rounds = Map.get(state, :rounds, %{})
    incomplete_rounds = Enum.count(rounds, fn {_id, snapshot} -> incomplete?(snapshot) end)

    retained_bytes = retained_bytes(state)
    max_retained_bytes = Map.get(state, :max_retained_bytes)

    %{
      rounds: map_size(rounds),
      terminal_rounds: map_size(rounds) - incomplete_rounds,
      incomplete_rounds: incomplete_rounds,
      round_events: total_count(Map.get(state, :events, %{})),
      audit_events: total_count(Map.get(state, :audit_events, %{})),
      attempt_journals: map_size(Map.get(state, :attempts, %{})),
      tool_journals: map_size(Map.get(state, :tool_intents, %{})),
      retained_bytes: retained_bytes,
      retained_bytes_limit: max_retained_bytes,
      retained_bytes_over_limit: over_limit?(retained_bytes, max_retained_bytes),
      evicted_rounds: Map.get(state, :evicted_rounds, 0) || 0
    }
    |> Map.put(:incomplete_rounds, count_incomplete(rounds, terminal_statuses))
    |> Map.put(:terminal_rounds, count_terminal(rounds, terminal_statuses))
  end

  def retained_bytes(state) do
    %{
      rounds: Map.get(state, :rounds, %{}),
      manifests: Map.get(state, :manifests, %{}),
      events: Map.get(state, :events, %{}),
      audit_events: Map.get(state, :audit_events, %{}),
      attempts: Map.get(state, :attempts, %{}),
      tool_intents: Map.get(state, :tool_intents, %{})
    }
    |> :erlang.term_to_binary()
    |> byte_size()
  end

  defp max_retained_bytes(opts) do
    case Keyword.get(opts, :max_retained_bytes, :profile_default) do
      :profile_default ->
        profile = Keyword.get(opts, :profile, RuntimeProfile.default())

        case RuntimeProfile.normalize(profile) do
          {:ok, profile} -> RuntimeProfile.limits(profile).retained_bytes
          {:error, _reason} -> RuntimeProfile.limits(:laptop).retained_bytes
        end

      false ->
        nil

      nil ->
        nil

      :infinity ->
        nil

      value ->
        normalize_positive_integer(value)
    end
  end

  defp normalize_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp normalize_positive_integer(_value), do: nil

  defp sensitive_retention(opts) do
    opts
    |> Keyword.get(:sensitive_retention, :redacted)
    |> normalize_sensitive_retention()
  end

  defp normalize_sensitive_retention(value) when value in [:redacted, "redacted"], do: :redacted
  defp normalize_sensitive_retention(value) when value in [:summary, "summary"], do: :summary
  defp normalize_sensitive_retention(_value), do: :redacted

  defp evict_until_within_limit(state, max_bytes) do
    if retained_bytes(state) <= max_bytes do
      state
    else
      candidates = terminal_candidates(state)
      evictable = if length(candidates) > 1, do: Enum.drop(candidates, -1), else: []

      Enum.reduce_while(evictable, state, fn {round_id, _snapshot}, acc ->
        if retained_bytes(acc) <= max_bytes do
          {:halt, acc}
        else
          {:cont, drop_round(acc, round_id)}
        end
      end)
    end
  end

  defp terminal_candidates(state) do
    state
    |> Map.get(:rounds, %{})
    |> Enum.filter(fn {_round_id, snapshot} -> terminal?(snapshot) end)
    |> Enum.sort_by(fn {round_id, snapshot} -> retention_sort_key(round_id, snapshot) end)
  end

  defp drop_round(state, round_id) do
    state
    |> delete_nested_map_key(:rounds, round_id)
    |> delete_nested_map_key(:manifests, round_id)
    |> delete_nested_map_key(:events, round_id)
    |> delete_nested_map_key(:audit_events, round_id)
    |> delete_nested_map_key(:next_seq, round_id)
    |> drop_journals(:attempts, round_id)
    |> drop_journals(:tool_intents, round_id)
    |> drop_committed_transitions(round_id)
    |> Map.update(:evicted_rounds, 1, &((&1 || 0) + 1))
  end

  defp delete_nested_map_key(state, key, round_id) do
    Map.update(state, key, %{}, &Map.delete(&1 || %{}, round_id))
  end

  defp drop_journals(state, key, round_id) do
    Map.update(state, key, %{}, fn journals ->
      journals
      |> map_or_empty()
      |> Map.reject(fn {journal_key, journal} ->
        journal_round_id(journal_key, journal) == round_id
      end)
    end)
  end

  defp journal_round_id({round_id, _shot_id, _attempt}, _journal), do: round_id
  defp journal_round_id({round_id, _shot_id, _attempt, _tool_key}, _journal), do: round_id
  defp journal_round_id(_key, journal), do: value(journal, :round_id)

  defp drop_committed_transitions(state, round_id) do
    Map.update(state, :committed_transitions, MapSet.new(), fn transitions ->
      transitions
      |> mapset_or_empty()
      |> Enum.reject(fn
        {^round_id, _transition_id} -> true
        _other -> false
      end)
      |> MapSet.new()
    end)
  end

  defp retention_sort_key(round_id, snapshot) do
    {
      time_sort_value(value(snapshot, :completed_at) || value(snapshot, :started_at)),
      to_string(round_id)
    }
  end

  defp time_sort_value(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp time_sort_value(time) when is_binary(time), do: time
  defp time_sort_value(_time), do: ""

  defp total_count(events_by_round) do
    events_by_round
    |> Map.values()
    |> Enum.reduce(0, fn events, count -> count + length(events || []) end)
  end

  defp count_incomplete(rounds, terminal_statuses) do
    Enum.count(rounds, fn {_id, snapshot} -> not terminal?(snapshot, terminal_statuses) end)
  end

  defp count_terminal(rounds, terminal_statuses) do
    Enum.count(rounds, fn {_id, snapshot} -> terminal?(snapshot, terminal_statuses) end)
  end

  defp terminal?(snapshot), do: terminal?(snapshot, @terminal_statuses)

  defp terminal?(snapshot, terminal_statuses) do
    status = value(snapshot, :status)
    status in terminal_statuses or normalize_status(status) in terminal_statuses
  end

  defp incomplete?(snapshot), do: not terminal?(snapshot)

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_value), do: %{}

  defp mapset_or_empty(%MapSet{} = set), do: set
  defp mapset_or_empty(_value), do: MapSet.new()

  defp normalize_status(status) when is_binary(status) do
    case status do
      "complete" -> :complete
      "failed" -> :failed
      "halted" -> :halted
      "cancelled" -> :cancelled
      _other -> status
    end
  end

  defp normalize_status(status), do: status

  defp over_limit?(_retained_bytes, nil), do: false
  defp over_limit?(retained_bytes, limit) when is_integer(limit), do: retained_bytes > limit
  defp over_limit?(_retained_bytes, _limit), do: false

  defp value(record, key) when is_map(record) do
    Map.get(record, key, Map.get(record, Atom.to_string(key)))
  end

  defp value(_record, _key), do: nil
end
