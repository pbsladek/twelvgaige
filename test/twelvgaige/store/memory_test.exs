defmodule Twelvgaige.Store.MemoryTest do
  use ExUnit.Case, async: true
  use Twelvgaige.TestSupport.StoreContract

  alias Twelvgaige.Store.Memory

  setup do
    name = :"store_#{System.unique_integer([:positive])}"
    start_supervised!({Memory, name: name})

    original = Process.whereis(Memory)

    if original do
      :ok
    end

    %{name: name, store: name}
  end

  test "creates and fetches a round", %{name: name} do
    snapshot = %{id: "round_1", status: :firing, version: 0}
    manifest = %{round_id: "round_1", compiled_pattern: %{}}

    assert :ok = GenServer.call(name, {:create_round, snapshot, manifest, []})
    assert {:ok, ^snapshot} = GenServer.call(name, {:get_round, "round_1"})
    assert {:ok, ^manifest} = GenServer.call(name, {:get_manifest, "round_1"})
  end

  test "commits transitions idempotently and assigns event seq", %{name: name} do
    snapshot = %{
      id: "round_1",
      status: :firing,
      version: 0,
      shots: [%{id: "shot_a", kind: :slug, status: :pending, attempt: 0}]
    }

    assert :ok = GenServer.call(name, {:create_round, snapshot, %{}, []})

    assert {:ok, [%{shot_id: "shot_a", status: "pending", attempt: 0}]} =
             GenServer.call(name, {:list_shot_runs, "round_1"})

    next = %{
      id: "round_1",
      status: :complete,
      shots: [%{id: "shot_a", kind: :slug, status: :complete, attempt: 1}]
    }

    events = [%{type: :round_completed}]

    assert :ok =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 0, "tr_1", next, events, []}
             )

    assert :already_committed =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 0, "tr_1", next, events, []}
             )

    assert {:ok, %{version: 1}} = GenServer.call(name, {:get_round, "round_1"})
    assert {:ok, [%{seq: 1}]} = GenServer.call(name, {:list_round_events, "round_1", []})

    assert {:ok, [%{shot_id: "shot_a", status: "complete", attempt: 1}]} =
             GenServer.call(name, {:list_shot_runs, "round_1"})
  end

  test "reports retained round and event stats", %{name: name} do
    snapshot = %{id: "round_1", status: :firing, version: 0}
    created = %{event_type: :round_created, round_id: "round_1", actor: "system"}

    assert :ok = GenServer.call(name, {:create_round, snapshot, %{}, [created]})

    assert :ok =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 0, "tr_1", %{snapshot | status: :complete},
                [%{type: :round_completed}], []}
             )

    assert {:ok, stats} = GenServer.call(name, :stats)
    assert stats.rounds == 1
    assert stats.terminal_rounds == 1
    assert stats.incomplete_rounds == 0
    assert stats.round_events == 1
    assert stats.audit_events == 1
    assert stats.attempt_journals == 0
    assert stats.tool_journals == 0
    assert stats.retained_bytes_limit > 0
    refute stats.retained_bytes_over_limit
    assert stats.retained_bytes > 0
  end

  test "evicts oldest terminal rounds when retained bytes exceed the configured cap" do
    name = :"retained_store_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: {:memory_retention, name},
      start: {Memory, :start_link, [[name: name, max_retained_bytes: 1]]}
    })

    first = %{
      id: "round_old",
      status: :complete,
      version: 0,
      completed_at: "2026-05-01T00:00:00Z"
    }

    second = %{
      id: "round_new",
      status: :complete,
      version: 0,
      completed_at: "2026-05-01T00:00:01Z"
    }

    assert :ok = GenServer.call(name, {:create_round, first, %{round_id: "round_old"}, []})
    assert :ok = GenServer.call(name, {:create_round, second, %{round_id: "round_new"}, []})

    assert {:error, :not_found} = GenServer.call(name, {:get_round, "round_old"})
    assert {:error, :not_found} = GenServer.call(name, {:get_manifest, "round_old"})
    assert {:ok, ^second} = GenServer.call(name, {:get_round, "round_new"})

    assert {:ok, stats} = GenServer.call(name, :stats)
    assert stats.rounds == 1
    assert stats.terminal_rounds == 1
    assert stats.evicted_rounds == 1
    assert stats.retained_bytes_over_limit
  end

  test "lists audit events with per-round sequence cursors", %{name: name} do
    snapshot = %{id: "round_1", status: :firing, version: 0}

    created = %{
      event_type: :round_created,
      round_id: "round_1",
      actor: "system",
      payload: %{authorization: "Bearer abc123"}
    }

    assert :ok = GenServer.call(name, {:create_round, snapshot, %{}, [created]})

    attempt = %{round_id: "round_1", shot_id: "shot_1", attempt: 1, status: :started}
    started = %{event_type: :shot_attempt_started, round_id: "round_1", actor: "system"}
    assert :ok = GenServer.call(name, {:record_attempt_started, attempt, [started]})

    assert {:ok,
            [
              %{seq: 1, event_type: :round_created, payload: %{authorization: "[REDACTED]"}},
              %{seq: 2, event_type: :shot_attempt_started}
            ]} =
             GenServer.call(name, {:list_audit_events, "round_1", []})

    assert {:ok, [%{seq: 2, event_type: :shot_attempt_started}]} =
             GenServer.call(name, {:list_audit_events, "round_1", [after_seq: 1, limit: 1]})
  end

  test "awaits round events without blocking transition commits", %{name: name} do
    snapshot = %{id: "round_1", status: :firing, version: 0}
    assert :ok = GenServer.call(name, {:create_round, snapshot, %{}, []})

    waiter =
      Task.async(fn ->
        GenServer.call(
          name,
          {:await_round_events, "round_1", [after_seq: 0, timeout_ms: 1_000]},
          2_000
        )
      end)

    Process.sleep(10)

    next = %{id: "round_1", status: :complete}
    events = [%{type: :round_completed}]

    assert :ok =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 0, "tr_1", next, events, []}
             )

    assert {:ok, [%{seq: 1, type: :round_completed}]} = Task.await(waiter)
  end

  test "detects version conflicts", %{name: name} do
    snapshot = %{id: "round_1", status: :firing, version: 2}
    assert :ok = GenServer.call(name, {:create_round, snapshot, %{}, []})

    assert {:error, :version_conflict} =
             GenServer.call(
               name,
               {:commit_transition, "round_1", 1, "tr_1", snapshot, [], []}
             )
  end

  test "lists incomplete rounds", %{name: name} do
    assert :ok = GenServer.call(name, {:create_round, %{id: "running", status: :firing}, %{}, []})
    assert :ok = GenServer.call(name, {:create_round, %{id: "done", status: :complete}, %{}, []})

    assert {:ok, [%{id: "running"}]} = GenServer.call(name, :list_incomplete_rounds)
  end

  test "lists all rounds and filters by status", %{name: name} do
    assert :ok = GenServer.call(name, {:create_round, %{id: "running", status: :firing}, %{}, []})
    assert :ok = GenServer.call(name, {:create_round, %{id: "done", status: :complete}, %{}, []})

    assert {:ok, rounds} = GenServer.call(name, {:list_rounds, []})
    assert Enum.map(rounds, & &1.id) == ["done", "running"]

    assert {:ok, [%{id: "done"}]} = GenServer.call(name, {:list_rounds, [status: :complete]})
    assert {:ok, [%{id: "done"}]} = GenServer.call(name, {:list_rounds, [status: "complete"]})
  end

  test "records journal outcomes only after start or intent", %{name: name} do
    attempt = %{round_id: "round_1", shot_id: "shot_1", attempt: 1, status: :started}
    attempt_finished = %{round_id: "round_1", shot_id: "shot_1", attempt: 1, status: :completed}

    assert {:error, :journal_missing} =
             GenServer.call(name, {:record_attempt_finished, attempt_finished, []})

    assert :ok = GenServer.call(name, {:record_attempt_started, attempt, []})
    assert :ok = GenServer.call(name, {:record_attempt_finished, attempt_finished, []})

    assert :already_recorded =
             GenServer.call(name, {:record_attempt_finished, attempt_finished, []})

    conflicting = Map.put(attempt_finished, :status, :failed)

    assert {:error, :journal_conflict} =
             GenServer.call(name, {:record_attempt_finished, conflicting, []})

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

    assert {:error, :journal_missing} = GenServer.call(name, {:record_tool_result, result, []})
    assert :ok = GenServer.call(name, {:record_tool_intent, intent, []})
    assert :ok = GenServer.call(name, {:record_tool_result, result, []})
    assert :already_recorded = GenServer.call(name, {:record_tool_result, result, []})

    assert {:ok, [^attempt_finished]} = GenServer.call(name, {:list_attempt_journals, "round_1"})
    assert {:ok, [^result]} = GenServer.call(name, {:list_tool_journals, "round_1"})
  end

  test "redacts sensitive journal payloads before retention", %{name: name} do
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

    assert {:ok, [journal]} = GenServer.call(name, {:list_tool_journals, "round_1"})
    assert journal.input.password == "[REDACTED]"
    assert journal.output["token"] == "[REDACTED]"
  end

  test "summary sensitive retention omits raw journal payloads" do
    name = :"store_summary_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: name,
      start: {Memory, :start_link, [[name: name, sensitive_retention: :summary]]}
    })

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

    assert {:ok, [journal]} = GenServer.call(name, {:list_tool_journals, "round_1"})
    assert journal.input["summary"] == "omitted"
    assert journal.output["summary"] == "omitted"
    refute inspect(journal) =~ "canary-secret"
  end
end
