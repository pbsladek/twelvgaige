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
      _pid = spawn(__MODULE__, :run_started_cli, [])
    end

    :ok
  end

  @doc false
  @spec run_started_cli() :: no_return()
  def run_started_cli do
    Main.main_started(argv())
    System.halt(0)
  end

  @spec burrito_runtime?() :: boolean()
  def burrito_runtime? do
    case Code.ensure_loaded(Burrito.Util.Args) do
      {:module, module} -> apply(module, :get_bin_path, []) != :not_in_burrito
      {:error, _reason} -> false
    end
  end

  @spec argv() :: [String.t()]
  def argv do
    case Code.ensure_loaded(Burrito.Util.Args) do
      {:module, module} -> apply(module, :argv, [])
      {:error, _reason} -> []
    end
  end
end
