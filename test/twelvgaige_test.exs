defmodule TwelvgaigeTest do
  use ExUnit.Case, async: true

  test "version is available" do
    assert Twelvgaige.version() == "0.1.0"
  end
end
