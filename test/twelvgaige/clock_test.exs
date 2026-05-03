defmodule Twelvgaige.ClockTest do
  use ExUnit.Case, async: true

  test "utc_now returns a UTC DateTime" do
    assert %DateTime{time_zone: "Etc/UTC"} = Twelvgaige.Clock.utc_now()
  end

  test "monotonic time returns an integer" do
    assert is_integer(Twelvgaige.Clock.monotonic_time())
  end
end
