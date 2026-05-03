defmodule Twelvgaige.TestSupport.FakeStore do
  @moduledoc """
  Controllable in-memory store behaviour implementation for tests.

  This fake is intentionally smaller than production stores. It preserves the
  behaviour contract shape and lets tests force the next operation to fail.
  """

  use Agent

  @behaviour Twelvgaige.Store

  @terminal_statuses MapSet.new([:complete, :failed, :halted, :cancelled])

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    Agent.start_link(
      fn ->
        %{
          rounds: %{},
          manifests: %{},
          events: %{},
          audit_events: %{},
          attempt_journals: %{},
          tool_journals: %{},
          transitions: MapSet.new(),
          calls: [],
          failures: []
        }
      end,
      name: name
    )
  end

  def fail_next(operation, reason \\ :store_down, server \\ __MODULE__) do
    Agent.update(
      server,
      &update_in(&1.failures, fn failures -> failures ++ [{operation, reason}] end)
    )
  end

  def calls(server \\ __MODULE__) do
    Agent.get(server, &Enum.reverse(&1.calls))
  end

  @impl true
  def create_round(snapshot, manifest, audit_events) do
    mutate(:create_round, fn state ->
      round_id = round_id(snapshot)

      if Map.has_key?(state.rounds, round_id) do
        {{:error, :round_already_exists}, state}
      else
        state =
          state
          |> put_in([:rounds, round_id], snapshot)
          |> put_in([:manifests, round_id], manifest)
          |> append_audit(round_id, audit_events)

        {:ok, state}
      end
    end)
  end

  @impl true
  def record_attempt_started(attempt, audit_events) do
    mutate(:record_attempt_started, fn state ->
      key = attempt_key(attempt)

      state =
        state
        |> put_in([:attempt_journals, key], attempt)
        |> append_audit(round_id(attempt), audit_events)

      {:ok, state}
    end)
  end

  @impl true
  def record_attempt_finished(attempt, audit_events) do
    mutate(:record_attempt_finished, fn state ->
      key = attempt_key(attempt)

      if Map.has_key?(state.attempt_journals, key) do
        state =
          state
          |> put_in([:attempt_journals, key], attempt)
          |> append_audit(round_id(attempt), audit_events)

        {:ok, state}
      else
        {{:error, :journal_missing}, state}
      end
    end)
  end

  @impl true
  def record_tool_intent(intent, audit_events) do
    mutate(:record_tool_intent, fn state ->
      key = tool_key(intent)

      state =
        state
        |> put_in([:tool_journals, key], intent)
        |> append_audit(round_id(intent), audit_events)

      {:ok, state}
    end)
  end

  @impl true
  def record_tool_result(result, audit_events) do
    mutate(:record_tool_result, fn state ->
      key = tool_key(result)

      if Map.has_key?(state.tool_journals, key) do
        state =
          state
          |> put_in([:tool_journals, key], result)
          |> append_audit(round_id(result), audit_events)

        {:ok, state}
      else
        {{:error, :journal_missing}, state}
      end
    end)
  end

  @impl true
  def commit_transition(
        round_id,
        expected_version,
        transition_id,
        next_snapshot,
        events,
        audit_events
      ) do
    mutate(:commit_transition, fn state ->
      cond do
        MapSet.member?(state.transitions, {round_id, transition_id}) ->
          {:already_committed, state}

        not Map.has_key?(state.rounds, round_id) ->
          {{:error, :not_found}, state}

        version(state.rounds[round_id]) != expected_version ->
          {{:error, :version_conflict}, state}

        true ->
          next_snapshot = put_value(next_snapshot, :version, expected_version + 1)
          events = assign_event_sequences(Map.get(state.events, round_id, []), events)

          state =
            state
            |> put_in([:rounds, round_id], next_snapshot)
            |> update_in([:events, round_id], &((&1 || []) ++ events))
            |> append_audit(round_id, audit_events)
            |> update_in([:transitions], &MapSet.put(&1, {round_id, transition_id}))

          {:ok, state}
      end
    end)
  end

  @impl true
  def get_round(round_id), do: fetch(:get_round, [:rounds, round_id])

  @impl true
  def get_manifest(round_id), do: fetch(:get_manifest, [:manifests, round_id])

  @impl true
  def list_rounds(opts \\ []) do
    Agent.get(__MODULE__, fn state ->
      status = Keyword.get(opts, :status)

      rounds =
        state.rounds
        |> Map.values()
        |> Enum.filter(fn snapshot ->
          is_nil(status) or normalize_status(value(snapshot, :status)) == normalize_status(status)
        end)
        |> Enum.sort_by(&round_id/1)

      {:ok, rounds}
    end)
  end

  @impl true
  def list_shot_runs(round_id) do
    case get_round(round_id) do
      {:ok, snapshot} -> {:ok, Enum.map(value(snapshot, :shots) || [], &shot_run(round_id, &1))}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def list_round_events(round_id, opts \\ []) do
    Agent.get(__MODULE__, fn state ->
      if Map.has_key?(state.rounds, round_id) do
        {:ok, filter_events(Map.get(state.events, round_id, []), opts)}
      else
        {:error, :not_found}
      end
    end)
  end

  @impl true
  def await_round_events(round_id, opts \\ []), do: list_round_events(round_id, opts)

  @impl true
  def list_audit_events(round_id, opts \\ []) do
    Agent.get(__MODULE__, fn state ->
      if Map.has_key?(state.rounds, round_id) do
        {:ok, filter_events(Map.get(state.audit_events, round_id, []), opts)}
      else
        {:error, :not_found}
      end
    end)
  end

  @impl true
  def list_attempt_journals(round_id) do
    Agent.get(__MODULE__, fn state ->
      journals =
        state.attempt_journals
        |> Enum.filter(fn {{journal_round_id, _shot_id, _attempt}, _journal} ->
          journal_round_id == round_id
        end)
        |> Enum.map(fn {_key, journal} -> journal end)

      {:ok, journals}
    end)
  end

  @impl true
  def list_tool_journals(round_id) do
    Agent.get(__MODULE__, fn state ->
      journals =
        state.tool_journals
        |> Enum.filter(fn {{journal_round_id, _shot_id, _attempt, _tool_id}, _journal} ->
          journal_round_id == round_id
        end)
        |> Enum.map(fn {_key, journal} -> journal end)

      {:ok, journals}
    end)
  end

  @impl true
  def list_incomplete_rounds do
    Agent.get(__MODULE__, fn state ->
      rounds =
        state.rounds
        |> Map.values()
        |> Enum.reject(&(normalize_status(value(&1, :status)) in @terminal_statuses))
        |> Enum.sort_by(&round_id/1)

      {:ok, rounds}
    end)
  end

  @impl true
  def stats do
    Agent.get(__MODULE__, fn state ->
      incomplete =
        Enum.count(state.rounds, fn {_id, snapshot} ->
          normalize_status(value(snapshot, :status)) not in @terminal_statuses
        end)

      {:ok,
       %{
         rounds: map_size(state.rounds),
         incomplete_rounds: incomplete,
         terminal_rounds: map_size(state.rounds) - incomplete,
         round_events: state.events |> Map.values() |> Enum.map(&length/1) |> Enum.sum(),
         audit_events: state.audit_events |> Map.values() |> Enum.map(&length/1) |> Enum.sum()
       }}
    end)
  end

  defp mutate(operation, fun) do
    Agent.get_and_update(__MODULE__, fn state ->
      state = update_in(state.calls, &[operation | &1])

      case pop_failure(operation, state.failures) do
        {:fail, reason, failures} ->
          {{:error, reason}, %{state | failures: failures}}

        {:ok, failures} ->
          {reply, state} = fun.(%{state | failures: failures})
          {reply, state}
      end
    end)
  end

  defp fetch(operation, path) do
    Agent.get(__MODULE__, fn state ->
      state = update_in(state.calls, &[operation | &1])

      case get_in(state, path) do
        nil -> {:error, :not_found}
        value -> {:ok, value}
      end
    end)
  end

  defp pop_failure(operation, failures) do
    case failures do
      [{^operation, reason} | rest] -> {:fail, reason, rest}
      [{:all, reason} | rest] -> {:fail, reason, rest}
      _other -> {:ok, failures}
    end
  end

  defp append_audit(state, _round_id, []), do: state

  defp append_audit(state, round_id, audit_events) do
    events = assign_event_sequences(Map.get(state.audit_events, round_id, []), audit_events)
    update_in(state.audit_events[round_id], &((&1 || []) ++ events))
  end

  defp assign_event_sequences(existing, events) do
    first_seq = length(existing) + 1

    events
    |> Enum.with_index(first_seq)
    |> Enum.map(fn {event, seq} -> put_value(event, :seq, value(event, :seq) || seq) end)
  end

  defp filter_events(events, opts) do
    after_seq = Keyword.get(opts, :after_seq, 0)
    limit = Keyword.get(opts, :limit, 100)

    events
    |> Enum.filter(&(value(&1, :seq) > after_seq))
    |> Enum.take(limit)
  end

  defp shot_run(round_id, shot) do
    %{
      round_id: round_id,
      shot_id: value(shot, :id),
      kind: normalize_status(value(shot, :kind)),
      status: normalize_status(value(shot, :status)),
      attempt: value(shot, :attempt) || 0,
      output: value(shot, :output),
      error: value(shot, :error)
    }
  end

  defp attempt_key(record),
    do: {round_id(record), value(record, :shot_id), value(record, :attempt)}

  defp tool_key(record) do
    {
      round_id(record),
      value(record, :shot_id),
      value(record, :attempt),
      value(record, :provider_tool_call_id) || value(record, :tool_call_index) ||
        value(record, :id)
    }
  end

  defp round_id(record), do: value(record, :round_id) || value(record, :id)
  defp version(record), do: value(record, :version) || 0

  defp value(record, key) when is_map(record),
    do: Map.get(record, key) || Map.get(record, Atom.to_string(key))

  defp put_value(record, key, value) when is_map(record), do: Map.put(record, key, value)

  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status(status) when is_binary(status), do: String.to_existing_atom(status)
  defp normalize_status(status), do: status
end
