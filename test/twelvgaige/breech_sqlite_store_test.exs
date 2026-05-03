defmodule Twelvgaige.BreechSQLiteStoreTest do
  use ExUnit.Case, async: false

  @moduletag :persistence

  alias Twelvgaige.Breech
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Shot
  alias Twelvgaige.Store.SQLite, as: SQLiteStore

  @workflow %{
    kind: :workflow,
    id: "breech_sqlite_store",
    version: "1.0.0",
    shots: [
      %{id: "only", kind: :slug, agent: "agent", prompt: "hello"}
    ]
  }

  @safety_workflow %{
    kind: :workflow,
    id: "breech_sqlite_safety",
    version: "1.0.0",
    shots: [
      %{id: "approval", kind: :safety, description: "review"},
      %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"]}
    ]
  }

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_breech_sqlite_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)

    %{path: Path.join(dir, "store.db")}
  end

  test "daemon-owned rounds can use the sqlite store across store restart", %{path: path} do
    breech_name = :"breech_sqlite_#{System.unique_integer([:positive])}"
    round_id = "round_sqlite_#{System.unique_integer([:positive])}"

    start_supervised!({SQLiteStore, path: path})
    start_supervised!({Breech, name: breech_name, store: SQLiteStore})

    assert {:ok, ^round_id} =
             Breech.start_round(@workflow, %{}, server: breech_name, round_id: round_id)

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)

    assert {:ok, [%{event_type: :round_completed}]} =
             Breech.list_round_events(round_id, server: breech_name)

    stop_supervised!(Breech)
    stop_supervised!(SQLiteStore)

    start_supervised!({SQLiteStore, path: path})
    start_supervised!({Breech, name: breech_name, store: SQLiteStore})

    assert {:ok, snapshot} = Breech.get_round(round_id, server: breech_name)
    assert snapshot.status == :complete
    assert [%{id: "only", status: :complete}] = snapshot.shots

    assert {:ok, rounds} = Breech.list_rounds(server: breech_name, status: :complete)
    assert Enum.any?(rounds, &(&1.id == round_id))

    assert {:ok, [%{event_type: :round_completed, seq: 1}]} =
             Breech.list_round_events(round_id, server: breech_name)
  end

  test "sqlite store participates in startup partial recovery", %{path: path} do
    breech_name = :"breech_sqlite_partial_#{System.unique_integer([:positive])}"
    round_id = "round_sqlite_partial_#{System.unique_integer([:positive])}"

    workflow = %{
      kind: :workflow,
      id: "breech_sqlite_partial",
      version: "1.0.0",
      shots: [
        %{id: "first", kind: :slug, agent: "agent", prompt: "first"},
        %{id: "second", kind: :slug, agent: "agent", prompt: "second", depends_on: ["first"]}
      ]
    }

    start_supervised!({SQLiteStore, path: path})

    snapshot =
      recovery_snapshot(round_id, workflow,
        status: :firing,
        version: 1,
        shots: [
          %{
            id: "first",
            kind: :slug,
            status: :complete,
            output: %{"content" => "already completed"}
          },
          %{id: "second", kind: :slug, depends_on: ["first"], status: :running, attempt: 1}
        ]
      )

    manifest = %{
      round_id: round_id,
      shell_id: Map.fetch!(workflow, :id),
      workflow: shell!(workflow)
    }

    assert :ok = SQLiteStore.create_round(snapshot, manifest, [])

    assert :ok =
             SQLiteStore.record_attempt_started(
               %{round_id: round_id, shot_id: "second", attempt: 1, status: :started},
               []
             )

    start_supervised!({Breech, name: breech_name, store: SQLiteStore})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)

    assert {:ok, completed} = Breech.get_round(round_id, server: breech_name)
    shots = Map.new(completed.shots, &{&1.id, &1})

    assert completed.version == 3
    assert shots["first"].status == :complete
    assert shots["first"].output == %{"content" => "already completed"}
    assert shots["second"].status == :complete
    assert shots["second"].attempt == 2
  end

  test "Breech startup routes scheduler-owned sqlite rounds through Round.Server", %{
    path: path
  } do
    breech_name = :"breech_sqlite_scheduler_partial_#{System.unique_integer([:positive])}"
    round_id = "round_sqlite_scheduler_partial_#{System.unique_integer([:positive])}"

    start_supervised!({SQLiteStore, path: path})

    snapshot =
      recovery_snapshot(round_id, @workflow,
        status: :firing,
        version: 1,
        policy: %{scheduler_owned?: true},
        shots: [
          %{id: "only", kind: :slug, status: :running, attempt: 1}
        ]
      )

    manifest = %{
      round_id: round_id,
      shell_id: Map.fetch!(@workflow, :id),
      workflow: shell!(@workflow)
    }

    assert :ok = SQLiteStore.create_round(snapshot, manifest, [])

    assert :ok =
             SQLiteStore.record_attempt_started(
               %{round_id: round_id, shot_id: "only", attempt: 1, status: :started},
               []
             )

    start_supervised!({Breech, name: breech_name, store: SQLiteStore})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)

    assert {:ok, completed} = Breech.get_round(round_id, server: breech_name)
    assert completed.status == :complete
    assert completed.version == 5
    assert [%{id: "only", status: :complete, attempt: 2, history: [history]}] = completed.shots
    assert history.recovery_action == :retry_no_tool
  end

  test "Breech startup moves ambiguous in-flight sqlite rounds to reconciliation", %{
    path: path
  } do
    breech_name = :"breech_sqlite_reconcile_#{System.unique_integer([:positive])}"
    round_id = "round_sqlite_reconcile_#{System.unique_integer([:positive])}"

    start_supervised!({SQLiteStore, path: path})

    snapshot =
      recovery_snapshot(round_id, @workflow,
        status: :firing,
        version: 1,
        shots: [
          %{id: "only", kind: :slug, status: :running, attempt: 1}
        ]
      )

    manifest = %{
      round_id: round_id,
      shell_id: Map.fetch!(@workflow, :id),
      workflow: shell!(@workflow)
    }

    assert :ok = SQLiteStore.create_round(snapshot, manifest, [])

    assert :ok =
             SQLiteStore.record_attempt_started(
               %{round_id: round_id, shot_id: "only", attempt: 1, status: :started},
               []
             )

    assert :ok =
             SQLiteStore.record_tool_intent(
               %{
                 round_id: round_id,
                 shot_id: "only",
                 attempt: 1,
                 id: "tool_1",
                 status: :intent_recorded,
                 safety_level: :idempotent_write,
                 idempotency: %{class: :idempotent}
               },
               []
             )

    assert :ok =
             SQLiteStore.record_tool_result(
               %{
                 round_id: round_id,
                 shot_id: "only",
                 attempt: 1,
                 id: "tool_1",
                 status: :observed_result
               },
               []
             )

    start_supervised!({Breech, name: breech_name, store: SQLiteStore})

    assert {:ok, snapshot} = Breech.get_round(round_id, server: breech_name)
    assert snapshot.status == :awaiting_reconciliation
    assert snapshot.version == 2
    assert snapshot.error.reason == :shot_crash
    assert snapshot.error.details.journal_summary.observed_tool_results == 1
    assert snapshot.error.details.journal_summary.write_intents == 1
    assert [%{status: :awaiting_reconciliation, error: %{reason: :shot_crash}}] = snapshot.shots
  end

  test "awaiting safety rounds resume after Breech and sqlite store restart", %{path: path} do
    breech_name = :"breech_sqlite_safety_#{System.unique_integer([:positive])}"
    round_id = "round_sqlite_safety_#{System.unique_integer([:positive])}"

    start_supervised!({SQLiteStore, path: path})
    start_supervised!({Breech, name: breech_name, store: SQLiteStore})

    assert {:ok, ^round_id} =
             Breech.start_round(@safety_workflow, %{}, server: breech_name, round_id: round_id)

    assert eventually(fn ->
             match?(
               {:ok, %{status: :awaiting_safety}},
               Breech.get_round(round_id, server: breech_name)
             )
           end)

    stop_supervised!(Breech)
    stop_supervised!(SQLiteStore)

    start_supervised!({SQLiteStore, path: path})
    start_supervised!({Breech, name: breech_name, store: SQLiteStore})

    assert {:ok, snapshot} = Breech.get_round(round_id, server: breech_name)
    assert snapshot.status == :awaiting_safety
    assert [%{"shot_id" => "approval"}] = snapshot.awaiting_safety

    assert :ok =
             Breech.approve_safety(round_id, "approval",
               server: breech_name,
               reason: "sqlite restart review",
               actor: "human:test"
             )

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)

    assert {:ok, complete} = Breech.get_round(round_id, server: breech_name)
    shots = Map.new(complete.shots, &{&1.id, &1})
    assert shots["approval"].output["reason"] == "sqlite restart review"
    assert shots["after"].status == :complete
  end

  defp eventually(fun), do: eventually(fun, 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts_left) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts_left - 1)
    end
  end

  defp recovery_snapshot(round_id, workflow, attrs) do
    defaults = [
      id: round_id,
      shell_id: Map.fetch!(workflow, :id),
      shell_version: Map.fetch!(workflow, :version),
      shots: [%{id: "only", kind: :slug, status: :pending}]
    ]

    defaults
    |> Keyword.merge(attrs)
    |> Keyword.update!(:shots, &Enum.map(&1, fn attrs -> Shot.State.new(attrs) end))
    |> Snapshot.new()
  end

  defp shell!(workflow) do
    {:ok, shell} = Twelvgaige.Shell.Workflow.from_map(workflow)
    shell
  end
end
