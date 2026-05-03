defmodule Twelvgaige.RuntimeProfileEnvTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.RuntimeProfile

  test "uses TWELVGAIGE_PROFILE as the process default" do
    previous = System.get_env("TWELVGAIGE_PROFILE")

    on_exit(fn ->
      if previous do
        System.put_env("TWELVGAIGE_PROFILE", previous)
      else
        System.delete_env("TWELVGAIGE_PROFILE")
      end
    end)

    System.put_env("TWELVGAIGE_PROFILE", "minimal")

    assert RuntimeProfile.default() == "minimal"
    assert RuntimeProfile.effective(nil, max_profile: :server) == {:ok, :minimal}
  end
end
