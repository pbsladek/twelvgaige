defmodule Twelvgaige.Store.SQLiteTest do
  use ExUnit.Case, async: false
  use Twelvgaige.TestSupport.StoreContract, persistent: true

  import Bitwise

  @moduletag :persistence

  alias Twelvgaige.Store.SQLite, as: SQLiteStore
  alias Twelvgaige.Store.SQLite.Migrations.Initial
  alias Twelvgaige.Store.SQLite.Migrations.RoundQueryColumns
  alias Twelvgaige.Store.SQLite.Migrations.ShotRuns
  alias Twelvgaige.Store.SQLite.Repo

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_sqlite_store_#{System.unique_integer([:positive])}"
      )

    path = Path.join(dir, "store.db")
    name = :"sqlite_store_#{System.unique_integer([:positive])}"

    on_exit(fn -> File.rm_rf(dir) end)

    %{
      name: name,
      path: path,
      store: name,
      store_module: SQLiteStore,
      store_child_id: SQLiteStore,
      store_start_opts: [name: name, path: path]
    }
  end

  @tag :posix_only
  test "creates private sqlite directory, database, and sidecars", %{name: name, path: path} do
    posix_only(fn ->
      start_supervised!({SQLiteStore, name: name, path: path})

      snapshot = %{id: "round_1", status: :firing, version: 0}
      assert :ok = GenServer.call(name, {:create_round, snapshot, %{}, []})

      assert file_mode(Path.dirname(path)) == 0o700
      assert file_mode(path) == 0o600

      for sidecar <- [path <> "-wal", path <> "-shm"], File.exists?(sidecar) do
        assert file_mode(sidecar) == 0o600
      end
    end)
  end

  test "persists and reloads rounds, manifests, transitions, and events", %{
    name: name,
    path: path
  } do
    start_supervised!({SQLiteStore, name: name, path: path})

    snapshot = %{
      id: "round_1",
      status: :firing,
      version: 0,
      shots: [%{id: "shot_a", kind: :slug, status: :pending, attempt: 0}]
    }

    manifest = %{round_id: "round_1", shell_id: "workflow", workflow: %{id: "workflow"}}

    created = %{
      event_type: :round_created,
      round_id: "round_1",
      actor: "system",
      payload: %{token: "raw"}
    }

    assert :ok = GenServer.call(name, {:create_round, snapshot, manifest, [created]})

    assert {:ok, [%{shot_id: "shot_a", status: "pending", attempt: 0}]} =
             GenServer.call(name, {:list_shot_runs, "round_1"})

    next = %{
      id: "round_1",
      status: :complete,
      shots: [%{id: "shot_a", kind: :slug, status: :complete, attempt: 1}]
    }

    events = [%{event_type: :round_completed}]
    audited = %{event_type: :round_completed, round_id: "round_1", actor: "system"}

    assert :ok =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 0, "transition_1", next, events, [audited]}
             )

    assert {:ok, %{version: 1, status: :complete}} =
             GenServer.call(name, {:get_round, "round_1"})

    assert {:ok, [%{seq: 1, event_type: :round_completed}]} =
             GenServer.call(name, {:list_round_events, "round_1", []})

    assert {:ok, [%{shot_id: "shot_a", status: "complete", attempt: 1}]} =
             GenServer.call(name, {:list_shot_runs, "round_1"})

    assert {:ok,
            [
              %{seq: 1, event_type: :round_created, payload: %{token: "[REDACTED]"}},
              %{seq: 2, event_type: :round_completed}
            ]} = GenServer.call(name, {:list_audit_events, "round_1", []})

    assert {:ok, stats} = GenServer.call(name, :stats)
    assert stats.rounds == 1
    assert stats.terminal_rounds == 1
    assert stats.incomplete_rounds == 0
    assert stats.round_events == 1
    assert stats.audit_events == 2
    assert stats.attempt_journals == 0
    assert stats.tool_journals == 0
    assert stats.retained_bytes_limit > 0
    refute stats.retained_bytes_over_limit
    assert stats.evicted_rounds == 0
    assert stats.retained_bytes > 0

    stop_supervised!(SQLiteStore)

    start_supervised!({SQLiteStore, name: name, path: path})

    assert {:ok, %{version: 1, status: :complete}} =
             GenServer.call(name, {:get_round, "round_1"})

    assert {:ok, ^manifest} = GenServer.call(name, {:get_manifest, "round_1"})

    assert {:ok, [%{seq: 1, event_type: :round_completed}]} =
             GenServer.call(name, {:list_round_events, "round_1", []})

    assert {:ok, [%{seq: 2, event_type: :round_completed}]} =
             GenServer.call(name, {:list_audit_events, "round_1", [after_seq: 1]})

    assert {:ok, [%{shot_id: "shot_a", status: "complete", attempt: 1}]} =
             GenServer.call(name, {:list_shot_runs, "round_1"})
  end

  test "applies the versioned schema migration", %{name: name, path: path} do
    start_supervised!({SQLiteStore, name: name, path: path})

    assert {:ok, %{rows: [[version]]}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "SELECT version FROM schema_migrations WHERE version = ?",
               [Initial.version()]
             )

    assert version == Initial.version()

    assert {:ok, %{rows: [[version]]}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "SELECT version FROM schema_migrations WHERE version = ?",
               [ShotRuns.version()]
             )

    assert version == ShotRuns.version()

    assert {:ok, %{rows: [[version]]}} =
             Ecto.Adapters.SQL.query(
               Repo,
               "SELECT version FROM schema_migrations WHERE version = ?",
               [RoundQueryColumns.version()]
             )

    assert version == RoundQueryColumns.version()
  end

  test "stores queryable round columns and filters with them", %{name: name, path: path} do
    start_supervised!({SQLiteStore, name: name, path: path})

    first_error =
      Twelvgaige.Error.new(:llm_error, :llm_timeout, "provider timed out", retryable: true)

    assert :ok =
             GenServer.call(
               name,
               {:create_round,
                %{
                  id: "round_old",
                  shell_id: "incident",
                  shell_version: "1.0.0",
                  status: :failed,
                  version: 0,
                  started_at: ~U[2026-05-01 10:00:00Z],
                  completed_at: ~U[2026-05-01 10:01:00Z],
                  error: first_error
                }, %{}, []}
             )

    assert :ok =
             GenServer.call(
               name,
               {:create_round,
                %{
                  id: "round_new",
                  shell_id: "incident",
                  shell_version: "1.1.0",
                  status: :complete,
                  version: 0,
                  started_at: ~U[2026-05-01 11:00:00Z],
                  completed_at: ~U[2026-05-01 11:02:00Z]
                }, %{}, []}
             )

    assert {:ok, %{rows: [[shell_id, shell_version, started_at, completed_at, error_reason]]}} =
             Ecto.Adapters.SQL.query(
               Repo,
               """
               SELECT shell_id, shell_version, started_at, completed_at, error_reason
               FROM rounds
               WHERE id = ?
               """,
               ["round_old"]
             )

    assert shell_id == "incident"
    assert shell_version == "1.0.0"
    assert started_at == "2026-05-01T10:00:00Z"
    assert completed_at == "2026-05-01T10:01:00Z"
    assert error_reason == "llm_timeout"

    assert {:ok, [%{id: "round_new"}]} =
             GenServer.call(
               name,
               {:list_rounds,
                [
                  shell_id: "incident",
                  started_after: "2026-05-01T10:30:00Z",
                  order_by: :started_at
                ]}
             )

    assert {:ok, [%{id: "round_old"}]} =
             GenServer.call(name, {:list_rounds, [error_reason: :llm_timeout]})
  end

  test "preserves idempotent transition tracking across restart", %{name: name, path: path} do
    start_supervised!({SQLiteStore, name: name, path: path})

    snapshot = %{id: "round_1", status: :firing, version: 0}
    assert :ok = GenServer.call(name, {:create_round, snapshot, %{}, []})

    next = %{id: "round_1", status: :complete}

    assert :ok =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 0, "transition_1", next, [], []}
             )

    stop_supervised!(SQLiteStore)
    start_supervised!({SQLiteStore, name: name, path: path})

    assert :already_committed =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 0, "transition_1", next, [], []}
             )
  end

  test "detects version conflicts and lists incomplete rounds", %{name: name, path: path} do
    start_supervised!({SQLiteStore, name: name, path: path})

    assert :ok =
             GenServer.call(name, {:create_round, %{id: "running", status: :firing}, %{}, []})

    assert :ok =
             GenServer.call(name, {:create_round, %{id: "done", status: :complete}, %{}, []})

    assert {:error, :version_conflict} =
             GenServer.call(
               name,
               {:commit_transition, "running", 1, "tr_1", %{id: "running"}, [], []}
             )

    assert {:ok, [%{id: "running"}]} = GenServer.call(name, :list_incomplete_rounds)
    assert {:ok, [%{id: "done"}]} = GenServer.call(name, {:list_rounds, [status: :complete]})
  end

  test "awaits events from the sqlite store process", %{name: name, path: path} do
    start_supervised!({SQLiteStore, name: name, path: path})

    assert :ok = GenServer.call(name, {:create_round, %{id: "round_1", status: :firing}, %{}, []})

    waiter =
      Task.async(fn ->
        GenServer.call(
          name,
          {:await_round_events, "round_1", [after_seq: 0, timeout_ms: 1_000]},
          2_000
        )
      end)

    next = %{id: "round_1", status: :complete}

    assert :ok =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 0, "transition_1", next, [%{type: :done}], []}
             )

    assert {:ok, [%{seq: 1, type: :done}]} = Task.await(waiter)
  end

  test "persists journal outcomes across restart", %{name: name, path: path} do
    start_supervised!({SQLiteStore, name: name, path: path})

    attempt = %{round_id: "round_1", shot_id: "shot_1", attempt: 1, status: :started}
    attempt_finished = %{round_id: "round_1", shot_id: "shot_1", attempt: 1, status: :completed}

    intent = %{
      round_id: "round_1",
      shot_id: "shot_1",
      attempt: 1,
      id: "tool_1",
      status: :intent_recorded
    }

    result = %{
      round_id: "round_1",
      shot_id: "shot_1",
      attempt: 1,
      id: "tool_1",
      status: :observed_result
    }

    assert :ok = GenServer.call(name, {:record_attempt_started, attempt, []})
    assert :ok = GenServer.call(name, {:record_attempt_finished, attempt_finished, []})
    assert :ok = GenServer.call(name, {:record_tool_intent, intent, []})
    assert :ok = GenServer.call(name, {:record_tool_result, result, []})

    stop_supervised!(SQLiteStore)
    start_supervised!({SQLiteStore, name: name, path: path})

    assert :already_recorded =
             GenServer.call(name, {:record_attempt_finished, attempt_finished, []})

    assert :already_recorded = GenServer.call(name, {:record_tool_result, result, []})
    assert {:ok, [^attempt_finished]} = GenServer.call(name, {:list_attempt_journals, "round_1"})
    assert {:ok, [^result]} = GenServer.call(name, {:list_tool_journals, "round_1"})
  end

  test "redacts sensitive journal payloads before persistence", %{name: name, path: path} do
    start_supervised!({SQLiteStore, name: name, path: path})

    intent = %{
      round_id: "round_1",
      shot_id: "shot_1",
      attempt: 1,
      id: "tool_1",
      status: :intent_recorded,
      input: %{password: "secret"}
    }

    result = %{
      round_id: "round_1",
      shot_id: "shot_1",
      attempt: 1,
      id: "tool_1",
      status: :observed_result,
      output: %{"token" => "secret"}
    }

    assert :ok = GenServer.call(name, {:record_tool_intent, intent, []})
    assert :ok = GenServer.call(name, {:record_tool_result, result, []})

    stop_supervised!(SQLiteStore)
    start_supervised!({SQLiteStore, name: name, path: path})

    assert {:ok, [journal]} = GenServer.call(name, {:list_tool_journals, "round_1"})
    assert journal.input.password == "[REDACTED]"
    assert journal.output["token"] == "[REDACTED]"
  end

  test "summary sensitive retention omits raw journal payloads across restart", %{
    name: name,
    path: path
  } do
    start_supervised!({SQLiteStore, name: name, path: path, sensitive_retention: :summary})

    intent = %{
      round_id: "round_1",
      shot_id: "shot_1",
      attempt: 1,
      id: "tool_1",
      status: :intent_recorded,
      input: %{token: "canary-secret", command: "inspect"}
    }

    result = %{
      round_id: "round_1",
      shot_id: "shot_1",
      attempt: 1,
      id: "tool_1",
      status: :observed_result,
      output: "Bearer canary-secret"
    }

    assert :ok = GenServer.call(name, {:record_tool_intent, intent, []})
    assert :ok = GenServer.call(name, {:record_tool_result, result, []})

    stop_supervised!(SQLiteStore)
    start_supervised!({SQLiteStore, name: name, path: path, sensitive_retention: :summary})

    assert {:ok, [journal]} = GenServer.call(name, {:list_tool_journals, "round_1"})
    assert journal.input["summary"] == "omitted"
    assert journal.output["summary"] == "omitted"
    refute inspect(journal) =~ "canary-secret"
    refute File.read!(path) =~ "canary-secret"
  end

  test "evicts oldest terminal rounds when retained bytes exceed the configured cap", %{
    name: name,
    path: path
  } do
    start_supervised!({SQLiteStore, name: name, path: path, max_retained_bytes: 1})

    running = %{
      id: "round_0_running",
      status: :firing,
      version: 0,
      shots: [%{id: "shot_running", kind: :slug, status: :pending, attempt: 0}]
    }

    old = %{
      id: "round_1_old",
      status: :complete,
      version: 0,
      shots: [%{id: "shot_old", kind: :slug, status: :complete, attempt: 1}]
    }

    newest = %{
      id: "round_2_new",
      status: :complete,
      version: 0,
      shots: [%{id: "shot_new", kind: :slug, status: :complete, attempt: 1}]
    }

    assert :ok =
             GenServer.call(name, {:create_round, running, %{round_id: "round_0_running"}, []})

    assert :ok = GenServer.call(name, {:create_round, old, %{round_id: "round_1_old"}, []})
    assert :ok = GenServer.call(name, {:create_round, newest, %{round_id: "round_2_new"}, []})

    assert {:error, :not_found} = GenServer.call(name, {:get_round, "round_1_old"})
    assert {:error, :not_found} = GenServer.call(name, {:get_manifest, "round_1_old"})
    assert {:error, :not_found} = GenServer.call(name, {:list_shot_runs, "round_1_old"})
    assert {:ok, %{id: "round_0_running"}} = GenServer.call(name, {:get_round, "round_0_running"})
    assert {:ok, %{id: "round_2_new"}} = GenServer.call(name, {:get_round, "round_2_new"})

    assert {:ok, stats} = GenServer.call(name, :stats)
    assert stats.rounds == 2
    assert stats.incomplete_rounds == 1
    assert stats.terminal_rounds == 1
    assert stats.retained_bytes_limit == 1
    assert stats.retained_bytes_over_limit
    assert stats.evicted_rounds == 1
  end

  defp file_mode(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    mode &&& 0o777
  end

  defp posix_only(fun), do: unless(windows?(), do: fun.())
  defp windows?, do: match?({:win32, _name}, :os.type())
end
