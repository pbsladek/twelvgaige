defmodule Twelvgaige.TestSupport.FakeCommandRunner do
  @moduledoc """
  Capturing command runner for tool tests.

  Use `runner/1` where a tool expects a `command_runner` function. Each call is
  recorded without starting an OS command and responses are returned in FIFO
  order.
  """

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
      calls: [],
      responses: Keyword.get(opts, :responses, [])
    }

    Agent.start_link(fn -> state end, name: name)
  end

  def runner(name \\ __MODULE__) do
    fn binary, args, opts -> run(name, binary, args, opts) end
  end

  def calls(name \\ __MODULE__) do
    Agent.get(name, fn state -> Enum.reverse(state.calls) end)
  end

  def run(name \\ __MODULE__, binary, args, opts)
      when is_binary(binary) and is_list(args) and is_list(opts) do
    call = %{binary: binary, args: args, opts: opts}

    Agent.get_and_update(name, fn state ->
      {response, responses} = next_response(state.responses, call)
      {response, %{state | calls: [call | state.calls], responses: responses}}
    end)
  end

  defp next_response([response | rest], call), do: {resolve_response(response, call), rest}

  defp next_response([], _call) do
    {{:ok, %{status: 0, stdout: "", stderr: "", duration_ms: 0}}, []}
  end

  defp resolve_response(response, call) when is_function(response, 1), do: response.(call)
  defp resolve_response(response, _call), do: response
end
