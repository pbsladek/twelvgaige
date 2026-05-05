defmodule Twelvgaige.Round.SnapshotTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Round.Snapshot

  test "to_map accepts persisted string-key error maps" do
    snapshot =
      Snapshot.new(%{
        "id" => "round_rejected",
        "shell_id" => "safety_simple",
        "shell_version" => "1.0.0",
        "status" => "halted",
        "error" => %{
          "class" => "policy_error",
          "reason" => "safety_rejected",
          "message" => "safety shot approval was rejected",
          "retryable" => false,
          "safety_required" => true,
          "details" => %{"shot_id" => "approval"}
        }
      })

    assert %{
             error: %{
               class: "policy_error",
               reason: "safety_rejected",
               message: "safety shot approval was rejected",
               retryable: false,
               safety_required: true,
               details: %{"shot_id" => "approval"}
             }
           } = Snapshot.to_map(snapshot)
  end
end
