defmodule Twelvgaige.Round.Watch do
  @moduledoc """
  Cursor-based round event collection for CLI and API watch surfaces.

  The store owns event durability and notification. This module owns the
  client-facing follow loop: replay committed events, optionally wait for the
  next batch, advance by round-event sequence, and stop at explicit bounds.
  """

  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot

  @default_after_seq 0
  @default_limit 100
  @default_timeout_ms 30_000
  @default_max_fetches 100

  @type source :: module()

  @type collect_option ::
          {:after_seq, non_neg_integer()}
          | {:limit, pos_integer()}
          | {:follow?, boolean()}
          | {:until_terminal?, boolean()}
          | {:timeout_ms, non_neg_integer()}
          | {:max_fetches, pos_integer()}
          | {:source, source()}
          | {:source_opts, keyword()}

  @type stream_result :: %{
          after_seq: non_neg_integer(),
          delivered: non_neg_integer(),
          fetches: non_neg_integer()
        }

  @type stream_handler :: ([Event.t()] -> :ok | {:halt, term()} | {:error, term()})

  @spec collect(String.t(), [collect_option()]) :: {:ok, [Event.t()]} | {:error, term()}
  def collect(round_id, opts \\ []) when is_binary(round_id) and is_list(opts) do
    opts = normalize_opts(opts)

    do_collect(round_id, opts, %{
      after_seq: opts.after_seq,
      remaining: opts.limit,
      fetches: 0,
      terminal_event_seen?: false,
      events: []
    })
  end

  @spec stream(String.t(), stream_handler(), [collect_option()]) ::
          {:ok, stream_result()} | {:error, term()} | {:halt, term()}
  def stream(round_id, handler, opts \\ [])
      when is_binary(round_id) and is_function(handler, 1) and is_list(opts) do
    opts = normalize_opts(opts)

    do_stream(
      round_id,
      opts,
      %{
        after_seq: opts.after_seq,
        remaining: opts.limit,
        fetches: 0,
        terminal_event_seen?: false,
        delivered: 0
      },
      handler
    )
  end

  defp do_collect(_round_id, _opts, %{remaining: remaining, events: events})
       when remaining <= 0 do
    {:ok, Enum.reverse(events)}
  end

  defp do_collect(_round_id, opts, %{fetches: fetches, events: events})
       when fetches >= opts.max_fetches do
    {:ok, Enum.reverse(events)}
  end

  defp do_collect(round_id, opts, state) do
    case list_events(round_id, opts, state) do
      {:ok, []} ->
        state = increment_fetches(state)
        maybe_await(round_id, opts, state)

      {:ok, events} ->
        state =
          state
          |> increment_fetches()
          |> append_events(events)

        maybe_continue_after_events(round_id, opts, state)

      {:error, _reason} = error ->
        error
    end
  end

  defp do_stream(_round_id, _opts, %{remaining: remaining} = state, _handler)
       when remaining <= 0 do
    {:ok, stream_result(state)}
  end

  defp do_stream(_round_id, opts, %{fetches: fetches} = state, _handler)
       when fetches >= opts.max_fetches do
    {:ok, stream_result(state)}
  end

  defp do_stream(round_id, opts, state, handler) do
    case list_events(round_id, opts, state) do
      {:ok, []} ->
        state = increment_fetches(state)
        stream_maybe_await(round_id, opts, state, handler)

      {:ok, events} ->
        with {:ok, state} <- deliver_events(state, events, handler) do
          state = increment_fetches(state)
          stream_maybe_continue_after_events(round_id, opts, state, handler)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_await(_round_id, %{follow?: false}, %{events: events}) do
    {:ok, Enum.reverse(events)}
  end

  defp maybe_await(_round_id, opts, %{fetches: fetches, events: events})
       when fetches >= opts.max_fetches do
    {:ok, Enum.reverse(events)}
  end

  defp maybe_await(round_id, %{until_terminal?: true} = opts, state) do
    with {:ok, false} <- terminal?(round_id, opts) do
      await_events(round_id, opts, state)
    else
      {:ok, true} when state.terminal_event_seen? -> {:ok, Enum.reverse(state.events)}
      {:ok, true} -> do_collect(round_id, opts, state)
      {:error, _reason} = error -> error
    end
  end

  defp maybe_await(round_id, opts, state), do: await_events(round_id, opts, state)

  defp stream_maybe_await(_round_id, %{follow?: false}, state, _handler) do
    {:ok, stream_result(state)}
  end

  defp stream_maybe_await(_round_id, opts, %{fetches: fetches} = state, _handler)
       when fetches >= opts.max_fetches do
    {:ok, stream_result(state)}
  end

  defp stream_maybe_await(round_id, %{until_terminal?: true} = opts, state, handler) do
    with {:ok, false} <- terminal?(round_id, opts) do
      stream_await_events(round_id, opts, state, handler)
    else
      {:ok, true} when state.terminal_event_seen? -> {:ok, stream_result(state)}
      {:ok, true} -> do_stream(round_id, opts, state, handler)
      {:error, _reason} = error -> error
    end
  end

  defp stream_maybe_await(round_id, opts, state, handler),
    do: stream_await_events(round_id, opts, state, handler)

  defp await_events(round_id, opts, state) do
    case source_call(opts.source, :await_round_events, round_id, event_opts(opts, state)) do
      {:ok, []} ->
        {:ok, Enum.reverse(state.events)}

      {:ok, events} ->
        state =
          state
          |> increment_fetches()
          |> append_events(events)

        maybe_continue_after_events(round_id, opts, state)

      {:error, _reason} = error ->
        error
    end
  end

  defp stream_await_events(round_id, opts, state, handler) do
    case source_call(opts.source, :await_round_events, round_id, event_opts(opts, state)) do
      {:ok, []} ->
        {:ok, stream_result(state)}

      {:ok, events} ->
        with {:ok, state} <- deliver_events(state, events, handler) do
          state = increment_fetches(state)
          stream_maybe_continue_after_events(round_id, opts, state, handler)
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp maybe_continue_after_events(_round_id, %{follow?: false}, %{events: events}) do
    {:ok, Enum.reverse(events)}
  end

  defp maybe_continue_after_events(_round_id, %{until_terminal?: false}, %{events: events}) do
    {:ok, Enum.reverse(events)}
  end

  defp maybe_continue_after_events(round_id, opts, state) do
    with {:ok, terminal?} <- terminal?(round_id, opts) do
      if terminal? and state.terminal_event_seen? do
        {:ok, Enum.reverse(state.events)}
      else
        do_collect(round_id, opts, state)
      end
    end
  end

  defp stream_maybe_continue_after_events(_round_id, %{follow?: false}, state, _handler) do
    {:ok, stream_result(state)}
  end

  defp stream_maybe_continue_after_events(_round_id, %{until_terminal?: false}, state, _handler) do
    {:ok, stream_result(state)}
  end

  defp stream_maybe_continue_after_events(round_id, opts, state, handler) do
    with {:ok, terminal?} <- terminal?(round_id, opts) do
      if terminal? and state.terminal_event_seen? do
        {:ok, stream_result(state)}
      else
        do_stream(round_id, opts, state, handler)
      end
    end
  end

  defp list_events(round_id, opts, state) do
    case source_call(opts.source, :list_round_events, round_id, event_opts(opts, state)) do
      {:ok, events} -> {:ok, events}
      {:error, _reason} = error -> error
    end
  end

  defp terminal?(round_id, opts) do
    case source_call(opts.source, :get_round, round_id, opts.source_opts) do
      {:ok, %Snapshot{} = snapshot} -> {:ok, Snapshot.terminal?(snapshot)}
      {:ok, %{status: status}} -> {:ok, status in Twelvgaige.Round.State.terminal_statuses()}
      {:error, _reason} = error -> error
    end
  end

  defp event_opts(opts, state) do
    opts.source_opts
    |> Keyword.put(:after_seq, state.after_seq)
    |> Keyword.put(:limit, state.remaining)
    |> Keyword.put(:timeout_ms, opts.timeout_ms)
  end

  defp append_events(state, events) do
    events = Enum.sort_by(events, &(event_seq(&1) || 0))

    %{
      state
      | after_seq: max_seq(state.after_seq, events),
        remaining: state.remaining - length(events),
        terminal_event_seen?: state.terminal_event_seen? or Enum.any?(events, &terminal_event?/1),
        events: Enum.reverse(events) ++ state.events
    }
  end

  defp deliver_events(state, events, handler) do
    events = Enum.sort_by(events, &(event_seq(&1) || 0))

    case handler.(events) do
      :ok ->
        {:ok,
         %{
           state
           | after_seq: max_seq(state.after_seq, events),
             remaining: state.remaining - length(events),
             terminal_event_seen?:
               state.terminal_event_seen? or Enum.any?(events, &terminal_event?/1),
             delivered: state.delivered + length(events)
         }}

      {:halt, reason} ->
        {:halt, reason}

      {:error, _reason} = error ->
        error

      other ->
        {:error, {:invalid_watch_stream_handler_result, other}}
    end
  end

  defp max_seq(after_seq, events) do
    Enum.reduce(events, after_seq, fn event, acc ->
      max(acc, event_seq(event) || acc)
    end)
  end

  defp event_seq(%Event{seq: seq}), do: seq
  defp event_seq(%{seq: seq}), do: seq
  defp event_seq(%{"seq" => seq}), do: seq
  defp event_seq(_event), do: nil

  defp terminal_event?(%Event{event_type: event_type}), do: terminal_event_type?(event_type)
  defp terminal_event?(%{event_type: event_type}), do: terminal_event_type?(event_type)
  defp terminal_event?(%{"event_type" => event_type}), do: terminal_event_type?(event_type)

  defp terminal_event_type?(event_type) when is_binary(event_type) do
    event_type in ~w(round_completed round_failed round_halted round_cancelled)
  end

  defp terminal_event_type?(event_type) when is_atom(event_type),
    do: terminal_event_type?(Atom.to_string(event_type))

  defp terminal_event_type?(_event_type), do: false

  defp increment_fetches(state), do: %{state | fetches: state.fetches + 1}

  defp stream_result(state) do
    %{
      after_seq: state.after_seq,
      delivered: state.delivered,
      fetches: state.fetches
    }
  end

  defp source_call(source, function, round_id, opts) do
    apply(source, function, [round_id, opts])
  end

  defp normalize_opts(opts) do
    %{
      after_seq: Keyword.get(opts, :after_seq, @default_after_seq),
      limit: Keyword.get(opts, :limit, @default_limit),
      follow?: Keyword.get(opts, :follow?, false),
      until_terminal?: Keyword.get(opts, :until_terminal?, false),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      max_fetches: Keyword.get(opts, :max_fetches, @default_max_fetches),
      source: Keyword.get(opts, :source, Twelvgaige),
      source_opts: Keyword.get(opts, :source_opts, [])
    }
  end
end
