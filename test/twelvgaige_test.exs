defmodule TwelvgaigeTest do
  use ExUnit.Case, async: true

  test "version is available" do
    assert Twelvgaige.version() =~ ~r/^\d+\.\d+\.\d+$/
  end
end
