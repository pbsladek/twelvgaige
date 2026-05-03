defmodule Twelvgaige.Round.ServerJournalTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Round.Server
  alias Twelvgaige.Shell.Workflow

  defmodule JournalStore do
    use Agent

    def start_link(_opts) do
      Agent.start_link(fn -> %{attempts: [], intents: []} end, name: __MODULE__)
    end

    def record_attempt_started(attempt, audit_events) do
      Agent.update(__MODULE__, fn state ->
        update_in(state.attempts, &(&1 ++ [{:started, attempt, audit_events}]))
      end)
    end

    def record_attempt_finished(attempt, audit_events) do
      Agent.update(__MODULE__, fn state ->
        update_in(state.attempts, &(&1 ++ [{:finished, attempt, audit_events}]))
      end)
    end

    def record_tool_intent(intent, audit_events) do
      Agent.update(__MODULE__, fn state ->
        update_in(state.intents, &(&1 ++ [{:intent, intent, audit_events}]))
      end)
    end

    def record_tool_result(result, audit_events) do
      Agent.update(__MODULE__, fn state ->
        update_in(state.intents, &(&1 ++ [{:result, result, audit_events}]))
      end)
    end

    def attempts, do: Agent.get(__MODULE__, & &1.attempts)
    def intents, do: Agent.get(__MODULE__, & &1.intents)
  end

  defmodule FailingStore do
    def record_attempt_started(_attempt, _audit_events), do: {:error, :store_down}
  end

  test "round server passes store journaling through to the runner before execution" do
    start_supervised!(JournalStore)

    root = tmp_dir!()
    File.write!(Path.join(root, "report.txt"), "cluster healthy")
    workflow = workflow_with_tool!()

    response = %{
      content: "reading",
      tool_calls: [
        %{"id" => "read_report", "name" => "shell_read", "input" => %{"path" => "report.txt"}}
      ]
    }

    assert {:ok, snapshot} =
             Server.run_sync(workflow, %{},
               round_id: "round_server_journal",
               response: response,
               tool_opts: [root: root],
               limiter: nil,
               store: JournalStore
             )

    assert snapshot.status == :complete

    assert [
             {:started, %{round_id: "round_server_journal", shot_id: "inspect", attempt: 1},
              [%{event_type: :shot_attempt_started}]},
             {:finished,
              %{
                round_id: "round_server_journal",
                shot_id: "inspect",
                attempt: 1,
                status: :completed
              }, [%{event_type: :shot_attempt_finished}]}
           ] = JournalStore.attempts()

    assert [
             {:intent,
              %{
                round_id: "round_server_journal",
                shot_id: "inspect",
                attempt: 1,
                tool_name: "shell_read"
              }, [%{event_type: :tool_intent_recorded}]},
             {:result,
              %{
                round_id: "round_server_journal",
                shot_id: "inspect",
                attempt: 1,
                tool_name: "shell_read",
                status: :observed_result
              }, [%{event_type: :tool_result_recorded}]}
           ] = JournalStore.intents()
  end

  test "round server returns a store error before attempt execution when journaling fails" do
    workflow = workflow_without_tool!()

    assert {:error, error} =
             Server.run_sync(workflow, %{},
               round_id: "round_server_journal_failure",
               response: "would have succeeded",
               store: FailingStore
             )

    assert error.class == :store_error
    assert error.reason == :store_unavailable
  end

  defp workflow_with_tool! do
    workflow!(%{
      kind: :workflow,
      id: "server_journal_round",
      version: "1.0.0",
      shots: [
        %{
          id: "inspect",
          kind: :slug,
          agent: "agent",
          tools: ["shell_read"],
          choke: %{max_iterations: 2},
          prompt: "inspect report"
        }
      ]
    })
  end

  defp workflow_without_tool! do
    workflow!(%{
      kind: :workflow,
      id: "server_journal_failure",
      version: "1.0.0",
      shots: [
        %{id: "inspect", kind: :slug, agent: "agent", prompt: "inspect report"}
      ]
    })
  end

  defp workflow!(map) do
    {:ok, workflow} = Workflow.from_map(map)
    workflow
  end

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-server-journal-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
