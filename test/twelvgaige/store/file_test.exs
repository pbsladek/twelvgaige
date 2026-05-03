defmodule Twelvgaige.Store.FileTest do
  use ExUnit.Case, async: true
  use Twelvgaige.TestSupport.StoreContract, persistent: true

  import Bitwise

  alias Twelvgaige.Store.File, as: FileStore

  setup do
    dir =
      Path.join(System.tmp_dir!(), "twelvgaige_file_store_#{System.unique_integer([:positive])}")

    path = Path.join(dir, "store.etf")
    name = :"file_store_#{System.unique_integer([:positive])}"

    on_exit(fn -> File.rm_rf(dir) end)

    %{
      name: name,
      path: path,
      store: name,
      store_module: FileStore,
      store_child_id: FileStore,
      store_start_opts: [name: name, path: path]
    }
  end

  @tag :posix_only
  test "creates private store directory and file", %{name: name, path: path} do
    posix_only(fn ->
      start_supervised!({FileStore, name: name, path: path})

      assert file_mode(Path.dirname(path)) == 0o700
      assert file_mode(path) == 0o600
    end)
  end

  test "persists and reloads rounds, manifests, transitions, and events", %{
    name: name,
    path: path
  } do
    start_supervised!({FileStore, name: name, path: path})

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
    assert stats.retained_bytes > 0

    stop_supervised!(FileStore)

    start_supervised!({FileStore, name: name, path: path})

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

  test "preserves idempotent transition tracking across restart", %{name: name, path: path} do
    start_supervised!({FileStore, name: name, path: path})

    snapshot = %{id: "round_1", status: :firing, version: 0}
    assert :ok = GenServer.call(name, {:create_round, snapshot, %{}, []})

    next = %{id: "round_1", status: :complete}

    assert :ok =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 0, "transition_1", next, [], []}
             )

    stop_supervised!(FileStore)
    start_supervised!({FileStore, name: name, path: path})

    assert :already_committed =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 0, "transition_1", next, [], []}
             )
  end

  test "persists retention eviction of terminal rounds", %{name: name, path: path} do
    start_supervised!({FileStore, name: name, path: path, max_retained_bytes: 1})

    old = %{
      id: "round_old",
      status: :complete,
      version: 0,
      completed_at: "2026-05-01T00:00:00Z"
    }

    new = %{
      id: "round_new",
      status: :complete,
      version: 0,
      completed_at: "2026-05-01T00:00:01Z"
    }

    assert :ok = GenServer.call(name, {:create_round, old, %{round_id: "round_old"}, []})
    assert :ok = GenServer.call(name, {:create_round, new, %{round_id: "round_new"}, []})

    assert {:error, :not_found} = GenServer.call(name, {:get_round, "round_old"})
    assert {:ok, ^new} = GenServer.call(name, {:get_round, "round_new"})

    stop_supervised!(FileStore)
    start_supervised!({FileStore, name: name, path: path, max_retained_bytes: 1})

    assert {:error, :not_found} = GenServer.call(name, {:get_round, "round_old"})
    assert {:ok, ^new} = GenServer.call(name, {:get_round, "round_new"})

    assert {:ok, stats} = GenServer.call(name, :stats)
    assert stats.rounds == 1
    assert stats.evicted_rounds == 1
    assert stats.retained_bytes_over_limit
  end

  test "lists incomplete rounds after reload", %{name: name, path: path} do
    start_supervised!({FileStore, name: name, path: path})

    assert :ok = GenServer.call(name, {:create_round, %{id: "running", status: :firing}, %{}, []})
    assert :ok = GenServer.call(name, {:create_round, %{id: "done", status: :complete}, %{}, []})

    stop_supervised!(FileStore)
    start_supervised!({FileStore, name: name, path: path})

    assert {:ok, [%{id: "running"}]} = GenServer.call(name, :list_incomplete_rounds)
  end

  test "awaits events from a durable store process", %{name: name, path: path} do
    start_supervised!({FileStore, name: name, path: path})

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
    start_supervised!({FileStore, name: name, path: path})

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

    stop_supervised!(FileStore)
    start_supervised!({FileStore, name: name, path: path})

    assert :already_recorded =
             GenServer.call(name, {:record_attempt_finished, attempt_finished, []})

    assert :already_recorded = GenServer.call(name, {:record_tool_result, result, []})
    assert {:ok, [^attempt_finished]} = GenServer.call(name, {:list_attempt_journals, "round_1"})
    assert {:ok, [^result]} = GenServer.call(name, {:list_tool_journals, "round_1"})
  end

  test "redacts sensitive journal payloads before persistence", %{name: name, path: path} do
    start_supervised!({FileStore, name: name, path: path})

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

    stop_supervised!(FileStore)
    start_supervised!({FileStore, name: name, path: path})

    assert {:ok, [journal]} = GenServer.call(name, {:list_tool_journals, "round_1"})
    assert journal.input.password == "[REDACTED]"
    assert journal.output["token"] == "[REDACTED]"
  end

  test "summary sensitive retention omits raw journal payloads across restart", %{
    name: name,
    path: path
  } do
    start_supervised!({FileStore, name: name, path: path, sensitive_retention: :summary})

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

    stop_supervised!(FileStore)
    start_supervised!({FileStore, name: name, path: path, sensitive_retention: :summary})

    assert {:ok, [journal]} = GenServer.call(name, {:list_tool_journals, "round_1"})
    assert journal.input["summary"] == "omitted"
    assert journal.output["summary"] == "omitted"
    refute inspect(journal) =~ "canary-secret"
    refute File.read!(path) =~ "canary-secret"
  end

  defp file_mode(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    mode &&& 0o777
  end

  defp posix_only(fun), do: unless(windows?(), do: fun.())
  defp windows?, do: match?({:win32, _name}, :os.type())
end
