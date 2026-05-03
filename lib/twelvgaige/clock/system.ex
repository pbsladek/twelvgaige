defmodule Twelvgaige.Clock.System do
  @moduledoc """
  System-backed clock implementation.
  """

  @behaviour Twelvgaige.Clock

  @impl true
  def utc_now do
    DateTime.utc_now()
  end

  @impl true
  def monotonic_time(unit) do
    System.monotonic_time(unit)
  end
end
