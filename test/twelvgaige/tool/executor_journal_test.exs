defmodule Twelvgaige.Tool.ExecutorJournalTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Executor
  alias Twelvgaige.Tool.Idempotency

  defmodule JournalStore do
    use Agent

    def start_link(_opts), do: Agent.start_link(fn -> %{intents: []} end, name: __MODULE__)

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

    def intents, do: Agent.get(__MODULE__, & &1.intents)
  end

  defmodule FailingStore do
    def record_tool_intent(_intent, _audit_events), do: {:error, :store_down}
  end

  defmodule ResultFailingStore do
    def record_tool_intent(_intent, _audit_events), do: :ok
    def record_tool_result(_result, _audit_events), do: {:error, :store_down}
  end

  defmodule SendTool do
    @behaviour Twelvgaige.Tool

    def name, do: "send_tool"
    def description, do: "sends to parent"
    def input_schema, do: %{"type" => "object", "additionalProperties" => true}
    def safety_level, do: :idempotent_write
    def idempotency, do: Idempotency.idempotent(requires_key?: true)

    def execute(input, opts) do
      send(Keyword.fetch!(opts, :parent), {:tool_executed, input})
      {:ok, %{"ok" => true}}
    end
  end

  defmodule TestCatalog do
    def fetch("send_tool"), do: {:ok, SendTool}
  end

  setup do
    start_supervised!(JournalStore)
    :ok
  end

  test "records tool intent before executing a tool" do
    input = %{"idempotency_key" => "key-1"}

    assert {:ok, %{"ok" => true}} =
             Executor.execute("send_tool", input,
               allowed_tools: ["send_tool"],
               max_safety: :idempotent_write,
               catalog: TestCatalog,
               store: JournalStore,
               limiter: nil,
               context: %{
                 round_id: "round_1",
                 shot_id: "apply",
                 attempt: 1,
                 tool_call_id: "call_1"
               },
               tool_opts: [parent: self()]
             )

    assert_receive {:tool_executed, ^input}

    assert [
             {:intent,
              %{
                id: "call_1",
                round_id: "round_1",
                shot_id: "apply",
                attempt: 1,
                tool_name: "send_tool",
                idempotency_key: "key-1"
              }, [%{event_type: :tool_intent_recorded}]},
             {:result,
              %{
                id: "call_1",
                round_id: "round_1",
                shot_id: "apply",
                attempt: 1,
                tool_name: "send_tool",
                status: :observed_result
              }, [%{event_type: :tool_result_recorded}]}
           ] = JournalStore.intents()
  end

  test "does not execute when tool intent cannot be recorded" do
    assert {:error, error} =
             Executor.execute("send_tool", %{},
               allowed_tools: ["send_tool"],
               max_safety: :idempotent_write,
               catalog: TestCatalog,
               store: FailingStore,
               limiter: nil,
               context: %{
                 round_id: "round_1",
                 shot_id: "apply",
                 attempt: 1,
                 tool_call_id: "call_1"
               },
               tool_opts: [parent: self()]
             )

    assert error.class == :store_error
    assert error.reason == :store_unavailable
    refute_receive {:tool_executed, _input}
  end

  test "returns a store error when tool result cannot be recorded after execution" do
    assert {:error, error} =
             Executor.execute("send_tool", %{},
               allowed_tools: ["send_tool"],
               max_safety: :idempotent_write,
               catalog: TestCatalog,
               store: ResultFailingStore,
               limiter: nil,
               context: %{
                 round_id: "round_1",
                 shot_id: "apply",
                 attempt: 1,
                 tool_call_id: "call_1"
               },
               tool_opts: [parent: self()]
             )

    assert_receive {:tool_executed, %{}}
    assert error.class == :store_error
    assert error.reason == :store_unavailable
  end
end
