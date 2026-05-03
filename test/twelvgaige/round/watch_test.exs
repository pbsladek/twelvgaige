defmodule Twelvgaige.Round.WatchTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Watch

  defmodule Source do
    def list_round_events(_round_id, opts), do: events(opts)
    def await_round_events(_round_id, opts), do: events(opts)

    def get_round(_round_id, opts) do
      opts
      |> Keyword.fetch!(:agent)
      |> Agent.get(fn state -> %{status: state.status} end)
      |> then(&{:ok, &1})
    end

    defp events(opts) do
      after_seq = Keyword.get(opts, :after_seq, 0)
      limit = Keyword.get(opts, :limit, 100)

      opts
      |> Keyword.fetch!(:agent)
      |> Agent.get(fn state ->
        state.events
        |> Enum.filter(&((&1.seq || 0) > after_seq))
        |> Enum.sort_by(& &1.seq)
        |> Enum.take(limit)
      end)
      |> then(&{:ok, &1})
    end
  end

  test "streams follow batches incrementally without accumulating all events first" do
    parent = self()
    event_1 = event(1, :round_awaiting_safety, "awaiting_safety")
    event_2 = event(2, :round_completed, "complete")

    {:ok, agent} = Agent.start(fn -> %{events: [event_1], status: :running} end)
    on_exit(fn -> Agent.stop(agent) end)

    handler = fn events ->
      seqs = Enum.map(events, & &1.seq)
      send(parent, {:batch, seqs})

      case seqs do
        [1] ->
          Agent.update(agent, &%{&1 | events: [event_1, event_2]})

        [2] ->
          Agent.update(agent, &%{&1 | status: :complete})
      end

      :ok
    end

    assert {:ok, %{after_seq: 2, delivered: 2}} =
             Watch.stream("round_watch_stream", handler,
               source: Source,
               source_opts: [agent: agent],
               follow?: true,
               until_terminal?: true,
               limit: 10,
               timeout_ms: 0
             )

    assert_received {:batch, [1]}
    assert_received {:batch, [2]}
  end

  test "stream can be halted by the consumer" do
    {:ok, agent} =
      Agent.start(fn ->
        %{events: [event(1, :round_completed, "complete")], status: :complete}
      end)

    on_exit(fn -> Agent.stop(agent) end)

    assert {:halt, :consumer_closed} =
             Watch.stream("round_watch_halt", fn _events -> {:halt, :consumer_closed} end,
               source: Source,
               source_opts: [agent: agent]
             )
  end

  test "stream returns zero delivered events when replay is empty and not following" do
    {:ok, agent} = Agent.start(fn -> %{events: [], status: :running} end)
    on_exit(fn -> Agent.stop(agent) end)

    assert {:ok, %{after_seq: 0, delivered: 0, fetches: 1}} =
             Watch.stream("round_watch_empty", fn _events -> flunk("unexpected batch") end,
               source: Source,
               source_opts: [agent: agent],
               follow?: false
             )
  end

  defp event(seq, type, status) do
    Event.new(
      round_id: "round_watch_stream",
      seq: seq,
      event_type: type,
      payload: %{"status" => status}
    )
  end
end
