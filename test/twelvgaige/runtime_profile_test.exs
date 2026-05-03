defmodule Twelvgaige.RuntimeProfileTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.RuntimeProfile
  alias Twelvgaige.Round.Snapshot

  test "normalizes supported profile names and defaults nil to laptop" do
    assert RuntimeProfile.normalize(nil) == {:ok, :laptop}
    assert RuntimeProfile.normalize(:minimal) == {:ok, :minimal}
    assert RuntimeProfile.normalize(" Workstation ") == {:ok, :workstation}
    assert RuntimeProfile.names() == [:minimal, :laptop, :workstation, :server]
  end

  test "rejects unsupported profile names without atom creation" do
    assert {:error, error} = RuntimeProfile.normalize("desktop")
    assert error.class == :input_error
    assert error.reason == :invalid_shell
    assert error.details.supported_profiles == ["minimal", "laptop", "workstation", "server"]
  end

  test "computes effective profile from run overrides, workflow policy, and max profile" do
    assert RuntimeProfile.effective(%{resource_profile: :minimal}) == {:ok, :minimal}

    assert RuntimeProfile.effective(%{resource_profile: :minimal},
             profile: :server,
             max_profile: :workstation
           ) == {:ok, :workstation}

    assert RuntimeProfile.effective(%{resource_profile: :server}, max_profile: :laptop) ==
             {:ok, :laptop}
  end

  test "recovers effective profile from snapshot shape" do
    snapshot =
      Snapshot.new(
        id: "round_1",
        shell_id: "workflow",
        shell_version: "1.0.0",
        resource_profile: "workstation"
      )

    assert RuntimeProfile.from_snapshot(snapshot, max_profile: :server) == {:ok, :workstation}
    assert RuntimeProfile.from_snapshot(snapshot, max_profile: :minimal) == {:ok, :workstation}
  end

  test "provides resource limits and shot executor options for each profile" do
    assert RuntimeProfile.limits(:minimal).active_shot == 1
    assert RuntimeProfile.limits(:server).llm_call == 32

    assert RuntimeProfile.limits(:laptop, %{"llm_call" => 2, running_shot_global: 3}) ==
             %{
               active_round: 1,
               active_shot: 3,
               active_shot_per_round: 3,
               llm_call: 2,
               tool_exec: 4,
               retained_bytes: 536_870_912
             }

    opts = RuntimeProfile.shot_opts(:minimal, max_iterations: 2)

    assert opts[:max_iterations] == 2
    assert opts[:max_tool_calls_per_shot] == 1
    assert opts[:max_llm_message_bytes] == 524_288
  end
end
