defmodule Twelvgaige.TestSupportFakesConfigTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.TestSupport.FakeClock
  alias Twelvgaige.TestSupport.FakeID

  setup do
    previous_clock = Application.get_env(:twelvgaige, :clock)
    previous_id_generator = Application.get_env(:twelvgaige, :id_generator)

    on_exit(fn ->
      restore_env(:clock, previous_clock)
      restore_env(:id_generator, previous_id_generator)
    end)

    :ok
  end

  test "fake clock makes wall and monotonic time deterministic" do
    start_supervised!(FakeClock)
    Application.put_env(:twelvgaige, :clock, FakeClock)

    assert Twelvgaige.Clock.utc_now() == ~U[2026-01-02 03:04:05.123456Z]
    assert Twelvgaige.Clock.monotonic_time() == 0

    FakeClock.advance(1_500)

    assert Twelvgaige.Clock.utc_now() == ~U[2026-01-02 03:04:06.623456Z]
    assert Twelvgaige.Clock.monotonic_time() == 1_500
    assert Twelvgaige.Clock.monotonic_time(:second) == 1
  end

  test "fake ID generator keeps domain prefixes and deterministic sequences" do
    start_supervised!(FakeID)
    Application.put_env(:twelvgaige, :id_generator, FakeID)

    assert Twelvgaige.ID.new(:round) == "round_fake_1"
    assert Twelvgaige.ID.transition_id() == "tr_fake_1"
    assert Twelvgaige.ID.new(:round) == "round_fake_2"
    assert Twelvgaige.ID.new(:daemon) == "daemon_fake_1"
  end

  defp restore_env(key, nil), do: Application.delete_env(:twelvgaige, key)
  defp restore_env(key, value), do: Application.put_env(:twelvgaige, key, value)
end
