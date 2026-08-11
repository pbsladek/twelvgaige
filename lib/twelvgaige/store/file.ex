defmodule Twelvgaige.Store.File do
  @moduledoc """
  Atomic file-backed store for Phase 4 recovery work.

  This is a local durable implementation of the `Twelvgaige.Store` behaviour.
  It persists the complete store state after each accepted mutation using
  Erlang's external term format and an atomic rename. SQLite remains the target
  production store, but this module gives recovery code a durable contract
  without adding a database dependency first.
  """

  use GenServer

  @behaviour Twelvgaige.Store

  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.Audit.Chain, as: AuditChain
  alias Twelvgaige.Redactor
  alias Twelvgaige.Round.ShotRun
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Security.FileMode
  alias Twelvgaige.Store.Retention
  alias Twelvgaige.Store.SQLite.TermCodec

  @terminal_statuses MapSet.new([:complete, :failed, :halted, :cancelled])
  @max_event_wait_ms 30_000

  defstruct [
    :path,
    rounds: %{},
    manifests: %{},
    events: %{},
    audit_events: %{},
    attempts: %{},
    tool_intents: %{},
    event_watchers: %{},
    event_watcher_refs: %{},
    committed_transitions: MapSet.new(),
    next_seq: %{},
    max_retained_bytes: nil,
    sensitive_retention: :redacted,
    evicted_rounds: 0
  ]

  @type start_option :: GenServer.option() | {:path, Path.t()}

  @spec start_link([start_option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:path) |> Path.expand()

    with :ok <- TermCodec.preload(),
         :ok <- FileMode.ensure_private_parent_dir(path),
         {:ok, state} <- load_state(path) do
      state =
        state
        |> Map.put(:path, path)
        |> Retention.configure(opts)
        |> Retention.enforce()

      with :ok <- persist_state(state) do
        {:ok, state}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl Twelvgaige.Store
  def create_round(snapshot, manifest, audit_events) do
    GenServer.call(__MODULE__, {:create_round, snapshot, manifest, audit_events})
  end

  @impl Twelvgaige.Store
  def record_attempt_started(attempt, audit_events) do
    GenServer.call(__MODULE__, {:record_attempt_started, attempt, audit_events})
  end

  @impl Twelvgaige.Store
  def record_attempt_finished(attempt, audit_events) do
    GenServer.call(__MODULE__, {:record_attempt_finished, attempt, audit_events})
  end

  @impl Twelvgaige.Store
  def record_tool_intent(intent, audit_events) do
    GenServer.call(__MODULE__, {:record_tool_intent, intent, audit_events})
  end

  @impl Twelvgaige.Store
  def record_tool_result(result, audit_events) do
    GenServer.call(__MODULE__, {:record_tool_result, result, audit_events})
  end

  @impl Twelvgaige.Store
  def list_attempt_journals(round_id) do
    GenServer.call(__MODULE__, {:list_attempt_journals, round_id})
  end

  @impl Twelvgaige.Store
  def list_tool_journals(round_id) do
    GenServer.call(__MODULE__, {:list_tool_journals, round_id})
  end

  @impl Twelvgaige.Store
  def list_audit_events(round_id, opts \\ []) do
    GenServer.call(__MODULE__, {:list_audit_events, round_id, opts})
  end

  @impl Twelvgaige.Store
  def commit_transition(
        round_id,
        expected_version,
        transition_id,
        next_snapshot,
        events,
        audit_events
      ) do
    GenServer.call(
      __MODULE__,
      {:commit_transition, round_id, expected_version, transition_id, next_snapshot, events,
       audit_events}
    )
  end

  @impl Twelvgaige.Store
  def get_round(round_id), do: GenServer.call(__MODULE__, {:get_round, round_id})

  @impl Twelvgaige.Store
  def get_manifest(round_id), do: GenServer.call(__MODULE__, {:get_manifest, round_id})

  @impl Twelvgaige.Store
  def list_rounds(opts \\ []) do
    GenServer.call(__MODULE__, {:list_rounds, opts})
  end

  @impl Twelvgaige.Store
  def list_shot_runs(round_id) do
    GenServer.call(__MODULE__, {:list_shot_runs, round_id})
  end

  @impl Twelvgaige.Store
  def list_round_events(round_id, opts \\ []) do
    GenServer.call(__MODULE__, {:list_round_events, round_id, opts})
  end

  @impl Twelvgaige.Store
  def await_round_events(round_id, opts \\ []) do
    timeout_ms = opts |> Keyword.get(:timeout_ms, @max_event_wait_ms) |> clamp_wait_timeout()
    GenServer.call(__MODULE__, {:await_round_events, round_id, opts}, timeout_ms + 1_000)
  end

  @impl Twelvgaige.Store
  def list_incomplete_rounds, do: GenServer.call(__MODULE__, :list_incomplete_rounds)

  @impl Twelvgaige.Store
  def stats, do: GenServer.call(__MODULE__, :stats)

  @impl true
  def handle_call({:create_round, snapshot, manifest, audit_events}, _from, state) do
    snapshot = Snapshot.persistable(snapshot)
    round_id = fetch_id!(snapshot, :round)
    audit_events = AuditChain.append([], AuditEvent.sanitize_many(audit_events))

    if Map.has_key?(state.rounds, round_id) do
      {:reply, {:error, :round_already_exists}, state}
    else
      state =
        state
        |> put_in([Access.key!(:rounds), round_id], snapshot)
        |> put_in([Access.key!(:manifests), round_id], manifest)
        |> put_in([Access.key!(:events), round_id], [])
        |> put_in([Access.key!(:audit_events), round_id], audit_events)
        |> put_in([Access.key!(:next_seq), round_id], 1)
        |> Retention.enforce()

      persist_reply(:ok, state)
    end
  end

  def handle_call({:record_attempt_started, attempt, audit_events}, _from, state) do
    attempt = sanitize_journal(attempt, state)
    key = attempt_key(attempt)

    case Map.fetch(state.attempts, key) do
      {:ok, ^attempt} ->
        state = append_audit(state, fetch_id!(attempt, :round), audit_events)
        state = Retention.enforce(state)
        persist_reply(:already_recorded, state)

      {:ok, _conflict} ->
        {:reply, {:error, :attempt_journal_conflict}, state}

      :error ->
        state =
          state
          |> put_in([Access.key!(:attempts), key], attempt)
          |> append_audit(fetch_id!(attempt, :round), audit_events)
          |> Retention.enforce()

        persist_reply(:ok, state)
    end
  end

  def handle_call({:record_attempt_finished, attempt, audit_events}, _from, state) do
    attempt = sanitize_journal(attempt, state)
    key = attempt_key(attempt)

    case merge_journal_finish(state.attempts, key, attempt) do
      {:ok, attempts} ->
        state =
          state
          |> Map.put(:attempts, attempts)
          |> append_audit(fetch_id!(attempt, :round), audit_events)
          |> Retention.enforce()

        persist_reply(:ok, state)

      :already_recorded ->
        state = append_audit(state, fetch_id!(attempt, :round), audit_events)
        state = Retention.enforce(state)
        persist_reply(:already_recorded, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:record_tool_intent, intent, audit_events}, _from, state) do
    intent = sanitize_journal(intent, state)
    key = tool_intent_key(intent)

    case Map.fetch(state.tool_intents, key) do
      {:ok, ^intent} ->
        state = append_audit(state, fetch_id!(intent, :round), audit_events)
        state = Retention.enforce(state)
        persist_reply(:already_recorded, state)

      {:ok, _conflict} ->
        {:reply, {:error, :tool_intent_conflict}, state}

      :error ->
        state =
          state
          |> put_in([Access.key!(:tool_intents), key], intent)
          |> append_audit(fetch_id!(intent, :round), audit_events)
          |> Retention.enforce()

        persist_reply(:ok, state)
    end
  end

  def handle_call({:record_tool_result, result, audit_events}, _from, state) do
    result = sanitize_journal(result, state)
    key = tool_intent_key(result)

    case merge_journal_finish(state.tool_intents, key, result) do
      {:ok, tool_intents} ->
        state =
          state
          |> Map.put(:tool_intents, tool_intents)
          |> append_audit(fetch_id!(result, :round), audit_events)
          |> Retention.enforce()

        persist_reply(:ok, state)

      :already_recorded ->
        state = append_audit(state, fetch_id!(result, :round), audit_events)
        state = Retention.enforce(state)
        persist_reply(:already_recorded, state)

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:list_attempt_journals, round_id}, _from, state) do
    journals =
      state.attempts
      |> Map.values()
      |> Enum.filter(&(value(&1, :round_id) == round_id))
      |> Enum.sort_by(&{to_string(value(&1, :shot_id)), value(&1, :attempt) || 0})

    {:reply, {:ok, journals}, state}
  end

  def handle_call({:list_tool_journals, round_id}, _from, state) do
    journals =
      state.tool_intents
      |> Map.values()
      |> Enum.filter(&(value(&1, :round_id) == round_id))
      |> Enum.sort_by(
        &{to_string(value(&1, :shot_id)), value(&1, :attempt) || 0, tool_journal_id(&1)}
      )

    {:reply, {:ok, journals}, state}
  end

  def handle_call({:list_audit_events, round_id, opts}, _from, state) do
    cond do
      Map.has_key?(state.audit_events, round_id) ->
        {:reply, {:ok, audit_events_after(Map.get(state.audit_events, round_id, []), opts)},
         state}

      Map.has_key?(state.rounds, round_id) ->
        {:reply, {:ok, []}, state}

      true ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(
        {:commit_transition, round_id, expected_version, transition_id, next_snapshot, events,
         audit_events},
        _from,
        state
      ) do
    transition_key = {round_id, transition_id}

    cond do
      MapSet.member?(state.committed_transitions, transition_key) ->
        {:reply, :already_committed, state}

      not Map.has_key?(state.rounds, round_id) ->
        {:reply, {:error, :not_found}, state}

      snapshot_version(state.rounds[round_id]) != expected_version ->
        {:reply, {:error, :version_conflict}, state}

      true ->
        {events, next_seq} = assign_event_sequences(events, state.next_seq[round_id] || 1)

        next_snapshot =
          next_snapshot
          |> put_value(:version, expected_version + 1)
          |> Snapshot.persistable()

        state =
          state
          |> put_in([Access.key!(:rounds), round_id], next_snapshot)
          |> update_in([Access.key!(:events), round_id], &((&1 || []) ++ events))
          |> append_audit(round_id, audit_events)
          |> put_in([Access.key!(:next_seq), round_id], next_seq)
          |> update_in([Access.key!(:committed_transitions)], &MapSet.put(&1, transition_key))
          |> notify_event_watchers(round_id)
          |> Retention.enforce()

        persist_reply(:ok, state)
    end
  end

  def handle_call({:get_round, round_id}, _from, state) do
    {:reply, fetch_record(state.rounds, round_id), state}
  end

  def handle_call({:get_manifest, round_id}, _from, state) do
    {:reply, fetch_record(state.manifests, round_id), state}
  end

  def handle_call({:list_rounds, opts}, _from, state) do
    status = Keyword.get(opts, :status)

    rounds =
      state.rounds
      |> Map.values()
      |> filter_status(status)
      |> Enum.sort_by(&to_string(value(&1, :id)))

    {:reply, {:ok, rounds}, state}
  end

  def handle_call({:list_shot_runs, round_id}, _from, state) do
    case Map.fetch(state.rounds, round_id) do
      {:ok, snapshot} -> {:reply, {:ok, ShotRun.from_snapshot(snapshot)}, state}
      :error -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:list_round_events, round_id, opts}, _from, state) do
    if Map.has_key?(state.rounds, round_id) do
      {:reply, {:ok, events_after(state, round_id, opts)}, state}
    else
      {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:await_round_events, round_id, opts}, from, state) do
    cond do
      not Map.has_key?(state.rounds, round_id) ->
        {:reply, {:error, :not_found}, state}

      events = events_after(state, round_id, opts) ->
        if events == [] do
          watcher_ref = make_ref()

          timeout_ms =
            opts |> Keyword.get(:timeout_ms, @max_event_wait_ms) |> clamp_wait_timeout()

          timer_ref = Process.send_after(self(), {:event_wait_timeout, watcher_ref}, timeout_ms)

          watcher = %{round_id: round_id, opts: opts, from: from, timer_ref: timer_ref}

          state =
            state
            |> put_in([Access.key!(:event_watchers), watcher_ref], watcher)
            |> update_in(
              [Access.key!(:event_watcher_refs), round_id],
              &MapSet.put(&1 || MapSet.new(), watcher_ref)
            )

          {:noreply, state}
        else
          {:reply, {:ok, events}, state}
        end
    end
  end

  def handle_call(:list_incomplete_rounds, _from, state) do
    rounds =
      state.rounds
      |> Map.values()
      |> Enum.reject(&(value(&1, :status) in @terminal_statuses))

    {:reply, {:ok, rounds}, state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, {:ok, Retention.stats(state, @terminal_statuses)}, state}
  end

  @impl true
  def handle_info({:event_wait_timeout, watcher_ref}, state) do
    case Map.fetch(state.event_watchers, watcher_ref) do
      {:ok, watcher} ->
        events = events_after(state, watcher.round_id, watcher.opts)
        GenServer.reply(watcher.from, {:ok, events})
        {:noreply, delete_event_watcher(state, watcher_ref, watcher)}

      :error ->
        {:noreply, state}
    end
  end

  defp persist_reply(reply, state) do
    case persist_state(state) do
      :ok -> {:reply, reply, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Local state is decoded in restricted mode and must match the store struct.
  # sobelow_skip ["Misc.BinToTerm"]
  defp load_state(path) do
    case File.read(path) do
      {:ok, binary} ->
        case :erlang.binary_to_term(binary, [:safe]) do
          %__MODULE__{} = state -> upgrade_state(state, path)
          _other -> {:error, :store_corrupt}
        end

      {:error, :enoent} ->
        {:ok, %__MODULE__{path: path}}

      {:error, _reason} = error ->
        error
    end
  rescue
    _error -> {:error, :store_corrupt}
  end

  defp upgrade_state(%__MODULE__{} = state, path) do
    defaults = Map.from_struct(%__MODULE__{})
    persisted = Map.from_struct(state)
    state = struct!(__MODULE__, Map.merge(defaults, persisted))

    rounds =
      Map.new(state.rounds, fn {round_id, snapshot} -> {round_id, Snapshot.upgrade(snapshot)} end)

    with {:ok, audit_events} <- upgrade_audit_events(state.audit_events) do
      {:ok, %{state | path: path, rounds: rounds, audit_events: audit_events}}
    end
  end

  defp upgrade_audit_events(audit_events) do
    Enum.reduce_while(audit_events, {:ok, %{}}, fn {round_id, events}, {:ok, migrated} ->
      case upgrade_round_audit_events(round_id, events) do
        {:ok, upgraded} -> {:cont, {:ok, Map.put(migrated, round_id, upgraded)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp upgrade_round_audit_events(round_id, events) do
    cond do
      Enum.all?(events, &legacy_unchained_audit?/1) ->
        {:ok, AuditChain.extend(AuditChain.genesis(), events)}

      Enum.all?(events, &chained_audit?/1) ->
        case AuditChain.verify(events) do
          :ok -> {:ok, events}
          {:error, reason} -> {:error, {:audit_chain_invalid, round_id, reason}}
        end

      true ->
        {:error, {:audit_chain_migration_ambiguous, round_id}}
    end
  end

  defp legacy_unchained_audit?(event) do
    is_nil(value(event, :audit_chain_algorithm)) and
      is_nil(value(event, :audit_previous_hash)) and
      is_nil(value(event, :audit_chain_hash))
  end

  defp chained_audit?(event) do
    is_binary(value(event, :audit_chain_algorithm)) and
      is_binary(value(event, :audit_previous_hash)) and
      is_binary(value(event, :audit_chain_hash))
  end

  defp persist_state(%__MODULE__{} = state) do
    persisted = %{state | event_watchers: %{}, event_watcher_refs: %{}}
    tmp_path = state.path <> ".tmp"
    binary = :erlang.term_to_binary(persisted)

    with :ok <- File.write(tmp_path, binary),
         :ok <- FileMode.ensure_private_file(tmp_path),
         :ok <- File.rename(tmp_path, state.path) do
      FileMode.ensure_private_file(state.path)
    end
  end

  defp append_audit(state, _round_id, []), do: state

  defp append_audit(state, round_id, audit_events) do
    existing = Map.get(state.audit_events, round_id, [])
    audit_events = AuditChain.append(existing, AuditEvent.sanitize_many(audit_events))

    put_in(state.audit_events[round_id], existing ++ audit_events)
  end

  defp sanitize_journal(%{} = journal, %{sensitive_retention: :summary}) do
    Redactor.summarize_sensitive_payloads(journal)
  end

  defp sanitize_journal(%{} = journal, _state), do: Redactor.redact_json(journal)

  defp merge_journal_finish(records, key, finish) do
    case Map.fetch(records, key) do
      {:ok, existing} ->
        merged = Map.merge(existing, finish)

        cond do
          existing == merged ->
            :already_recorded

          finished_journal?(existing) ->
            {:error, :journal_conflict}

          true ->
            {:ok, Map.put(records, key, merged)}
        end

      :error ->
        {:error, :journal_missing}
    end
  end

  defp finished_journal?(record) do
    value(record, :status) in [:completed, :failed, :observed_result, :reconcile_required]
  end

  defp tool_journal_id(record) do
    value(record, :provider_tool_call_id) || value(record, :tool_call_index) || value(record, :id) ||
      ""
  end

  defp fetch_record(records, id) do
    case Map.fetch(records, id) do
      {:ok, record} -> {:ok, record}
      :error -> {:error, :not_found}
    end
  end

  defp filter_status(rounds, nil), do: rounds

  defp filter_status(rounds, status) do
    status = normalize_status(status)

    Enum.filter(rounds, &(normalize_status(value(&1, :status)) == status))
  end

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(status), do: to_string(status)

  defp assign_event_sequences(events, first_seq) do
    Enum.map_reduce(events, first_seq, fn event, seq ->
      {put_value(event, :seq, seq), seq + 1}
    end)
  end

  defp events_after(state, round_id, opts) do
    after_seq = opts |> Keyword.get(:after_seq, 0) |> normalize_non_negative_integer(0)
    limit = opts |> Keyword.get(:limit, 100) |> normalize_positive_integer(100) |> min(1_000)

    state.events
    |> Map.get(round_id, [])
    |> events_after_seq(after_seq, limit)
  end

  defp audit_events_after(events, opts) do
    after_seq = opts |> Keyword.get(:after_seq, 0) |> normalize_non_negative_integer(0)
    limit = opts |> Keyword.get(:limit, 100) |> normalize_positive_integer(100) |> min(1_000)

    events
    |> audit_events_after_seq(after_seq, limit)
  end

  defp events_after_seq(events, after_seq, limit) do
    events
    |> Enum.reduce_while({[], 0}, fn event, {acc, count} ->
      cond do
        count >= limit -> {:halt, {acc, count}}
        value(event, :seq) <= after_seq -> {:cont, {acc, count}}
        true -> {:cont, {[event | acc], count + 1}}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp audit_events_after_seq(events, after_seq, limit) do
    events
    |> Enum.reduce_while({[], 0, 1}, fn event, {acc, count, seq} ->
      cond do
        count >= limit ->
          {:halt, {acc, count, seq}}

        true ->
          event = put_value(event, :seq, value(event, :seq) || seq)
          next_seq = seq + 1

          if value(event, :seq) > after_seq do
            {:cont, {[event | acc], count + 1, next_seq}}
          else
            {:cont, {acc, count, next_seq}}
          end
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp notify_event_watchers(state, round_id) do
    watcher_refs = Map.get(state.event_watcher_refs, round_id, MapSet.new())

    Enum.reduce(watcher_refs, state, fn watcher_ref, acc ->
      case Map.fetch(acc.event_watchers, watcher_ref) do
        {:ok, watcher} ->
          case events_after(acc, round_id, watcher.opts) do
            [] ->
              acc

            events ->
              Process.cancel_timer(watcher.timer_ref)
              GenServer.reply(watcher.from, {:ok, events})
              delete_event_watcher(acc, watcher_ref, watcher)
          end

        :error ->
          update_in(
            acc.event_watcher_refs[round_id],
            &MapSet.delete(&1 || MapSet.new(), watcher_ref)
          )
      end
    end)
  end

  defp delete_event_watcher(state, watcher_ref, watcher) do
    state
    |> update_in([Access.key!(:event_watchers)], &Map.delete(&1, watcher_ref))
    |> update_in([Access.key!(:event_watcher_refs), watcher.round_id], fn refs ->
      refs = refs || MapSet.new()
      MapSet.delete(refs, watcher_ref)
    end)
  end

  defp normalize_non_negative_integer(value, _default) when is_integer(value) and value >= 0,
    do: value

  defp normalize_non_negative_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> default
    end
  end

  defp normalize_non_negative_integer(_value, default), do: default

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp clamp_wait_timeout(timeout_ms) when is_integer(timeout_ms) do
    timeout_ms
    |> max(0)
    |> min(@max_event_wait_ms)
  end

  defp clamp_wait_timeout(timeout_ms) when is_binary(timeout_ms) do
    case Integer.parse(timeout_ms) do
      {integer, ""} -> clamp_wait_timeout(integer)
      _other -> @max_event_wait_ms
    end
  end

  defp clamp_wait_timeout(_timeout_ms), do: @max_event_wait_ms

  defp attempt_key(attempt) do
    {fetch_id!(attempt, :round), value(attempt, :shot_id), value(attempt, :attempt)}
  end

  defp tool_intent_key(intent) do
    {
      fetch_id!(intent, :round),
      value(intent, :shot_id),
      value(intent, :attempt),
      value(intent, :provider_tool_call_id) || value(intent, :tool_call_index) ||
        value(intent, :id)
    }
  end

  defp fetch_id!(record, :round) do
    value(record, :round_id) || value(record, :id) || raise ArgumentError, "missing round id"
  end

  defp snapshot_version(snapshot), do: value(snapshot, :version) || 0

  defp value(record, key) when is_map(record) do
    Map.get(record, key) || Map.get(record, Atom.to_string(key))
  end

  defp put_value(record, key, value) when is_map(record) do
    Map.put(record, key, value)
  end
end
