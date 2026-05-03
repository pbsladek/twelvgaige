defmodule Twelvgaige.TestSupport.FakeID do
  @moduledoc """
  Deterministic ID generator for tests.

  The fake keeps Twelvgaige's production domain prefixes and replaces the random
  suffix with a per-prefix sequence.
  """

  @behaviour Twelvgaige.ID

  def child_spec(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    %{
      id: name,
      start: {__MODULE__, :start_link, [opts]}
    }
  end

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %{} end, name: name)
  end

  def reset(name \\ __MODULE__) do
    Agent.update(name, fn _counts -> %{} end)
  end

  @impl true
  def new(prefix) do
    count =
      Agent.get_and_update(__MODULE__, fn counts ->
        next = Map.get(counts, prefix, 0) + 1
        {next, Map.put(counts, prefix, next)}
      end)

    "#{Twelvgaige.ID.prefix_slug(prefix)}_fake_#{count}"
  end
end
