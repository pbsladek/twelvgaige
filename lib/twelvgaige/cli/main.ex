defmodule Twelvgaige.CLI.Main do
  @moduledoc """
  Command-line entrypoint for Twelvgaige.
  """

  alias Twelvgaige.CLI.Dispatcher
  alias Twelvgaige.CLI.EscriptPriv

  @spec main([String.t()]) :: :ok
  def main(args) do
    start_runtime!()
    main_started(args)
  end

  @spec main_started([String.t()]) :: :ok
  def main_started(args) do
    Dispatcher.dispatch(args)
  end

  @spec run([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def run(args), do: Dispatcher.run(args)

  defp start_runtime! do
    with :ok <- EscriptPriv.prepare(),
         {:ok, _apps} <- Application.ensure_all_started(:twelvgaige) do
      :ok
    else
      {:error, reason} ->
        IO.write(:stderr, "failed to start twelvgaige: #{inspect(reason)}\n")
        System.halt(8)
    end
  end
end
