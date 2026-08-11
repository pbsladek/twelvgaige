defmodule Twelvgaige.Operations.Store do
  @moduledoc """
  Durable SQLite state for unattended single-user operation.

  Records are namespaced, versioned, and written transactionally. Replay claims
  use a separate unique-key table so an automation occurrence cannot be admitted
  twice after a restart. Audit events are hash chained before persistence.
  """

  use GenServer

  alias Ecto.Adapters.SQL
  alias Twelvgaige.Audit.Chain
  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.Store.SQLite.Repo

  @schema_version 3
  @live_authority_namespaces ["control_token", "credential", "sandbox_resource"]

  defstruct [:path, :repo, raw_retention_days: 30, security_retention_days: 90]

  @type retention_class :: :raw | :security | :permanent

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    start_opts = Keyword.delete(opts, :name)

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, start_opts),
      else: GenServer.start_link(__MODULE__, start_opts, name: name)
  end

  def put(namespace, key, value, opts \\ []) do
    call(opts, {:put, to_string(namespace), to_string(key), value, opts})
  end

  def put_new(namespace, key, value, opts \\ []) do
    call(opts, {:put_new, to_string(namespace), to_string(key), value, opts})
  end

  def put_many_new(entries, opts \\ []) when is_list(entries) do
    normalized =
      Enum.map(entries, fn {namespace, key, value} ->
        {to_string(namespace), to_string(key), value}
      end)

    call(opts, {:put_many_new, normalized, opts})
  end

  def compare_and_put(namespace, key, expected_version, value, opts \\ []) do
    call(
      opts,
      {:compare_and_put, to_string(namespace), to_string(key), expected_version, value, opts}
    )
  end

  def get(namespace, key, opts \\ []) do
    call(opts, {:get, to_string(namespace), to_string(key)})
  end

  def list(namespace, opts \\ []) do
    call(opts, {:list, to_string(namespace)})
  end

  def delete(namespace, key, opts \\ []) do
    call(opts, {:delete, to_string(namespace), to_string(key)})
  end

  def claim_once(namespace, occurrence_id, value, opts \\ []) do
    call(opts, {:claim_once, to_string(namespace), to_string(occurrence_id), value})
  end

  def append_audit(event, opts \\ []) when is_map(event), do: call(opts, {:append_audit, event})
  def list_audit(opts \\ []), do: call(opts, :list_audit)
  def audit_snapshot(opts \\ []), do: call(opts, :audit_snapshot)
  def prune(opts \\ []), do: call(opts, {:prune, Keyword.get(opts, :now, DateTime.utc_now())})
  def stats(opts \\ []), do: call(opts, :stats)

  def backup(destination, opts \\ []) do
    call(opts, {:backup, Path.expand(destination)}, Keyword.get(opts, :timeout, 60_000))
  end

  @doc "Restores an operations backup while stripping all live authority."
  def restore_backup(source, destination, opts \\ []) do
    source = Path.expand(source)
    destination = Path.expand(destination)
    temporary = destination <> ".restore-" <> unique_suffix()

    result =
      with :ok <- distinct_paths(source, destination),
           :ok <- require_regular_file(source),
           :ok <- require_available_destination(destination, opts),
           :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.cp(source, temporary),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- sanitize_restored_database(temporary),
           {:ok, audit_verified?} <- verify_restored_audit(temporary, opts),
           :ok <- install_restore(temporary, destination, opts) do
        {:ok,
         %{
           source: source,
           destination: destination,
           live_credentials_restored: false,
           audit_checkpoint_verified: audit_verified?
         }}
      end

    if match?({:error, _reason}, result), do: File.rm(temporary)
    result
  end

  @impl true
  def init(opts) do
    path = opts |> Keyword.fetch!(:path) |> Path.expand()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         {:ok, repo} <- start_repo(path),
         :ok <- ensure_schema(repo),
         :ok <- protect_files(path) do
      {:ok,
       %__MODULE__{
         path: path,
         repo: repo,
         raw_retention_days: Keyword.get(opts, :raw_retention_days, 30),
         security_retention_days: Keyword.get(opts, :security_retention_days, 90)
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{repo: repo}), do: stop_repo(repo)

  @impl true
  def handle_call({:put, namespace, key, value, opts}, _from, state) do
    now = iso8601(Keyword.get(opts, :now, DateTime.utc_now()))
    {class, expires_at, hold_until} = retention(opts, state)
    encoded = encode(value)

    result =
      SQL.query(
        state.repo,
        """
        INSERT INTO records(namespace, record_key, value, version, retention_class, expires_at, hold_until, inserted_at, updated_at)
        VALUES(?, ?, ?, 1, ?, ?, ?, ?, ?)
        ON CONFLICT(namespace, record_key) DO UPDATE SET
          value = excluded.value,
          version = records.version + 1,
          retention_class = excluded.retention_class,
          expires_at = excluded.expires_at,
          hold_until = excluded.hold_until,
          updated_at = excluded.updated_at
        """,
        [namespace, key, encoded, class, expires_at, hold_until, now, now]
      )

    {:reply, sql_ok(result), state}
  end

  def handle_call({:put_new, namespace, key, value, opts}, _from, state) do
    now = iso8601(Keyword.get(opts, :now, DateTime.utc_now()))
    {class, expires_at, hold_until} = retention(opts, state)

    result =
      SQL.query(
        state.repo,
        """
        INSERT OR IGNORE INTO records(namespace, record_key, value, version, retention_class, expires_at, hold_until, inserted_at, updated_at)
        VALUES(?, ?, ?, 1, ?, ?, ?, ?, ?)
        """,
        [namespace, key, encode(value), class, expires_at, hold_until, now, now]
      )

    reply =
      case result do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, %{num_rows: 0}} -> :already_present
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:put_many_new, entries, opts}, _from, state) do
    now = iso8601(Keyword.get(opts, :now, DateTime.utc_now()))
    {class, expires_at, hold_until} = retention(opts, state)
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(state.repo)

    reply =
      try do
        Repo.transaction(fn ->
          Enum.each(entries, fn {namespace, key, value} ->
            case SQL.query(
                   state.repo,
                   "INSERT INTO records(namespace, record_key, value, version, retention_class, expires_at, hold_until, inserted_at, updated_at) VALUES(?, ?, ?, 1, ?, ?, ?, ?, ?)",
                   [namespace, key, encode(value), class, expires_at, hold_until, now, now]
                 ) do
              {:ok, _} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end)
        end)
      after
        Repo.put_dynamic_repo(previous)
      end

    reply =
      case reply do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:compare_and_put, namespace, key, expected, value, opts}, _from, state) do
    now = iso8601(Keyword.get(opts, :now, DateTime.utc_now()))
    {class, expires_at, hold_until} = retention(opts, state)

    result =
      SQL.query(
        state.repo,
        "UPDATE records SET value = ?, version = version + 1, retention_class = ?, expires_at = ?, hold_until = ?, updated_at = ? WHERE namespace = ? AND record_key = ? AND version = ?",
        [encode(value), class, expires_at, hold_until, now, namespace, key, expected]
      )

    reply =
      case result do
        {:ok, %{num_rows: 1}} -> :ok
        {:ok, %{num_rows: 0}} -> {:error, :version_conflict}
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:get, namespace, key}, _from, state) do
    result =
      SQL.query(
        state.repo,
        "SELECT value, version, retention_class, expires_at, hold_until, inserted_at, updated_at FROM records WHERE namespace = ? AND record_key = ?",
        [namespace, key]
      )

    reply =
      case result do
        {:ok, %{rows: [[value, version, class, expires, hold, inserted, updated]]}} ->
          with {:ok, value} <- decode(value) do
            {:ok,
             %{
               key: key,
               value: value,
               version: version,
               retention_class: String.to_existing_atom(class),
               expires_at: parse_time(expires),
               hold_until: parse_time(hold),
               inserted_at: parse_time(inserted),
               updated_at: parse_time(updated)
             }}
          end

        {:ok, %{rows: []}} ->
          {:error, :not_found}

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:list, namespace}, _from, state) do
    result =
      SQL.query(
        state.repo,
        "SELECT record_key, value, version, retention_class, expires_at, hold_until, inserted_at, updated_at FROM records WHERE namespace = ? ORDER BY record_key",
        [namespace]
      )

    reply =
      case result do
        {:ok, %{rows: rows}} ->
          rows
          |> Enum.reduce_while({:ok, []}, fn [
                                               key,
                                               value,
                                               version,
                                               class,
                                               expires,
                                               hold,
                                               inserted,
                                               updated
                                             ],
                                             {:ok, acc} ->
            case decode(value) do
              {:ok, decoded} ->
                record = %{
                  key: key,
                  value: decoded,
                  version: version,
                  retention_class: String.to_existing_atom(class),
                  expires_at: parse_time(expires),
                  hold_until: parse_time(hold),
                  inserted_at: parse_time(inserted),
                  updated_at: parse_time(updated)
                }

                {:cont, {:ok, [record | acc]}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)
          |> case do
            {:ok, records} -> {:ok, Enum.reverse(records)}
            error -> error
          end

        {:error, reason} ->
          {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:delete, namespace, key}, _from, state) do
    result =
      SQL.query(state.repo, "DELETE FROM records WHERE namespace = ? AND record_key = ?", [
        namespace,
        key
      ])

    {:reply, sql_ok(result), state}
  end

  def handle_call({:claim_once, namespace, occurrence_id, value}, _from, state) do
    result =
      SQL.query(
        state.repo,
        "INSERT OR IGNORE INTO replay_claims(namespace, occurrence_id, value, claimed_at) VALUES(?, ?, ?, ?)",
        [namespace, occurrence_id, encode(value), iso8601(DateTime.utc_now())]
      )

    reply =
      case result do
        {:ok, %{num_rows: 1}} -> :claimed
        {:ok, %{num_rows: 0}} -> :duplicate
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, state}
  end

  def handle_call({:append_audit, event}, _from, state) do
    occurred_at =
      event
      |> Map.get(:occurred_at, Map.get(event, "occurred_at", DateTime.utc_now()))
      |> audit_occurred_at()

    with {:ok, previous_hash} <- audit_tail_hash(state.repo),
         [chained] <- Chain.extend(previous_hash, [event]),
         {:ok, encoded} <- chained |> AuditEvent.to_map() |> Jason.encode(),
         {:ok, _result} <-
           SQL.query(
             state.repo,
             "INSERT INTO audit_events(event_id, occurred_at, chain_hash, payload, expires_at) VALUES(?, ?, ?, ?, ?)",
             [
               Map.get(chained, :event_id, Twelvgaige.ID.new(:event)),
               iso8601(occurred_at),
               chained.audit_chain_hash,
               encoded,
               occurred_at
               |> DateTime.add(state.security_retention_days * 86_400, :second)
               |> iso8601()
             ]
           ) do
      {:reply, {:ok, chained}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:list_audit, _from, state), do: {:reply, load_audit(state.repo), state}

  def handle_call(:audit_snapshot, _from, state),
    do: {:reply, load_audit_snapshot(state.repo), state}

  def handle_call({:prune, %DateTime{} = now}, _from, state) do
    now = iso8601(now)
    {:reply, prune_expired(state.repo, now), state}
  end

  def handle_call(:stats, _from, state) do
    with {:ok, %{rows: [[records]]}} <- SQL.query(state.repo, "SELECT COUNT(*) FROM records", []),
         {:ok, %{rows: [[claims]]}} <-
           SQL.query(state.repo, "SELECT COUNT(*) FROM replay_claims", []),
         {:ok, %{rows: [[audits]]}} <-
           SQL.query(state.repo, "SELECT COUNT(*) FROM audit_events", []),
         {:ok, %{rows: [[version]]}} <- SQL.query(state.repo, "PRAGMA user_version", []) do
      {:reply,
       {:ok,
        %{
          path: state.path,
          schema_version: version,
          records: records,
          claims: claims,
          audits: audits
        }}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:backup, destination}, _from, state) do
    result =
      case require_available_destination(destination, []) do
        :ok ->
          created =
            with escaped = String.replace(destination, "'", "''"),
                 {:ok, _} <- SQL.query(state.repo, "VACUUM INTO '#{escaped}'", []),
                 :ok <- File.chmod(destination, 0o600),
                 :ok <- sanitize_backup(destination) do
              {:ok,
               %{
                 source: state.path,
                 destination: destination,
                 schema_version: @schema_version,
                 live_credentials_included: false
               }}
            end

          if match?({:error, _reason}, created), do: File.rm(destination)
          created

        {:error, _reason} = error ->
          error
      end

    {:reply, result, state}
  end

  defp call(opts, request, timeout \\ 30_000) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), request, timeout)
  end

  defp start_repo(path) do
    Repo.start_link(
      database: path,
      pool_size: 1,
      name: nil,
      busy_timeout: 5_000,
      journal_mode: :wal,
      log: false
    )
  end

  defp stop_repo(repo) when is_pid(repo) do
    if Process.alive?(repo), do: Supervisor.stop(repo)
    :ok
  end

  defp ensure_schema(repo) do
    with {:ok, _} <- SQL.query(repo, "PRAGMA foreign_keys = ON", []),
         {:ok, %{rows: [[version]]}} <- SQL.query(repo, "PRAGMA user_version", []),
         :ok <- migrate(repo, version) do
      :ok
    end
  end

  defp migrate(_repo, @schema_version), do: :ok

  defp migrate(repo, 0) do
    statements = [
      """
      CREATE TABLE records(
        namespace TEXT NOT NULL,
        record_key TEXT NOT NULL,
        value BLOB NOT NULL,
        version INTEGER NOT NULL,
        retention_class TEXT NOT NULL,
        expires_at TEXT,
        hold_until TEXT,
        inserted_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(namespace, record_key)
      )
      """,
      """
      CREATE TABLE replay_claims(
        namespace TEXT NOT NULL,
        occurrence_id TEXT NOT NULL,
        value BLOB NOT NULL,
        claimed_at TEXT NOT NULL,
        PRIMARY KEY(namespace, occurrence_id)
      )
      """,
      "PRAGMA user_version = 1"
    ]

    with :ok <- transaction_statements(repo, statements), do: migrate(repo, 1)
  end

  defp migrate(repo, 1) do
    statements = [
      """
      CREATE TABLE audit_events(
        sequence INTEGER PRIMARY KEY AUTOINCREMENT,
        event_id TEXT NOT NULL UNIQUE,
        occurred_at TEXT NOT NULL,
        chain_hash TEXT NOT NULL,
        payload TEXT NOT NULL
      )
      """,
      "CREATE INDEX records_expiry_idx ON records(expires_at, hold_until)",
      "PRAGMA user_version = 2"
    ]

    with :ok <- transaction_statements(repo, statements), do: migrate(repo, 2)
  end

  defp migrate(repo, 2) do
    statements = [
      "ALTER TABLE audit_events ADD COLUMN expires_at TEXT",
      "UPDATE audit_events SET expires_at = datetime(occurred_at, '+90 days') WHERE expires_at IS NULL",
      "CREATE INDEX audit_events_expiry_idx ON audit_events(expires_at)",
      """
      CREATE TABLE audit_chain_state(
        id INTEGER PRIMARY KEY CHECK(id = 1),
        anchor_hash TEXT NOT NULL,
        pruned_through_sequence INTEGER NOT NULL,
        updated_at TEXT NOT NULL
      )
      """,
      "INSERT INTO audit_chain_state(id, anchor_hash, pruned_through_sequence, updated_at) VALUES(1, '#{Chain.genesis()}', 0, datetime('now'))",
      "PRAGMA user_version = 3"
    ]

    transaction_statements(repo, statements)
  end

  defp migrate(_repo, version), do: {:error, {:unsupported_operations_schema, version}}

  defp transaction_statements(repo, statements) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(repo)

    try do
      case Repo.transaction(fn ->
             Enum.each(statements, fn statement ->
               case SQL.query(repo, statement, []) do
                 {:ok, _} -> :ok
                 {:error, reason} -> Repo.rollback(reason)
               end
             end)
           end) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp scrub_restored_authority(repo) do
    placeholders = Enum.map_join(@live_authority_namespaces, ",", fn _ -> "?" end)

    with {:ok, _} <-
           SQL.query(
             repo,
             "DELETE FROM records WHERE namespace IN (#{placeholders})",
             @live_authority_namespaces
           ),
         {:ok, %{rows: rows}} <-
           SQL.query(
             repo,
             "SELECT record_key, value FROM records WHERE namespace = 'session'",
             []
           ),
         :ok <- quarantine_restored_sessions(repo, rows) do
      :ok
    end
  end

  defp quarantine_restored_sessions(repo, rows) do
    Enum.reduce_while(rows, :ok, fn [key, payload], :ok ->
      with {:ok, session} <- decode(payload),
           restored <-
             session
             |> Map.put(:status, :awaiting_reconciliation)
             |> Map.put(:credential_lease_id, nil)
             |> Map.put(:egress_lease_id, nil)
             |> Map.put(:control_lease, nil),
           restored <- Map.update(restored, :control_epoch, 1, &(&1 + 1)),
           restored <- Map.put(restored, :controller_pid, nil),
           {:ok, _} <-
             SQL.query(
               repo,
               "UPDATE records SET value = ?, version = version + 1, updated_at = ? WHERE namespace = 'session' AND record_key = ?",
               [encode(restored), iso8601(DateTime.utc_now()), key]
             ) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp sanitize_backup(path) do
    with {:ok, repo} <- start_repo(path) do
      try do
        with :ok <- ensure_schema(repo),
             :ok <- scrub_restored_authority(repo),
             {:ok, _result} <- SQL.query(repo, "PRAGMA wal_checkpoint(TRUNCATE)", []) do
          :ok
        end
      after
        _ = stop_repo(repo)
      end
    end
  end

  defp sanitize_restored_database(path) do
    with {:ok, repo} <- start_repo(path) do
      try do
        with :ok <- ensure_schema(repo),
             :ok <- scrub_restored_authority(repo),
             {:ok, _result} <- SQL.query(repo, "PRAGMA wal_checkpoint(TRUNCATE)", []) do
          :ok
        end
      after
        _ = stop_repo(repo)
      end
    end
  end

  defp verify_restored_audit(path, opts) do
    checkpoint_path = Keyword.get(opts, :audit_checkpoint_path)
    signing_key = Keyword.get(opts, :audit_signing_key)

    case {checkpoint_path, signing_key} do
      {nil, nil} ->
        {:ok, false}

      {checkpoint_path, signing_key}
      when is_binary(checkpoint_path) and is_binary(signing_key) and byte_size(signing_key) >= 32 ->
        case start_link(name: nil, path: path) do
          {:ok, store} ->
            try do
              case Twelvgaige.Operations.AuditAnchor.verify_store(
                     checkpoint_path,
                     signing_key,
                     store: store,
                     owner_uid: Keyword.get(opts, :owner_uid)
                   ) do
                :ok -> {:ok, true}
                {:error, reason} -> {:error, {:restored_audit_checkpoint_invalid, reason}}
              end
            after
              if Process.alive?(store), do: GenServer.stop(store)
            end

          {:error, reason} ->
            {:error, {:restored_audit_store_unavailable, reason}}
        end

      _other ->
        {:error, :restored_audit_verification_configuration_invalid}
    end
  end

  defp load_audit(repo) do
    with {:ok, snapshot} <- load_audit_snapshot(repo), do: {:ok, snapshot.events}
  end

  defp load_audit_snapshot(repo) do
    with {:ok, %{rows: [[anchor_hash, pruned_through]]}} <-
           SQL.query(
             repo,
             "SELECT anchor_hash, pruned_through_sequence FROM audit_chain_state WHERE id = 1",
             []
           ),
         {:ok, %{rows: rows}} <-
           SQL.query(repo, "SELECT sequence, payload FROM audit_events ORDER BY sequence", []),
         {:ok, events} <- decode_audit_rows(rows),
         :ok <- Chain.verify_from(anchor_hash, events) do
      {:ok,
       %{
         base_hash: anchor_hash,
         pruned_through_sequence: pruned_through,
         events: events,
         event_count: length(events),
         chain_head: audit_head(events, anchor_hash)
       }}
    else
      {:ok, %{rows: []}} -> {:error, :audit_chain_state_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_audit_rows(rows) do
    rows
    |> Enum.reduce_while({:ok, []}, fn [_sequence, payload], {:ok, acc} ->
      case Jason.decode(payload, keys: :atoms) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp audit_tail_hash(repo) do
    with {:ok, %{rows: rows}} <-
           SQL.query(
             repo,
             "SELECT chain_hash FROM audit_events ORDER BY sequence DESC LIMIT 1",
             []
           ) do
      case rows do
        [[hash]] -> {:ok, hash}
        [] -> audit_anchor_hash(repo)
      end
    end
  end

  defp audit_anchor_hash(repo) do
    case SQL.query(repo, "SELECT anchor_hash FROM audit_chain_state WHERE id = 1", []) do
      {:ok, %{rows: [[hash]]}} -> {:ok, hash}
      {:ok, %{rows: []}} -> {:error, :audit_chain_state_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  defp audit_head([], base_hash), do: base_hash
  defp audit_head(events, _base_hash), do: List.last(events).audit_chain_hash

  defp prune_expired(repo, now) do
    previous = Repo.get_dynamic_repo()
    Repo.put_dynamic_repo(repo)

    try do
      case Repo.transaction(fn ->
             records_removed = prune_records!(repo, now)
             audits_removed = prune_audit_events!(repo, now)
             records_removed + audits_removed
           end) do
        {:ok, count} -> {:ok, count}
        {:error, reason} -> {:error, reason}
      end
    after
      Repo.put_dynamic_repo(previous)
    end
  end

  defp prune_records!(repo, now) do
    case SQL.query(
           repo,
           "DELETE FROM records WHERE retention_class != 'permanent' AND expires_at IS NOT NULL AND expires_at <= ? AND (hold_until IS NULL OR hold_until <= ?)",
           [now, now]
         ) do
      {:ok, %{num_rows: count}} -> count
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp prune_audit_events!(repo, now) do
    case SQL.query(
           repo,
           "SELECT sequence, chain_hash FROM audit_events WHERE expires_at IS NOT NULL AND expires_at <= ? ORDER BY sequence DESC LIMIT 1",
           [now]
         ) do
      {:ok, %{rows: []}} ->
        0

      {:ok, %{rows: [[sequence, chain_hash]]}} ->
        with {:ok, %{num_rows: count}} <-
               SQL.query(repo, "DELETE FROM audit_events WHERE sequence <= ?", [sequence]),
             {:ok, _result} <-
               SQL.query(
                 repo,
                 "UPDATE audit_chain_state SET anchor_hash = ?, pruned_through_sequence = ?, updated_at = ? WHERE id = 1",
                 [chain_hash, sequence, now]
               ) do
          count
        else
          {:error, reason} -> Repo.rollback(reason)
        end

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp retention(opts, state) do
    class = Keyword.get(opts, :retention_class, :raw)

    if class not in [:raw, :security, :permanent],
      do: raise(ArgumentError, "invalid retention class")

    expires_at =
      case Keyword.get(opts, :expires_at) do
        nil when class == :permanent ->
          nil

        nil ->
          default_days =
            if(class == :raw, do: state.raw_retention_days, else: state.security_retention_days)

          days = Keyword.get(opts, :retention_days, default_days)
          DateTime.add(Keyword.get(opts, :now, DateTime.utc_now()), days * 86_400, :second)

        value ->
          value
      end

    {Atom.to_string(class), iso8601(expires_at), iso8601(Keyword.get(opts, :hold_until))}
  end

  defp encode(value), do: :erlang.term_to_binary(value, [:compressed])

  # The `:safe` option prevents unsafe external terms; callers validate the
  # returned record shape before use.
  # sobelow_skip ["Misc.BinToTerm"]
  defp decode(value) when is_binary(value) do
    {:ok, :erlang.binary_to_term(value, [:safe])}
  rescue
    _ -> {:error, :operations_record_invalid}
  end

  defp sql_ok({:ok, _}), do: :ok
  defp sql_ok({:error, reason}), do: {:error, reason}

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value) when is_binary(value), do: value

  defp parse_time(nil), do: nil
  defp parse_time(value), do: value |> DateTime.from_iso8601() |> elem(1)

  defp audit_occurred_at(%DateTime{} = value), do: value

  defp audit_occurred_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, parsed, _offset} -> parsed
      _other -> DateTime.utc_now()
    end
  end

  defp audit_occurred_at(_value), do: DateTime.utc_now()

  defp protect_files(path) do
    [path, path <> "-wal", path <> "-shm"]
    |> Enum.reduce_while(:ok, fn candidate, :ok ->
      case File.chmod(candidate, 0o600) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp require_regular_file(path) do
    if File.regular?(path), do: :ok, else: {:error, :backup_source_not_found}
  end

  defp require_available_destination(path, opts) do
    cond do
      not File.exists?(path) -> :ok
      Keyword.get(opts, :replace?, false) -> :ok
      true -> {:error, :restore_destination_exists}
    end
  end

  defp distinct_paths(path, path), do: {:error, :restore_source_is_destination}
  defp distinct_paths(_source, _destination), do: :ok

  defp install_restore(temporary, destination, opts) do
    if Keyword.get(opts, :replace?, false) do
      case File.rename(temporary, destination) do
        :ok ->
          :ok

        {:error, :eexist} ->
          with :ok <- File.rm(destination), do: File.rename(temporary, destination)

        {:error, reason} ->
          {:error, reason}
      end
    else
      case File.ln(temporary, destination) do
        :ok -> File.rm(temporary)
        {:error, :eexist} -> {:error, :restore_destination_exists}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp unique_suffix,
    do: :crypto.strong_rand_bytes(9) |> Base.url_encode64(padding: false)
end
