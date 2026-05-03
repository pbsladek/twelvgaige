defmodule Twelvgaige.Clock do
  @moduledoc """
  Time seam for production code and tests.
  """

  @callback utc_now() :: DateTime.t()
  @callback monotonic_time(unit :: System.time_unit()) :: integer()

  @spec utc_now() :: DateTime.t()
  def utc_now do
    impl().utc_now()
  end

  @spec monotonic_time(System.time_unit()) :: integer()
  def monotonic_time(unit \\ :millisecond) do
    impl().monotonic_time(unit)
  end

  defp impl do
    Application.get_env(:twelvgaige, :clock, Twelvgaige.Clock.System)
  end
end
