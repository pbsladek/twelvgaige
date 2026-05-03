defmodule Twelvgaige.TestSupport.StoreContract do
  @moduledoc false

  import ExUnit.Assertions

  defmacro __using__(opts \\ []) do
    persistent? = Keyword.get(opts, :persistent, false)

    quote bind_quoted: [persistent?: persistent?] do
      test "store contract: creates, fetches, lists, and reports stats", context do
        context =
          Twelvgaige.TestSupport.StoreContract.ensure_started(context, &start_supervised!/1)

        store = context.store

        Twelvgaige.TestSupport.StoreContract.assert_round_contract(store)
      end

      test "store contract: commits transitions idempotently with event cursors", context do
        context =
          Twelvgaige.TestSupport.StoreContract.ensure_started(context, &start_supervised!/1)

        store = context.store

        Twelvgaige.TestSupport.StoreContract.assert_transition_contract(store)
      end

      test "store contract: records attempt and tool journals idempotently", context do
        context =
          Twelvgaige.TestSupport.StoreContract.ensure_started(context, &start_supervised!/1)

        store = context.store

        Twelvgaige.TestSupport.StoreContract.assert_journal_contract(store)
      end

      test "store contract: awaits future round events by cursor", context do
        context =
          Twelvgaige.TestSupport.StoreContract.ensure_started(context, &start_supervised!/1)

        store = context.store

        Twelvgaige.TestSupport.StoreContract.assert_event_wait_contract(store)
      end

      if persistent? do
        test "store contract: reloads durable records after restart", context do
          context =
            Twelvgaige.TestSupport.StoreContract.ensure_started(context, &start_supervised!/1)

          Twelvgaige.TestSupport.StoreContract.create_restart_fixture(context.store)

          stop_supervised!(Map.get(context, :store_child_id, context.store_module))
          start_supervised!({context.store_module, context.store_start_opts})

          Twelvgaige.TestSupport.StoreContract.assert_restart_fixture(context.store)
        end
      end
    end
  end

  def ensure_started(
        %{store_module: store_module, store_start_opts: start_opts} = context,
        start_fun
      )
      when is_function(start_fun, 1) do
    if Process.whereis(context.store) do
      context
    else
      start_fun.({store_module, start_opts})
      context
    end
  end

  def ensure_started(context, _start_fun), do: context

  def assert_round_contract(store) do
    snapshot = %{
      id: "contract_round",
      status: :firing,
      version: 0,
      shots: [%{id: "root", kind: :slug, status: :pending, attempt: 0}]
    }

    manifest = %{round_id: "contract_round", shell_id: "contract", workflow: %{id: "contract"}}
    audit = [%{event_type: :round_created, round_id: "contract_round", payload: %{token: "raw"}}]

    assert :ok = call(store, {:create_round, snapshot, manifest, audit})
    assert {:error, :round_already_exists} = call(store, {:create_round, snapshot, manifest, []})
    assert {:ok, ^snapshot} = call(store, {:get_round, "contract_round"})
    assert {:ok, ^manifest} = call(store, {:get_manifest, "contract_round"})
    assert {:error, :not_found} = call(store, {:get_round, "missing_round"})
    assert {:error, :not_found} = call(store, {:get_manifest, "missing_round"})

    assert {:ok, [%{id: "contract_round"}]} = call(store, {:list_rounds, []})
    assert {:ok, []} = call(store, {:list_rounds, [status: :complete]})
    assert {:ok, [%{id: "contract_round"}]} = call(store, :list_incomplete_rounds)

    assert {:ok, [%{shot_id: "root", status: "pending", attempt: 0}]} =
             call(store, {:list_shot_runs, "contract_round"})

    assert {:error, :not_found} = call(store, {:list_shot_runs, "missing_round"})

    assert {:ok, [%{seq: 1, event_type: :round_created, payload: %{token: "[REDACTED]"}}]} =
             call(store, {:list_audit_events, "contract_round", []})

    assert {:ok, stats} = call(store, :stats)
    assert stats.rounds == 1
    assert stats.incomplete_rounds == 1
    assert stats.terminal_rounds == 0
    assert stats.audit_events == 1
    assert stats.retained_bytes > 0
    assert Map.has_key?(stats, :retained_bytes_limit)
    assert Map.has_key?(stats, :retained_bytes_over_limit)
  end

  def assert_transition_contract(store) do
    snapshot = %{
      id: "contract_transition",
      status: :firing,
      version: 0,
      shots: [%{id: "root", kind: :slug, status: :pending, attempt: 0}]
    }

    next = %{
      id: "contract_transition",
      status: :complete,
      shots: [%{id: "root", kind: :slug, status: :complete, attempt: 1}]
    }

    event = %{event_type: :round_completed}
    audit = %{event_type: :round_completed, round_id: "contract_transition", actor: "system"}

    assert :ok = call(store, {:create_round, snapshot, %{round_id: "contract_transition"}, []})

    assert :ok =
             call(
               store,
               {:commit_transition, "contract_transition", 0, "transition_1", next, [event],
                [audit]}
             )

    assert :already_committed =
             call(
               store,
               {:commit_transition, "contract_transition", 0, "transition_1", next, [event],
                [audit]}
             )

    assert {:error, :version_conflict} =
             call(
               store,
               {:commit_transition, "contract_transition", 0, "transition_2", next, [], []}
             )

    assert {:ok, %{version: 1, status: :complete}} =
             call(store, {:get_round, "contract_transition"})

    assert {:ok, [%{seq: 1, event_type: :round_completed}]} =
             call(store, {:list_round_events, "contract_transition", [after_seq: 0]})

    assert {:ok, []} = call(store, {:list_round_events, "contract_transition", [after_seq: 1]})

    assert {:ok, [%{shot_id: "root", status: "complete", attempt: 1}]} =
             call(store, {:list_shot_runs, "contract_transition"})

    assert {:ok, [%{seq: 1, event_type: :round_completed}]} =
             call(store, {:list_audit_events, "contract_transition", []})
  end

  def assert_journal_contract(store) do
    attempt = %{round_id: "contract_journal", shot_id: "shot_1", attempt: 1, status: :started}
    finished = %{round_id: "contract_journal", shot_id: "shot_1", attempt: 1, status: :completed}
    conflicting = %{finished | status: :failed}

    intent = %{
      round_id: "contract_journal",
      shot_id: "shot_1",
      attempt: 1,
      id: "tool_1",
      status: :intent_recorded
    }

    result = intent |> Map.put(:status, :observed_result) |> Map.put(:output, %{ok: true})
    conflicting_result = %{result | output: %{ok: false}}

    assert {:error, :journal_missing} = call(store, {:record_attempt_finished, finished, []})
    assert :ok = call(store, {:record_attempt_started, attempt, []})
    assert :already_recorded = call(store, {:record_attempt_started, attempt, []})
    assert :ok = call(store, {:record_attempt_finished, finished, []})
    assert :already_recorded = call(store, {:record_attempt_finished, finished, []})
    assert {:error, :journal_conflict} = call(store, {:record_attempt_finished, conflicting, []})
    assert {:ok, [^finished]} = call(store, {:list_attempt_journals, "contract_journal"})

    assert {:error, :journal_missing} = call(store, {:record_tool_result, result, []})
    assert :ok = call(store, {:record_tool_intent, intent, []})
    assert :already_recorded = call(store, {:record_tool_intent, intent, []})
    assert :ok = call(store, {:record_tool_result, result, []})
    assert :already_recorded = call(store, {:record_tool_result, result, []})

    assert {:error, :journal_conflict} =
             call(store, {:record_tool_result, conflicting_result, []})

    assert {:ok, [^result]} = call(store, {:list_tool_journals, "contract_journal"})
  end

  def assert_event_wait_contract(store) do
    snapshot = %{id: "contract_wait", status: :firing, version: 0}
    next = %{id: "contract_wait", status: :complete}

    assert :ok = call(store, {:create_round, snapshot, %{round_id: "contract_wait"}, []})

    waiter =
      Task.async(fn ->
        call(store, {:await_round_events, "contract_wait", [after_seq: 0, timeout_ms: 1_000]})
      end)

    assert :ok =
             call(
               store,
               {:commit_transition, "contract_wait", 0, "transition_wait", next,
                [%{event_type: :round_completed}], []}
             )

    assert {:ok, [%{seq: 1, event_type: :round_completed}]} = Task.await(waiter, 2_000)
  end

  def create_restart_fixture(store) do
    snapshot = %{
      id: "contract_restart",
      status: :firing,
      version: 0,
      shots: [%{id: "root", kind: :slug, status: :pending, attempt: 0}]
    }

    next = %{
      id: "contract_restart",
      status: :complete,
      shots: [%{id: "root", kind: :slug, status: :complete, attempt: 1}]
    }

    manifest = %{round_id: "contract_restart", shell_id: "contract", workflow: %{id: "contract"}}
    attempt = %{round_id: "contract_restart", shot_id: "root", attempt: 1, status: :completed}

    intent = %{
      round_id: "contract_restart",
      shot_id: "root",
      attempt: 1,
      id: "tool",
      status: :observed_result
    }

    assert :ok = call(store, {:create_round, snapshot, manifest, []})

    assert :ok =
             call(
               store,
               {:commit_transition, "contract_restart", 0, "transition_restart", next,
                [%{event_type: :round_completed}], []}
             )

    assert :ok = call(store, {:record_attempt_started, %{attempt | status: :started}, []})
    assert :ok = call(store, {:record_attempt_finished, attempt, []})
    assert :ok = call(store, {:record_tool_intent, %{intent | status: :intent_recorded}, []})
    assert :ok = call(store, {:record_tool_result, intent, []})
  end

  def assert_restart_fixture(store) do
    assert {:ok, %{version: 1, status: :complete}} = call(store, {:get_round, "contract_restart"})

    assert {:ok, %{round_id: "contract_restart"}} =
             call(store, {:get_manifest, "contract_restart"})

    assert :already_committed =
             call(
               store,
               {:commit_transition, "contract_restart", 0, "transition_restart",
                %{id: "contract_restart", status: :complete}, [], []}
             )

    assert {:ok, [%{seq: 1, event_type: :round_completed}]} =
             call(store, {:list_round_events, "contract_restart", []})

    assert {:ok, [%{status: :completed}]} =
             call(store, {:list_attempt_journals, "contract_restart"})

    assert {:ok, [%{status: :observed_result}]} =
             call(store, {:list_tool_journals, "contract_restart"})
  end

  defp call(store, request), do: GenServer.call(store, request)
end
