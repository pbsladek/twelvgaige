defmodule Twelvgaige.CLI.BurritoTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Burrito

  test "normal Mix and test runs are not treated as Burrito runtime" do
    refute Burrito.burrito_runtime?()
  end
end
