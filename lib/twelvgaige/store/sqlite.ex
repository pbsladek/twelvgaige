defmodule Twelvgaige.Store.SQLite do
  @moduledoc """
  SQLite-backed implementation of the store behaviour.

  The schema keeps queryable identities and statuses in relational columns while
  persisting snapshots, manifests, events, and journals as external-term blobs.
  That deliberately preserves the current recovery contract, including structs
  inside round manifests, while Phase 4 proves transactional durability.
  """

  use GenServer

  @behaviour Twelvgaige.Store

  alias Ecto.Adapters.SQL
  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.Redactor
  alias Twelvgaige.Round.ShotRun
  alias Twelvgaige.Security.FileMode
  alias Twelvgaige.Store.Retention
  alias Twelvgaige.Store.SQLite.Migrations.Initial
  alias Twelvgaige.Store.SQLite.Migrations.RoundQueryColumns
  alias Twelvgaige.Store.SQLite.Migrations.ShotRuns
  alias Twelvgaige.Store.SQLite.Repo

  @terminal_statuses MapSet.new([:complete, :failed, :halted, :cancelled])
  @max_event_wait_ms 30_000
  @retention_batch_size 32
  @default_sqlcipher_kdf_iter 256_000
  @external_term_modules [
    Calendar.ISO,
    DateTime,
    MapSet,
    Twelvgaige.Audit.Event,
    Twelvgaige.Error,
    Twelvgaige.LLM.Response,
    Twelvgaige.Loadout,
    Twelvgaige.Pattern.Compiled,
    Twelvgaige.Round.Event,
    Twelvgaige.Round.Manifest,
    Twelvgaige.Round.ShotRun,
    Twelvgaige.Round.Snapshot,
    Twelvgaige.Shell.Agent,
    Twelvgaige.Shell.Agent.Choke,
    Twelvgaige.Shell.Agent.Memory,
    Twelvgaige.Shell.Agent.Tools,
    Twelvgaige.Shell.Workflow,
    Twelvgaige.Shell.Workflow.Choke,
    Twelvgaige.Shell.Workflow.Policy,
    Twelvgaige.Shell.Workflow.Retry,
    Twelvgaige.Shell.Workflow.Shot,
    Twelvgaige.Shot.Attempt,
    Twelvgaige.Shot.AttemptJournal,
    Twelvgaige.Shot.State,
    Twelvgaige.Tool.Call,
    Twelvgaige.Tool.IntentJournal
  ]
  @external_term_atoms [
    :actor,
    :agent,
    :attempt,
    :audit,
    :awaiting_reconciliation,
    :awaiting_safety,
    :backoff,
    :base_delay_ms,
    :block_round,
    :calendar,
    :cancelled,
    :cancel_round,
    :choke,
    :complete,
    :completed,
    :completed_at,
    :condition,
    :created_at,
    :day,
    :dependency,
    :depends_on,
    :description,
    :effective_resource_profile,
    :error,
    :estimated,
    :event_type,
    :fail_round,
    false,
    :fixed,
    :halt_round,
    :history,
    :hour,
    :id,
    :idempotency_metadata,
    :input,
    :input_schema,
    :input_tokens,
    :kind,
    :failed,
    :halted,
    :laptop,
    :max_attempts,
    :max_delay_ms,
    :max_iterations,
    :microsecond,
    :minute,
    :month,
    :name,
    :next_retry_at,
    :occurred_at,
    :ok,
    :on_cancel,
    :on_condition_error,
    :on_safety_reject,
    :on_shot_failure,
    :on_store_error,
    :output,
    :output_schema,
    :output_tokens,
    :path,
    :payload,
    :pending,
    :policy,
    :prompt,
    :queue_timeout_ms,
    :queued,
    :read_only,
    :requires_tool_intents,
    :resource_profile,
    :result,
    :retry,
    :retryable_errors,
    :round_completed,
    :round_id,
    :round_state_transition,
    :round_version,
    :retrying,
    :running,
    :safety_level,
    :safety_scope,
    :schema_version,
    :second,
    :seq,
    :shell_id,
    :shell_version,
    :shot_attempt_finished,
    :shot_attempt_started,
    :shot_id,
    :shots,
    :skipped,
    :slug,
    :source,
    :started_at,
    :status,
    :std_offset,
    :store_status,
    :summary,
    :time_zone,
    :timeout_ms,
    :tool_call_count,
    :token_budget,
    :tool_safety,
    :tools,
    :total_tokens,
    :transition_id,
    true,
    :type,
    :usage,
    :utc_offset,
    :version,
    :workflow,
    :workflow_hash,
    :year,
    :zone_abbr
  ]

  defstruct [
    :path,
    :repo_pid,
    :max_retained_bytes,
    :sensitive_retention,
    encrypted?: false,
    evicted_rounds: 0,
    event_watchers: %{},
    event_watcher_refs: %{}
  ]

  @type start_option :: GenServer.option() | {:path, Path.t()}

  @spec start_link([start_option()]) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    path = opts |> Keyword.fetch!(:path) |> Path.expand()

    with :ok <- preload_external_term_atoms(),
         :ok <- prepare_encrypted_store(path, opts),
         :ok <- FileMode.ensure_private_parent_dir(path),
         {:ok, repo_pid} <- start_repo(path, opts),
         :ok <- configure_encrypted_connection(opts),
         :ok <- configure_connection(opts),
         :ok <- ensure_schema(),
         :ok <- protect_sqlite_files(path) do
      retention = Retention.configure(%{}, opts)

      state = %__MODULE__{
        path: path,
        repo_pid: repo_pid,
        encrypted?: encrypted?(opts),
        max_retained_bytes: Map.get(retention, :max_retained_bytes),
        sensitive_retention: Map.get(retention, :sensitive_retention)
      }

      {:ok, enforce_retention(state)}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %__MODULE__{repo_pid: repo_pid}) when is_pid(repo_pid) do
    if Process.alive?(repo_pid) do
      Supervisor.stop(repo_pid)
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp preload_external_term_atoms do
    Enum.each(@external_term_modules, &Code.ensure_loaded/1)
    Enum.each(@external_term_atoms, &Atom.to_string/1)
    :ok
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
    round_id = fetch_id!(snapshot, :round)

    reply =
      transaction(fn ->
        case round_exists?(round_id) do
          {:ok, true} ->
            {:error, :round_already_exists}

          {:ok, false} ->
            with :ok <- insert_round(snapshot),
                 :ok <- insert_manifest(round_id, manifest),
                 :ok <- replace_shot_runs(round_id, snapshot),
                 :ok <- insert_audit_events(round_id, audit_events) do
              :ok
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    {:reply, reply, maybe_enforce_retention(state, reply)}
  end

  def handle_call({:record_attempt_started, attempt, audit_events}, _from, state) do
    attempt = sanitize_journal(attempt, state)

    reply =
      transaction(fn ->
        key = attempt_key(attempt)

        case fetch_attempt_journal(key) do
          {:ok, ^attempt} ->
            with :ok <- insert_audit_events(fetch_id!(attempt, :round), audit_events) do
              :already_recorded
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          {:ok, _conflict} ->
            {:error, :attempt_journal_conflict}

          {:error, :not_found} ->
            with :ok <- insert_attempt_journal(attempt),
                 :ok <- insert_audit_events(fetch_id!(attempt, :round), audit_events) do
              :ok
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    {:reply, reply, maybe_enforce_retention(state, reply)}
  end

  def handle_call({:record_attempt_finished, attempt, audit_events}, _from, state) do
    attempt = sanitize_journal(attempt, state)

    reply =
      transaction(fn ->
        key = attempt_key(attempt)

        case fetch_attempt_journal(key) do
          {:ok, existing} ->
            case merge_journal_finish(existing, attempt) do
              {:ok, merged} ->
                with :ok <- update_attempt_journal(key, merged),
                     :ok <- insert_audit_events(fetch_id!(attempt, :round), audit_events) do
                  :ok
                else
                  {:error, reason} -> Repo.rollback(reason)
                end

              :already_recorded ->
                with :ok <- insert_audit_events(fetch_id!(attempt, :round), audit_events) do
                  :already_recorded
                else
                  {:error, reason} -> Repo.rollback(reason)
                end

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :not_found} ->
            {:error, :journal_missing}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    {:reply, reply, maybe_enforce_retention(state, reply)}
  end

  def handle_call({:record_tool_intent, intent, audit_events}, _from, state) do
    intent = sanitize_journal(intent, state)

    reply =
      transaction(fn ->
        key = tool_intent_key(intent)

        case fetch_tool_journal(key) do
          {:ok, ^intent} ->
            with :ok <- insert_audit_events(fetch_id!(intent, :round), audit_events) do
              :already_recorded
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          {:ok, _conflict} ->
            {:error, :tool_intent_conflict}

          {:error, :not_found} ->
            with :ok <- insert_tool_journal(intent),
                 :ok <- insert_audit_events(fetch_id!(intent, :round), audit_events) do
              :ok
            else
              {:error, reason} -> Repo.rollback(reason)
            end

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    {:reply, reply, maybe_enforce_retention(state, reply)}
  end

  def handle_call({:record_tool_result, result, audit_events}, _from, state) do
    result = sanitize_journal(result, state)

    reply =
      transaction(fn ->
        key = tool_intent_key(result)

        case fetch_tool_journal(key) do
          {:ok, existing} ->
            case merge_journal_finish(existing, result) do
              {:ok, merged} ->
                with :ok <- update_tool_journal(key, merged),
                     :ok <- insert_audit_events(fetch_id!(result, :round), audit_events) do
                  :ok
                else
                  {:error, reason} -> Repo.rollback(reason)
                end

              :already_recorded ->
                with :ok <- insert_audit_events(fetch_id!(result, :round), audit_events) do
                  :already_recorded
                else
                  {:error, reason} -> Repo.rollback(reason)
                end

              {:error, reason} ->
                {:error, reason}
            end

          {:error, :not_found} ->
            {:error, :journal_missing}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    {:reply, reply, maybe_enforce_retention(state, reply)}
  end

  def handle_call({:list_attempt_journals, round_id}, _from, state) do
    {:reply, list_attempt_journals_query(round_id), state}
  end

  def handle_call({:list_tool_journals, round_id}, _from, state) do
    {:reply, list_tool_journals_query(round_id), state}
  end

  def handle_call({:list_audit_events, round_id, opts}, _from, state) do
    {:reply, list_audit_events_query(round_id, opts), state}
  end

  def handle_call(
        {:commit_transition, round_id, expected_version, transition_id, next_snapshot, events,
         audit_events},
        _from,
        state
      ) do
    reply =
      transaction(fn ->
        cond do
          transition_committed?(round_id, transition_id) ->
            :already_committed

          not round_exists!(round_id) ->
            {:error, :not_found}

          current_version(round_id) != expected_version ->
            {:error, :version_conflict}

          true ->
            first_seq = next_event_seq(round_id)
            {events, _next_seq} = assign_event_sequences(events, first_seq)
            next_snapshot = put_value(next_snapshot, :version, expected_version + 1)

            with :ok <- update_round(round_id, next_snapshot),
                 :ok <- replace_shot_runs(round_id, next_snapshot),
                 :ok <- insert_round_events(round_id, events),
                 :ok <- insert_audit_events(round_id, audit_events),
                 :ok <- insert_transition(round_id, transition_id) do
              :ok
            else
              {:error, reason} -> Repo.rollback(reason)
            end
        end
      end)

    state =
      if reply == :ok do
        state
        |> notify_event_watchers(round_id)
        |> enforce_retention()
      else
        state
      end

    {:reply, reply, state}
  end

  def handle_call({:get_round, round_id}, _from, state) do
    {:reply, get_round_query(round_id), state}
  end

  def handle_call({:get_manifest, round_id}, _from, state) do
    {:reply, get_manifest_query(round_id), state}
  end

  def handle_call({:list_rounds, opts}, _from, state) do
    {:reply, list_rounds_query(opts), state}
  end

  def handle_call({:list_shot_runs, round_id}, _from, state) do
    {:reply, list_shot_runs_query(round_id), state}
  end

  def handle_call({:list_round_events, round_id, opts}, _from, state) do
    reply =
      if round_exists!(round_id) do
        {:ok, events_after(round_id, opts)}
      else
        {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call({:await_round_events, round_id, opts}, from, state) do
    cond do
      not round_exists!(round_id) ->
        {:reply, {:error, :not_found}, state}

      events = events_after(round_id, opts) ->
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
    {:reply, list_incomplete_rounds_query(), state}
  end

  def handle_call(:stats, _from, state) do
    {:reply, stats_query(state), state}
  end

  def handle_call({:backup, destination, opts}, _from, state) do
    {:reply, backup_to(state, destination, opts), state}
  end

  @impl true
  def handle_info({:event_wait_timeout, watcher_ref}, state) do
    case Map.fetch(state.event_watchers, watcher_ref) do
      {:ok, watcher} ->
        events = events_after(watcher.round_id, watcher.opts)
        GenServer.reply(watcher.from, {:ok, events})
        {:noreply, delete_event_watcher(state, watcher_ref, watcher)}

      :error ->
        {:noreply, state}
    end
  end

  def handle_info({:EXIT, repo_pid, reason}, %__MODULE__{repo_pid: repo_pid} = state) do
    {:stop, {:repo_exit, reason}, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec backup(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def backup(destination, opts \\ []) when is_binary(destination) do
    server = Keyword.get(opts, :server, __MODULE__)
    timeout = Keyword.get(opts, :timeout, 30_000)
    GenServer.call(server, {:backup, destination, opts}, timeout)
  end

  @spec restore_backup(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore_backup(source, destination, opts \\ [])
      when is_binary(source) and is_binary(destination) do
    source = Path.expand(source)
    destination = Path.expand(destination)

    with :ok <- ensure_restore_source(source),
         :ok <- ensure_restore_destination(destination, opts),
         :ok <- FileMode.ensure_private_parent_dir(destination),
         {:ok, bytes} <- File.copy(source, destination),
         :ok <- FileMode.chmod_if_supported(destination, 0o600) do
      {:ok,
       %{
         "status" => "ok",
         "source" => source,
         "destination" => destination,
         "bytes" => bytes,
         "replaced" => Keyword.get(opts, :replace?, false) == true
       }}
    else
      {:error, _reason} = error -> error
    end
  end

  defp start_repo(path, opts) do
    repo_opts =
      [
        database: path,
        pool_size: Keyword.get(opts, :pool_size, 1),
        busy_timeout: Keyword.get(opts, :busy_timeout, 5_000),
        journal_mode: Keyword.get(opts, :journal_mode, :wal),
        log: Keyword.get(opts, :log, false)
      ]
      |> maybe_put_sqlcipher_key(opts)

    Repo.start_link(repo_opts)
  end

  defp stop_repo(pid) when is_pid(pid), do: Supervisor.stop(pid)

  defp prepare_encrypted_store(_path, opts) do
    if encrypted?(opts) do
      with {:ok, _key} <- sqlcipher_key(opts),
           {:ok, repo_pid} <- start_repo(":memory:", opts) do
        try do
          configure_encrypted_connection(opts)
        after
          stop_repo(repo_pid)
        end
      end
    else
      :ok
    end
  end

  defp configure_encrypted_connection(opts) do
    if encrypted?(opts) do
      with {:ok, _key} <- sqlcipher_key(opts),
           {:ok, _version} <- sqlcipher_version(),
           :ok <- configure_sqlcipher_pragmas(opts) do
        :ok
      end
    else
      :ok
    end
  end

  defp sqlcipher_version do
    case query("PRAGMA cipher_version", []) do
      {:ok, %{rows: [[version] | _]}} when is_binary(version) and version != "" ->
        {:ok, version}

      {:ok, _result} ->
        {:error, :sqlcipher_unavailable}

      {:error, _reason} = error ->
        error
    end
  end

  defp configure_sqlcipher_pragmas(opts) do
    kdf_iter = opts |> Keyword.get(:cipher_kdf_iter, @default_sqlcipher_kdf_iter) |> max(1)

    with :ok <- query_ok("PRAGMA kdf_iter = #{kdf_iter}", []),
         :ok <- query_ok("PRAGMA cipher_memory_security = ON", []) do
      :ok
    else
      {:error, _reason} = error -> error
    end
  end

  defp configure_connection(opts) do
    busy_timeout = opts |> Keyword.get(:busy_timeout, 5_000) |> normalize_positive_integer(5_000)
    journal_mode = opts |> Keyword.get(:journal_mode, :wal) |> normalize_journal_mode()

    with :ok <- query_ok("PRAGMA foreign_keys = ON", []),
         :ok <- query_ok("PRAGMA busy_timeout = #{busy_timeout}", []) do
      query_ok("PRAGMA journal_mode = #{journal_mode}", [])
    end
  end

  defp protect_sqlite_files(path) do
    FileMode.ensure_private_existing_files([path, path <> "-wal", path <> "-shm"])
  end

  defp backup_to(%__MODULE__{} = state, destination, opts) when is_binary(destination) do
    destination = Path.expand(destination)

    with {:ok, policy} <- backup_policy(state, opts),
         :ok <- ensure_backup_destination(destination),
         :ok <- FileMode.ensure_private_parent_dir(destination),
         :ok <- vacuum_into(destination),
         :ok <- FileMode.chmod_if_supported(destination, 0o600) do
      {:ok,
       %{
         "status" => "ok",
         "source" => state.path,
         "destination" => destination,
         "mode" => Atom.to_string(policy.mode),
         "encrypted" => state.encrypted?,
         "plaintext" => policy.plaintext?,
         "warnings" => policy.warnings
       }}
    else
      {:error, _reason} = error ->
        error
    end
  end

  defp backup_to(%__MODULE__{}, _destination, _opts), do: {:error, :invalid_backup_destination}

  defp backup_policy(%__MODULE__{encrypted?: encrypted?}, opts) do
    mode = Keyword.get(opts, :mode, if(encrypted?, do: :encrypted, else: :plaintext))

    Twelvgaige.Crypto.BackupPolicy.plan(
      mode: mode,
      allow_plaintext_export?: Keyword.get(opts, :allow_plaintext_export?, false)
    )
    |> case do
      {:ok, %{mode: :redacted}} -> {:error, :redacted_sqlite_backup_not_supported}
      other -> other
    end
  end

  defp ensure_backup_destination(path) do
    if File.exists?(path) do
      {:error, :backup_destination_exists}
    else
      :ok
    end
  end

  defp ensure_restore_source(path) do
    if File.regular?(path) do
      :ok
    else
      {:error, :backup_source_not_found}
    end
  end

  defp ensure_restore_destination(path, opts) do
    if File.exists?(path) do
      if Keyword.get(opts, :replace?, false) == true do
        File.rm(path)
      else
        {:error, :restore_destination_exists}
      end
    else
      :ok
    end
  end

  defp vacuum_into(destination) do
    query_ok("VACUUM INTO #{sql_string_literal(destination)}", [])
  end

  defp maybe_put_sqlcipher_key(repo_opts, opts) do
    if encrypted?(opts) do
      case sqlcipher_key(opts) do
        {:ok, key} -> Keyword.put(repo_opts, :key, sql_string_literal(key))
        {:error, _reason} -> repo_opts
      end
    else
      repo_opts
    end
  end

  defp sqlcipher_key(opts) do
    key = Keyword.get(opts, :key) || key_from_env(Keyword.get(opts, :key_env))

    case key do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :sqlcipher_key_required}
    end
  end

  defp key_from_env(nil), do: nil
  defp key_from_env(""), do: nil

  defp key_from_env(env) when is_binary(env) do
    case System.get_env(env) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

  defp encrypted?(opts), do: Keyword.get(opts, :encrypted?, false) == true

  defp sql_string_literal(value) do
    escaped = String.replace(value, "'", "''")
    "'#{escaped}'"
  end

  defp ensure_schema do
    with :ok <- migrate(Initial),
         :ok <- migrate(ShotRuns),
         :ok <- migrate(RoundQueryColumns),
         :ok <- backfill_round_query_columns(),
         :ok <- backfill_shot_runs() do
      :ok
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp migrate(migration) do
    case Ecto.Migrator.up(Repo, migration.version(), migration,
           log: false,
           log_migrations_sql: false,
           log_migrator_sql: false
         ) do
      status when status in [:ok, :already_up] -> :ok
    end
  end

  defp backfill_shot_runs do
    case query("SELECT id, snapshot FROM rounds ORDER BY id", []) do
      {:ok, %{rows: rows}} ->
        Enum.reduce_while(rows, :ok, fn [round_id, snapshot], :ok ->
          case replace_shot_runs(round_id, decode(snapshot)) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      {:error, _reason} = error ->
        error
    end
  end

  defp backfill_round_query_columns do
    case query("SELECT id, snapshot FROM rounds ORDER BY id", []) do
      {:ok, %{rows: rows}} ->
        Enum.reduce_while(rows, :ok, fn [round_id, snapshot], :ok ->
          snapshot = decode(snapshot)

          case update_round_query_columns(round_id, snapshot) do
            :ok -> {:cont, :ok}
            {:error, _reason} = error -> {:halt, error}
          end
        end)

      {:error, _reason} = error ->
        error
    end
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, reply} -> reply
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_round(snapshot) do
    now = now_string()
    round_id = fetch_id!(snapshot, :round)
    columns = round_query_columns(snapshot)

    query_ok(
      """
      INSERT INTO rounds
        (id, status, version, shell_id, shell_version, started_at, completed_at,
         error_class, error_reason, snapshot, inserted_at, updated_at)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      [
        round_id,
        normalize_status(value(snapshot, :status)),
        snapshot_version(snapshot),
        columns.shell_id,
        columns.shell_version,
        columns.started_at,
        columns.completed_at,
        columns.error_class,
        columns.error_reason,
        encode(snapshot),
        now,
        now
      ]
    )
  end

  defp insert_manifest(round_id, manifest) do
    query_ok("INSERT INTO manifests (round_id, manifest) VALUES (?, ?)", [
      round_id,
      encode(manifest)
    ])
  end

  defp update_round(round_id, snapshot) do
    columns = round_query_columns(snapshot)

    query_ok(
      """
      UPDATE rounds
      SET status = ?, version = ?, shell_id = ?, shell_version = ?, started_at = ?,
          completed_at = ?, error_class = ?, error_reason = ?, snapshot = ?, updated_at = ?
      WHERE id = ?
      """,
      [
        normalize_status(value(snapshot, :status)),
        snapshot_version(snapshot),
        columns.shell_id,
        columns.shell_version,
        columns.started_at,
        columns.completed_at,
        columns.error_class,
        columns.error_reason,
        encode(snapshot),
        now_string(),
        round_id
      ]
    )
  end

  defp update_round_query_columns(round_id, snapshot) do
    columns = round_query_columns(snapshot)

    query_ok(
      """
      UPDATE rounds
      SET shell_id = ?, shell_version = ?, started_at = ?, completed_at = ?,
          error_class = ?, error_reason = ?
      WHERE id = ?
      """,
      [
        columns.shell_id,
        columns.shell_version,
        columns.started_at,
        columns.completed_at,
        columns.error_class,
        columns.error_reason,
        round_id
      ]
    )
  end

  defp replace_shot_runs(round_id, snapshot) do
    with :ok <- query_ok("DELETE FROM shot_runs WHERE round_id = ?", [round_id]) do
      insert_shot_runs(round_id, ShotRun.from_snapshot(snapshot))
    end
  end

  defp insert_shot_runs(_round_id, []), do: :ok

  defp insert_shot_runs(round_id, shot_runs) do
    Enum.reduce_while(shot_runs, :ok, fn shot_run, :ok ->
      case query_ok(
             """
             INSERT INTO shot_runs
               (round_id, shot_id, kind, status, attempt, started_at, completed_at,
                next_retry_at, output, error)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
             """,
             [
               round_id,
               value(shot_run, :shot_id),
               value(shot_run, :kind),
               value(shot_run, :status),
               value(shot_run, :attempt) || 0,
               value(shot_run, :started_at),
               value(shot_run, :completed_at),
               value(shot_run, :next_retry_at),
               encode_nullable(value(shot_run, :output)),
               encode_nullable(value(shot_run, :error))
             ]
           ) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp insert_transition(round_id, transition_id) do
    query_ok(
      "INSERT INTO committed_transitions (round_id, transition_id) VALUES (?, ?)",
      [round_id, transition_id]
    )
  end

  defp insert_round_events(_round_id, []), do: :ok

  defp insert_round_events(round_id, events) do
    Enum.reduce_while(events, :ok, fn event, :ok ->
      case query_ok("INSERT INTO round_events (round_id, seq, event) VALUES (?, ?, ?)", [
             round_id,
             value(event, :seq),
             encode(event)
           ]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp insert_audit_events(_round_id, []), do: :ok

  defp insert_audit_events(round_id, audit_events) do
    audit_events
    |> AuditEvent.sanitize_many()
    |> Enum.reduce_while(:ok, fn event, :ok ->
      case query_ok("INSERT INTO audit_events (round_id, event) VALUES (?, ?)", [
             round_id,
             encode(event)
           ]) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp sanitize_journal(%{} = journal, %{sensitive_retention: :summary}) do
    Redactor.summarize_sensitive_payloads(journal)
  end

  defp sanitize_journal(%{} = journal, _state), do: Redactor.redact_json(journal)

  defp insert_attempt_journal(attempt) do
    {round_id, shot_id, attempt_number} = attempt_key(attempt)

    query_ok(
      """
      INSERT INTO attempt_journals (round_id, shot_id, attempt, status, journal)
      VALUES (?, ?, ?, ?, ?)
      """,
      [
        round_id,
        shot_id,
        attempt_number,
        normalize_status(value(attempt, :status)),
        encode(attempt)
      ]
    )
  end

  defp update_attempt_journal({round_id, shot_id, attempt_number}, journal) do
    query_ok(
      """
      UPDATE attempt_journals SET status = ?, journal = ?
      WHERE round_id = ? AND shot_id = ? AND attempt = ?
      """,
      [
        normalize_status(value(journal, :status)),
        encode(journal),
        round_id,
        shot_id,
        attempt_number
      ]
    )
  end

  defp insert_tool_journal(journal) do
    {round_id, shot_id, attempt_number, tool_key} = tool_intent_key(journal)

    query_ok(
      """
      INSERT INTO tool_journals (round_id, shot_id, attempt, tool_key, status, journal)
      VALUES (?, ?, ?, ?, ?, ?)
      """,
      [
        round_id,
        shot_id,
        attempt_number,
        tool_key,
        normalize_status(value(journal, :status)),
        encode(journal)
      ]
    )
  end

  defp update_tool_journal({round_id, shot_id, attempt_number, tool_key}, journal) do
    query_ok(
      """
      UPDATE tool_journals SET status = ?, journal = ?
      WHERE round_id = ? AND shot_id = ? AND attempt = ? AND tool_key = ?
      """,
      [
        normalize_status(value(journal, :status)),
        encode(journal),
        round_id,
        shot_id,
        attempt_number,
        tool_key
      ]
    )
  end

  defp get_round_query(round_id) do
    case query("SELECT snapshot FROM rounds WHERE id = ?", [round_id]) do
      {:ok, %{rows: [[snapshot]]}} -> {:ok, decode(snapshot)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp get_manifest_query(round_id) do
    case query("SELECT manifest FROM manifests WHERE round_id = ?", [round_id]) do
      {:ok, %{rows: [[manifest]]}} -> {:ok, decode(manifest)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp list_rounds_query(opts) do
    {where_sql, params} = round_list_where(opts)
    order_sql = round_list_order(opts)
    limit_sql = round_list_limit(opts)

    case query("SELECT snapshot FROM rounds #{where_sql} #{order_sql} #{limit_sql}", params) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [snapshot] -> decode(snapshot) end)}
      {:error, _reason} = error -> error
    end
  end

  defp round_list_where(opts) do
    []
    |> maybe_where("status = ?", maybe_status(opts))
    |> maybe_where("shell_id = ?", Keyword.get(opts, :shell_id))
    |> maybe_where("shell_version = ?", Keyword.get(opts, :shell_version))
    |> maybe_where("started_at >= ?", Keyword.get(opts, :started_after))
    |> maybe_where("started_at <= ?", Keyword.get(opts, :started_before))
    |> maybe_where("completed_at >= ?", Keyword.get(opts, :completed_after))
    |> maybe_where("completed_at <= ?", Keyword.get(opts, :completed_before))
    |> maybe_where("error_reason = ?", Keyword.get(opts, :error_reason))
    |> case do
      [] ->
        {"", []}

      clauses ->
        {clauses, params} = Enum.unzip(Enum.reverse(clauses))
        {"WHERE " <> Enum.join(clauses, " AND "), params}
    end
  end

  defp maybe_where(clauses, _sql, nil), do: clauses
  defp maybe_where(clauses, _sql, ""), do: clauses
  defp maybe_where(clauses, sql, value), do: [{sql, query_value(value)} | clauses]

  defp maybe_status(opts) do
    case Keyword.get(opts, :status) do
      nil -> nil
      status -> normalize_status(status)
    end
  end

  defp round_list_order(opts) do
    case Keyword.get(opts, :order_by, :id) do
      :started_at -> "ORDER BY started_at, id"
      "started_at" -> "ORDER BY started_at, id"
      :completed_at -> "ORDER BY completed_at, id"
      "completed_at" -> "ORDER BY completed_at, id"
      :updated_at -> "ORDER BY updated_at, id"
      "updated_at" -> "ORDER BY updated_at, id"
      :inserted_at -> "ORDER BY inserted_at, id"
      "inserted_at" -> "ORDER BY inserted_at, id"
      _other -> "ORDER BY id"
    end
  end

  defp round_list_limit(opts) do
    case normalize_positive_integer(Keyword.get(opts, :limit), nil) do
      nil -> ""
      limit -> "LIMIT #{min(limit, 1_000)}"
    end
  end

  defp list_shot_runs_query(round_id) do
    case query(
           """
           SELECT shot_id, kind, status, attempt, started_at, completed_at, next_retry_at, output, error
           FROM shot_runs
           WHERE round_id = ?
           ORDER BY shot_id
           """,
           [round_id]
         ) do
      {:ok, %{rows: []}} ->
        case round_exists?(round_id) do
          {:ok, true} -> {:ok, []}
          {:ok, false} -> {:error, :not_found}
          {:error, _reason} = error -> error
        end

      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &shot_run_row(round_id, &1))}

      {:error, _reason} = error ->
        error
    end
  end

  defp shot_run_row(round_id, [
         shot_id,
         kind,
         status,
         attempt,
         started_at,
         completed_at,
         next_retry_at,
         output,
         error
       ]) do
    %{
      round_id: round_id,
      shot_id: shot_id,
      kind: kind,
      status: status,
      attempt: attempt,
      started_at: started_at,
      completed_at: completed_at,
      next_retry_at: next_retry_at,
      output: decode_nullable(output),
      error: decode_nullable(error)
    }
  end

  defp list_incomplete_rounds_query do
    placeholders = Enum.map_join(@terminal_statuses, ", ", fn _status -> "?" end)

    case query(
           "SELECT snapshot FROM rounds WHERE status NOT IN (#{placeholders}) ORDER BY id",
           Enum.map(@terminal_statuses, &normalize_status/1)
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [snapshot] -> decode(snapshot) end)}
      {:error, _reason} = error -> error
    end
  end

  defp stats_query(%__MODULE__{} = state) do
    with {:ok, rounds} <- count_query("SELECT COUNT(*) FROM rounds", []),
         {:ok, terminal_rounds} <- terminal_round_count_query(),
         {:ok, incomplete_rounds} <- incomplete_round_count_query(),
         {:ok, round_events} <- count_query("SELECT COUNT(*) FROM round_events", []),
         {:ok, audit_events} <- count_query("SELECT COUNT(*) FROM audit_events", []),
         {:ok, attempt_journals} <- count_query("SELECT COUNT(*) FROM attempt_journals", []),
         {:ok, tool_journals} <- count_query("SELECT COUNT(*) FROM tool_journals", []),
         {:ok, retained_bytes} <- retained_data_bytes_query() do
      retained_bytes_limit = state.max_retained_bytes

      {:ok,
       %{
         rounds: rounds,
         terminal_rounds: terminal_rounds,
         incomplete_rounds: incomplete_rounds,
         round_events: round_events,
         audit_events: audit_events,
         attempt_journals: attempt_journals,
         tool_journals: tool_journals,
         retained_bytes: retained_bytes,
         retained_bytes_limit: retained_bytes_limit,
         retained_bytes_over_limit:
           retained_bytes_over_limit?(retained_bytes, retained_bytes_limit),
         evicted_rounds: state.evicted_rounds
       }}
    end
  end

  defp terminal_round_count_query do
    placeholders = Enum.map_join(@terminal_statuses, ", ", fn _status -> "?" end)

    count_query(
      "SELECT COUNT(*) FROM rounds WHERE status IN (#{placeholders})",
      Enum.map(@terminal_statuses, &normalize_status/1)
    )
  end

  defp incomplete_round_count_query do
    placeholders = Enum.map_join(@terminal_statuses, ", ", fn _status -> "?" end)

    count_query(
      "SELECT COUNT(*) FROM rounds WHERE status NOT IN (#{placeholders})",
      Enum.map(@terminal_statuses, &normalize_status/1)
    )
  end

  defp count_query(sql, params) do
    case query(sql, params) do
      {:ok, %{rows: [[count]]}} when is_integer(count) -> {:ok, count}
      {:ok, %{rows: [[count]]}} -> {:ok, normalize_count(count)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_count(count) when is_integer(count), do: count
  defp normalize_count(count) when is_binary(count), do: String.to_integer(count)
  defp normalize_count(nil), do: 0
  defp normalize_count(count), do: trunc(count)

  defp maybe_enforce_retention(state, reply) when reply in [:ok, :already_recorded] do
    enforce_retention(state)
  end

  defp maybe_enforce_retention(state, _reply), do: state

  defp enforce_retention(%__MODULE__{max_retained_bytes: max_retained_bytes} = state)
       when is_integer(max_retained_bytes) and max_retained_bytes > 0 do
    case retained_data_bytes_query() do
      {:ok, retained_bytes} when retained_bytes > max_retained_bytes ->
        evict_terminal_rounds(state, max_retained_bytes)

      {:ok, _retained_bytes} ->
        state

      {:error, _reason} ->
        state
    end
  end

  defp enforce_retention(state), do: state

  defp evict_terminal_rounds(state, max_retained_bytes) do
    case terminal_round_ids_query() do
      {:ok, round_ids} ->
        evictable_round_ids =
          if length(round_ids) > 1 do
            round_ids
            |> Enum.drop(-1)
            |> Enum.take(@retention_batch_size)
          else
            []
          end

        Enum.reduce_while(evictable_round_ids, state, fn round_id, acc ->
          case retained_data_bytes_query() do
            {:ok, retained_bytes} when retained_bytes <= max_retained_bytes ->
              {:halt, acc}

            {:ok, _retained_bytes} ->
              case delete_round_query(round_id) do
                :ok -> {:cont, %{acc | evicted_rounds: acc.evicted_rounds + 1}}
                {:error, _reason} -> {:halt, acc}
              end

            {:error, _reason} ->
              {:halt, acc}
          end
        end)

      {:error, _reason} ->
        state
    end
  end

  defp retained_data_bytes_query do
    case query(
           """
           SELECT
             COALESCE((SELECT SUM(LENGTH(snapshot)) FROM rounds), 0) +
             COALESCE((SELECT SUM(LENGTH(manifest)) FROM manifests), 0) +
             COALESCE((SELECT SUM(LENGTH(event)) FROM round_events), 0) +
             COALESCE((SELECT SUM(LENGTH(event)) FROM audit_events), 0) +
             COALESCE((SELECT SUM(LENGTH(journal)) FROM attempt_journals), 0) +
             COALESCE((SELECT SUM(LENGTH(journal)) FROM tool_journals), 0) +
             COALESCE((SELECT SUM(LENGTH(output)) FROM shot_runs WHERE output IS NOT NULL), 0) +
             COALESCE((SELECT SUM(LENGTH(error)) FROM shot_runs WHERE error IS NOT NULL), 0)
           """,
           []
         ) do
      {:ok, %{rows: [[bytes]]}} -> {:ok, normalize_count(bytes)}
      {:error, _reason} = error -> error
    end
  end

  defp terminal_round_ids_query do
    placeholders = Enum.map_join(@terminal_statuses, ", ", fn _status -> "?" end)

    case query(
           """
           SELECT id FROM rounds
           WHERE status IN (#{placeholders})
           ORDER BY COALESCE(completed_at, started_at, updated_at), id
           """,
           Enum.map(@terminal_statuses, &normalize_status/1)
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [round_id] -> round_id end)}
      {:error, _reason} = error -> error
    end
  end

  defp delete_round_query(round_id) do
    transaction(fn ->
      with :ok <- query_ok("DELETE FROM audit_events WHERE round_id = ?", [round_id]),
           :ok <- query_ok("DELETE FROM attempt_journals WHERE round_id = ?", [round_id]),
           :ok <- query_ok("DELETE FROM tool_journals WHERE round_id = ?", [round_id]),
           :ok <- query_ok("DELETE FROM shot_runs WHERE round_id = ?", [round_id]),
           :ok <- query_ok("DELETE FROM round_events WHERE round_id = ?", [round_id]),
           :ok <- query_ok("DELETE FROM committed_transitions WHERE round_id = ?", [round_id]),
           :ok <- query_ok("DELETE FROM manifests WHERE round_id = ?", [round_id]),
           :ok <- query_ok("DELETE FROM rounds WHERE id = ?", [round_id]) do
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp retained_bytes_over_limit?(_retained_bytes, nil), do: false

  defp retained_bytes_over_limit?(retained_bytes, retained_bytes_limit)
       when is_integer(retained_bytes_limit) do
    retained_bytes > retained_bytes_limit
  end

  defp retained_bytes_over_limit?(_retained_bytes, _retained_bytes_limit), do: false

  defp list_attempt_journals_query(round_id) do
    case query(
           """
           SELECT journal FROM attempt_journals
           WHERE round_id = ?
           ORDER BY shot_id, attempt
           """,
           [round_id]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [journal] -> decode(journal) end)}
      {:error, _reason} = error -> error
    end
  end

  defp list_tool_journals_query(round_id) do
    case query(
           """
           SELECT journal FROM tool_journals
           WHERE round_id = ?
           ORDER BY shot_id, attempt, tool_key
           """,
           [round_id]
         ) do
      {:ok, %{rows: rows}} -> {:ok, Enum.map(rows, fn [journal] -> decode(journal) end)}
      {:error, _reason} = error -> error
    end
  end

  defp list_audit_events_query(round_id, opts) do
    case query(
           """
           SELECT event FROM audit_events
           WHERE round_id = ?
           ORDER BY id
           """,
           [round_id]
         ) do
      {:ok, %{rows: []}} ->
        case round_exists?(round_id) do
          {:ok, true} -> {:ok, []}
          {:ok, false} -> {:error, :not_found}
          {:error, _reason} = error -> error
        end

      {:ok, %{rows: rows}} ->
        events =
          rows
          |> Enum.map(fn [event] -> decode(event) end)
          |> audit_events_after(opts)

        {:ok, events}

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_attempt_journal({round_id, shot_id, attempt}) do
    case query(
           """
           SELECT journal FROM attempt_journals
           WHERE round_id = ? AND shot_id = ? AND attempt = ?
           """,
           [round_id, shot_id, attempt]
         ) do
      {:ok, %{rows: [[journal]]}} -> {:ok, decode(journal)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp fetch_tool_journal({round_id, shot_id, attempt, tool_key}) do
    case query(
           """
           SELECT journal FROM tool_journals
           WHERE round_id = ? AND shot_id = ? AND attempt = ? AND tool_key = ?
           """,
           [round_id, shot_id, attempt, tool_key]
         ) do
      {:ok, %{rows: [[journal]]}} -> {:ok, decode(journal)}
      {:ok, %{rows: []}} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp round_exists?(round_id) do
    case query("SELECT 1 FROM rounds WHERE id = ? LIMIT 1", [round_id]) do
      {:ok, %{rows: [_row]}} -> {:ok, true}
      {:ok, %{rows: []}} -> {:ok, false}
      {:error, _reason} = error -> error
    end
  end

  defp round_exists!(round_id) do
    case round_exists?(round_id) do
      {:ok, exists?} -> exists?
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp transition_committed?(round_id, transition_id) do
    case query(
           """
           SELECT 1 FROM committed_transitions
           WHERE round_id = ? AND transition_id = ?
           LIMIT 1
           """,
           [round_id, transition_id]
         ) do
      {:ok, %{rows: [_row]}} -> true
      {:ok, %{rows: []}} -> false
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp current_version(round_id) do
    case query("SELECT version FROM rounds WHERE id = ?", [round_id]) do
      {:ok, %{rows: [[version]]}} -> version
      {:ok, %{rows: []}} -> nil
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp next_event_seq(round_id) do
    case query("SELECT COALESCE(MAX(seq), 0) + 1 FROM round_events WHERE round_id = ?", [
           round_id
         ]) do
      {:ok, %{rows: [[seq]]}} -> seq
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp events_after(round_id, opts) do
    after_seq = opts |> Keyword.get(:after_seq, 0) |> normalize_non_negative_integer(0)
    limit = opts |> Keyword.get(:limit, 100) |> normalize_positive_integer(100) |> min(1_000)

    case query(
           """
           SELECT event FROM round_events
           WHERE round_id = ? AND seq > ?
           ORDER BY seq
           LIMIT ?
           """,
           [round_id, after_seq, limit]
         ) do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [event] -> decode(event) end)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp audit_events_after(events, opts) do
    after_seq = opts |> Keyword.get(:after_seq, 0) |> normalize_non_negative_integer(0)
    limit = opts |> Keyword.get(:limit, 100) |> normalize_positive_integer(100) |> min(1_000)

    events
    |> assign_audit_sequences()
    |> Enum.filter(&(value(&1, :seq) > after_seq))
    |> Enum.take(limit)
  end

  defp assign_audit_sequences(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, seq} -> put_value(event, :seq, value(event, :seq) || seq) end)
  end

  defp notify_event_watchers(state, round_id) do
    watcher_refs = Map.get(state.event_watcher_refs, round_id, MapSet.new())

    Enum.reduce(watcher_refs, state, fn watcher_ref, acc ->
      case Map.fetch(acc.event_watchers, watcher_ref) do
        {:ok, watcher} ->
          case events_after(watcher.round_id, watcher.opts) do
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

  defp merge_journal_finish(existing, finish) do
    merged = Map.merge(existing, finish)

    cond do
      existing == merged ->
        :already_recorded

      finished_journal?(existing) ->
        {:error, :journal_conflict}

      true ->
        {:ok, merged}
    end
  end

  defp finished_journal?(record) do
    value(record, :status) in [:completed, :failed, :observed_result, :reconcile_required]
  end

  defp assign_event_sequences(events, first_seq) do
    Enum.map_reduce(events, first_seq, fn event, seq ->
      {put_value(event, :seq, seq), seq + 1}
    end)
  end

  defp query_ok(sql, params) do
    case query(sql, params) do
      {:ok, _result} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp query(sql, params) do
    SQL.query(Repo, sql, params)
  rescue
    error -> {:error, error}
  end

  defp encode(term), do: :erlang.term_to_binary(term)
  defp decode(binary), do: :erlang.binary_to_term(binary, [:safe])
  defp encode_nullable(nil), do: nil
  defp encode_nullable(term), do: encode(term)
  defp decode_nullable(nil), do: nil
  defp decode_nullable(binary), do: decode(binary)

  defp attempt_key(attempt) do
    {fetch_id!(attempt, :round), value(attempt, :shot_id), value(attempt, :attempt)}
  end

  defp tool_intent_key(intent) do
    {
      fetch_id!(intent, :round),
      value(intent, :shot_id),
      value(intent, :attempt),
      tool_key(intent)
    }
  end

  defp tool_key(intent) do
    intent
    |> tool_journal_id()
    |> to_string()
  end

  defp tool_journal_id(record) do
    value(record, :provider_tool_call_id) || value(record, :tool_call_index) || value(record, :id) ||
      ""
  end

  defp fetch_id!(record, :round) do
    value(record, :round_id) || value(record, :id) || raise ArgumentError, "missing round id"
  end

  defp snapshot_version(snapshot), do: value(snapshot, :version) || 0

  defp now_string, do: DateTime.to_iso8601(Twelvgaige.Clock.utc_now())

  defp round_query_columns(snapshot) do
    error = value(snapshot, :error)

    %{
      shell_id: query_value(value(snapshot, :shell_id)),
      shell_version: query_value(value(snapshot, :shell_version)),
      started_at: query_value(value(snapshot, :started_at)),
      completed_at: query_value(value(snapshot, :completed_at)),
      error_class: query_value(error_value(error, :class)),
      error_reason: query_value(error_value(error, :reason))
    }
  end

  defp error_value(nil, _key), do: nil
  defp error_value(%Twelvgaige.Error{} = error, key), do: Map.get(error, key)
  defp error_value(error, key) when is_map(error), do: value(error, key)
  defp error_value(_error, _key), do: nil

  defp query_value(nil), do: nil
  defp query_value(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp query_value(value) when is_atom(value), do: Atom.to_string(value)
  defp query_value(value), do: to_string(value)

  defp value(record, key) when is_map(record) do
    Map.get(record, key) || Map.get(record, Atom.to_string(key))
  end

  defp put_value(record, key, value) when is_map(record) do
    Map.put(record, key, value)
  end

  defp normalize_status(status) when is_atom(status), do: Atom.to_string(status)
  defp normalize_status(status) when is_binary(status), do: status
  defp normalize_status(status), do: to_string(status)

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

  defp normalize_journal_mode(mode) when mode in [:wal, "wal", "WAL"], do: "WAL"
  defp normalize_journal_mode(mode) when mode in [:delete, "delete", "DELETE"], do: "DELETE"

  defp normalize_journal_mode(mode) when mode in [:truncate, "truncate", "TRUNCATE"],
    do: "TRUNCATE"

  defp normalize_journal_mode(mode) when mode in [:persist, "persist", "PERSIST"], do: "PERSIST"
  defp normalize_journal_mode(_mode), do: "WAL"
end
