defmodule Twelvgaige.CLI.Burrito do
  @moduledoc """
  Burrito runtime integration for the single-file native executable.

  A Burrito executable starts the OTP application directly. The normal Mix
  release and escript paths start the application as infrastructure first, then
  invoke the CLI from their wrapper. This module keeps the Burrito-only branch
  explicit so the standard OTP supervision tree remains reusable in tests and
  bundled releases.
  """

  alias Twelvgaige.CLI.Main

  @spec maybe_start_cli() :: :ok
  def maybe_start_cli do
    if burrito_runtime?() do
      {:ok, _pid} =
        Task.start(fn ->
          Main.main_started(argv())
          System.halt(0)
        end)
    end

    :ok
  end

  @spec burrito_runtime?() :: boolean()
  def burrito_runtime? do
    Code.ensure_loaded?(Burrito.Util.Args) and
      Burrito.Util.Args.get_bin_path() != :not_in_burrito
  end

  @spec argv() :: [String.t()]
  def argv do
    Burrito.Util.Args.argv()
  end
end
