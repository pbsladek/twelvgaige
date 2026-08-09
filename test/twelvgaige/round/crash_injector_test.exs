defmodule Twelvgaige.Round.CrashInjectorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Round.CrashInjector
  alias Twelvgaige.Round.CrashInjector.InjectedCrash

  test "injects at one selected transition boundary and occurrence" do
    hook = CrashInjector.hook(stage: :after_commit, event_type: :shot_completed, occurrence: 2)
    pending = %{event_type: :shot_completed, transition_id: "tr_1"}

    assert :ok = hook.(:before_commit, pending, nil)
    assert :ok = hook.(:after_commit, pending, nil)

    assert_raise InjectedCrash, fn ->
      hook.(:after_commit, %{pending | transition_id: "tr_2"}, nil)
    end

    assert :ok = hook.(:after_commit, %{pending | transition_id: "tr_3"}, nil)
  end
end
