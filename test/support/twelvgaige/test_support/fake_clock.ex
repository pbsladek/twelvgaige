defmodule Twelvgaige.TestSupport.FakeClock do
  @moduledoc """
  Deterministic Agent-backed clock for tests that need stable timestamps.
  """

  @behaviour Twelvgaige.Clock

  @default_now ~U[2026-01-02 03:04:05.123456Z]

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      now: Keyword.get(opts, :now, @default_now),
      monotonic_ms: Keyword.get(opts, :monotonic_ms, 0)
    }

    Agent.start_link(fn -> state end, name: name)
  end

  def set_now(now, name \\ __MODULE__) do
    Agent.update(name, &%{&1 | now: now})
  end

  def advance(milliseconds, name \\ __MODULE__) when is_integer(milliseconds) do
    Agent.update(name, fn state ->
      %{
        state
        | now: DateTime.add(state.now, milliseconds, :millisecond),
          monotonic_ms: state.monotonic_ms + milliseconds
      }
    end)
  end

  @impl true
  def utc_now do
    Agent.get(__MODULE__, & &1.now)
  end

  @impl true
  def monotonic_time(unit) do
    __MODULE__
    |> Agent.get(& &1.monotonic_ms)
    |> System.convert_time_unit(:millisecond, unit)
  end
end
