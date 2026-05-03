defmodule Twelvgaige.BreechFileStoreTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Breech
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Shot
  alias Twelvgaige.Store.File, as: FileStore

  @workflow %{
    kind: :workflow,
    id: "breech_file_store",
    version: "1.0.0",
    shots: [
      %{id: "only", kind: :slug, agent: "agent", prompt: "hello"}
    ]
  }

  @safety_workflow %{
    kind: :workflow,
    id: "breech_file_safety",
    version: "1.0.0",
    shots: [
      %{id: "approval", kind: :safety, description: "review"},
      %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"]}
    ]
  }

  setup do
    dir =
      Path.join(System.tmp_dir!(), "twelvgaige_breech_file_#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(dir) end)

    %{path: Path.join(dir, "store.etf")}
  end

  test "daemon-owned rounds can use the durable file store across store restart", %{path: path} do
    breech_name = :"breech_file_#{System.unique_integer([:positive])}"
    round_id = "round_file_#{System.unique_integer([:positive])}"

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert {:ok, ^round_id} =
             Breech.start_round(@workflow, %{}, server: breech_name, round_id: round_id)

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)

    assert {:ok, [%{event_type: :round_completed}]} =
             Breech.list_round_events(round_id, server: breech_name)

    stop_supervised!(Breech)
    stop_supervised!(FileStore)

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert {:ok, snapshot} = Breech.get_round(round_id, server: breech_name)
    assert snapshot.status == :complete
    assert [%{id: "only", status: :complete}] = snapshot.shots

    assert {:ok, rounds} = Breech.list_rounds(server: breech_name, status: :complete)
    assert Enum.any?(rounds, &(&1.id == round_id))

    assert {:ok, [%{event_type: :round_completed, seq: 1}]} =
             Breech.list_round_events(round_id, server: breech_name)
  end

  test "awaiting safety rounds resume after Breech and file store restart", %{path: path} do
    breech_name = :"breech_file_safety_#{System.unique_integer([:positive])}"
    round_id = "round_file_safety_#{System.unique_integer([:positive])}"

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert {:ok, ^round_id} =
             Breech.start_round(@safety_workflow, %{}, server: breech_name, round_id: round_id)

    assert eventually(fn ->
             match?(
               {:ok, %{status: :awaiting_safety}},
               Breech.get_round(round_id, server: breech_name)
             )
           end)

    stop_supervised!(Breech)
    stop_supervised!(FileStore)

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert {:ok, snapshot} = Breech.get_round(round_id, server: breech_name)
    assert snapshot.status == :awaiting_safety
    assert [%{"shot_id" => "approval"}] = snapshot.awaiting_safety

    assert :ok =
             Breech.approve_safety(round_id, "approval",
               server: breech_name,
               reason: "reviewed after restart",
               actor: "human:test"
             )

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)

    assert {:ok, complete} = Breech.get_round(round_id, server: breech_name)
    shots = Map.new(complete.shots, &{&1.id, &1})
    assert shots["approval"].output["reason"] == "reviewed after restart"
    assert shots["after"].status == :complete
  end

  test "scheduler-owned awaiting safety rounds resume through Round.Server", %{path: path} do
    breech_name = :"breech_file_scheduler_safety_#{System.unique_integer([:positive])}"
    round_id = "round_file_scheduler_safety_#{System.unique_integer([:positive])}"

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert {:ok, ^round_id} =
             Breech.start_round(@safety_workflow, %{},
               server: breech_name,
               round_id: round_id,
               scheduler?: true,
               limiter: nil
             )

    assert eventually(fn ->
             match?(
               {:ok, %{status: :awaiting_safety}},
               Breech.get_round(round_id, server: breech_name)
             )
           end)

    assert {:ok, awaiting} = Breech.get_round(round_id, server: breech_name)
    assert awaiting.version == 2
    assert awaiting.policy.scheduler_owned?

    assert eventually(fn ->
             safety_decision_result_ok?(
               Breech.approve_safety(round_id, "approval",
                 server: breech_name,
                 reason: "scheduler reviewed",
                 actor: "human:test",
                 limiter: nil
               )
             )
           end)

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)

    assert {:ok, complete} = Breech.get_round(round_id, server: breech_name)
    shots = Map.new(complete.shots, &{&1.id, &1})

    assert complete.version == 6
    assert shots["approval"].status == :complete
    assert shots["approval"].output["reason"] == "scheduler reviewed"
    assert shots["after"].status == :complete
  end

  test "scheduler-owned safety rejection stays on scheduler transition path", %{path: path} do
    breech_name = :"breech_file_scheduler_reject_#{System.unique_integer([:positive])}"
    round_id = "round_file_scheduler_reject_#{System.unique_integer([:positive])}"

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert {:ok, ^round_id} =
             Breech.start_round(@safety_workflow, %{},
               server: breech_name,
               round_id: round_id,
               scheduler?: true,
               limiter: nil
             )

    assert eventually(fn ->
             match?(
               {:ok, %{status: :awaiting_safety}},
               Breech.get_round(round_id, server: breech_name)
             )
           end)

    assert eventually(fn ->
             safety_decision_result_ok?(
               Breech.reject_safety(round_id, "approval",
                 server: breech_name,
                 reason: "scheduler rejected",
                 actor: "human:test",
                 limiter: nil
               )
             )
           end)

    assert eventually(fn ->
             match?({:ok, %{status: :halted}}, Breech.get_round(round_id, server: breech_name))
           end)

    assert {:ok, halted} = Breech.get_round(round_id, server: breech_name)
    shots = Map.new(halted.shots, &{&1.id, &1})

    assert halted.version == 3
    assert halted.error.reason == :safety_rejected
    assert shots["approval"].status == :failed
    assert shots["approval"].output["reason"] == "scheduler rejected"
    assert shots["after"].status == :pending
  end

  test "recovery uses the stored manifest instead of changed workflow files", %{path: path} do
    breech_name = :"breech_manifest_source_#{System.unique_integer([:positive])}"
    round_id = "round_manifest_source_#{System.unique_integer([:positive])}"
    workflow_path = Path.join(Path.dirname(path), "workflow.yaml")

    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml("stored_manifest_workflow"))

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert {:ok, ^round_id} =
             Breech.start_round(workflow_path, %{}, server: breech_name, round_id: round_id)

    assert eventually(fn ->
             match?(
               {:ok, %{status: :awaiting_safety}},
               Breech.get_round(round_id, server: breech_name)
             )
           end)

    stop_supervised!(Breech)
    stop_supervised!(FileStore)

    File.write!(workflow_path, "kind: agent\nid: changed_source\nversion: 1.0.0\n")

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert :ok =
             Breech.approve_safety(round_id, "approval",
               server: breech_name,
               reason: "manifest replay",
               actor: "human:test"
             )

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)

    assert {:ok, snapshot} = Breech.get_round(round_id, server: breech_name)
    assert snapshot.shell_id == "stored_manifest_workflow"
    assert Enum.map(snapshot.shots, & &1.id) == ["after", "approval"]
  end

  test "Breech normalizes tuple store application config", %{path: path} do
    previous = Application.get_env(:twelvgaige, :store)
    on_exit(fn -> restore_store_config(previous) end)

    Application.put_env(:twelvgaige, :store, {FileStore, path: path})

    breech_name = :"breech_file_config_#{System.unique_integer([:positive])}"
    round_id = "round_file_config_#{System.unique_integer([:positive])}"

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name})

    assert {:ok, ^round_id} =
             Breech.start_round(@workflow, %{}, server: breech_name, round_id: round_id)

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)
  end

  test "Breech refuses to start when the configured store is unavailable" do
    breech_name = :"breech_missing_store_#{System.unique_integer([:positive])}"
    trap_exit? = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:store_unavailable, FileStore}} =
               Breech.start_link(name: breech_name, store: FileStore)
    after
      Process.flag(:trap_exit, trap_exit?)
    end
  end

  test "Breech startup resumes recoverable queued file-store rounds", %{path: path} do
    breech_name = :"breech_file_recover_#{System.unique_integer([:positive])}"
    round_id = "round_file_recover_#{System.unique_integer([:positive])}"

    start_supervised!({FileStore, path: path})

    snapshot = recovery_snapshot(round_id, status: :queued)

    manifest = %{
      round_id: round_id,
      shell_id: Map.fetch!(@workflow, :id),
      workflow: shell!(@workflow)
    }

    assert :ok = FileStore.create_round(snapshot, manifest, [])

    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)
  end

  test "Breech startup resumes retryable partial file-store rounds", %{path: path} do
    breech_name = :"breech_file_partial_#{System.unique_integer([:positive])}"
    round_id = "round_file_partial_#{System.unique_integer([:positive])}"

    workflow = %{
      kind: :workflow,
      id: "breech_file_partial",
      version: "1.0.0",
      shots: [
        %{id: "first", kind: :slug, agent: "agent", prompt: "first"},
        %{id: "second", kind: :slug, agent: "agent", prompt: "second", depends_on: ["first"]}
      ]
    }

    start_supervised!({FileStore, path: path})

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

    assert :ok = FileStore.create_round(snapshot, manifest, [])

    assert :ok =
             FileStore.record_attempt_started(
               %{round_id: round_id, shot_id: "second", attempt: 1, status: :started},
               []
             )

    start_supervised!({Breech, name: breech_name, store: FileStore})

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

  test "Breech startup routes scheduler-owned recovered rounds through Round.Server", %{
    path: path
  } do
    breech_name = :"breech_file_scheduler_partial_#{System.unique_integer([:positive])}"
    round_id = "round_file_scheduler_partial_#{System.unique_integer([:positive])}"

    start_supervised!({FileStore, path: path})

    snapshot =
      recovery_snapshot(round_id,
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

    assert :ok = FileStore.create_round(snapshot, manifest, [])

    assert :ok =
             FileStore.record_attempt_started(
               %{round_id: round_id, shot_id: "only", attempt: 1, status: :started},
               []
             )

    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Breech.get_round(round_id, server: breech_name))
           end)

    assert {:ok, completed} = Breech.get_round(round_id, server: breech_name)
    assert completed.status == :complete
    assert completed.version == 5
    assert [%{id: "only", status: :complete, attempt: 2, history: [history]}] = completed.shots
    assert history.recovery_action == :retry_no_tool
  end

  test "Breech startup moves ambiguous in-flight file-store rounds to reconciliation", %{
    path: path
  } do
    breech_name = :"breech_file_reconcile_#{System.unique_integer([:positive])}"
    round_id = "round_file_reconcile_#{System.unique_integer([:positive])}"

    start_supervised!({FileStore, path: path})

    snapshot =
      recovery_snapshot(round_id,
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

    assert :ok = FileStore.create_round(snapshot, manifest, [])

    assert :ok =
             FileStore.record_attempt_started(
               %{round_id: round_id, shot_id: "only", attempt: 1, status: :started},
               []
             )

    assert :ok =
             FileStore.record_tool_intent(
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
             FileStore.record_tool_result(
               %{
                 round_id: round_id,
                 shot_id: "only",
                 attempt: 1,
                 id: "tool_1",
                 status: :observed_result
               },
               []
             )

    start_supervised!({Breech, name: breech_name, store: FileStore})

    assert {:ok, snapshot} = Breech.get_round(round_id, server: breech_name)
    assert snapshot.status == :awaiting_reconciliation
    assert snapshot.version == 2
    assert snapshot.error.reason == :shot_crash
    assert snapshot.error.details.journal_summary.observed_tool_results == 1
    assert snapshot.error.details.journal_summary.write_intents == 1
    assert [%{status: :awaiting_reconciliation, error: %{reason: :shot_crash}}] = snapshot.shots
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

  defp safety_decision_result_ok?(:ok), do: true

  defp safety_decision_result_ok?(
         {:error,
          %Twelvgaige.Error{
            class: :policy_error,
            reason: :policy_denied,
            message: "round is already active"
          }}
       ),
       do: false

  defp safety_decision_result_ok?(other) do
    flunk("unexpected safety decision result: #{inspect(other)}")
  end

  defp restore_store_config(nil), do: Application.delete_env(:twelvgaige, :store)
  defp restore_store_config(previous), do: Application.put_env(:twelvgaige, :store, previous)

  defp recovery_snapshot(round_id, attrs) do
    recovery_snapshot(round_id, @workflow, attrs)
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

  defp workflow_yaml(id) do
    """
    kind: workflow
    id: #{id}
    version: 1.0.0
    shots:
      - id: approval
        kind: safety
        description: review
      - id: after
        kind: slug
        agent: agent
        depends_on:
          - approval
        prompt: after
    """
  end
end
