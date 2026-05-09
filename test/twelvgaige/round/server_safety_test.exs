defmodule Twelvgaige.Round.ServerSafetyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Twelvgaige.Round.ServerSafety
  alias Twelvgaige.Round.State, as: RoundState

  property "approval aliases normalize to approved decisions" do
    check all(decision <- StreamData.member_of([:approve, :approved, "approve", "approved"])) do
      assert {:approved, nil, "system"} = ServerSafety.normalize_decision(decision)
    end
  end

  property "rejection aliases normalize to rejected decisions" do
    check all(decision <- StreamData.member_of([:reject, :rejected, "reject", "rejected"])) do
      assert {:rejected, nil, "system"} = ServerSafety.normalize_decision(decision)
    end
  end

  test "decision uses explicit per-shot overrides before awaiting" do
    request = %{"shot_id" => "gate"}

    assert {:approved, "checked", "system"} =
             ServerSafety.decision(request, safety_decisions: %{"gate" => {:approved, "checked"}})

    assert :await = ServerSafety.decision(request, safety_decisions: %{"other" => :approved})
  end

  test "decision supports arity-two handlers" do
    request = %{"shot_id" => "gate"}

    handler = fn shot_id, req ->
      assert shot_id == "gate"
      assert req == request
      %{decision: :reject, reason: "unsafe", actor: "reviewer"}
    end

    assert {:rejected, "unsafe", "reviewer"} =
             ServerSafety.decision(request, safety_handler: handler)
  end

  test "request and output shapes are JSON-safe" do
    round_state =
      RoundState.new(
        id: "round_1",
        shell_id: "shell",
        shell_version: "1.0.0",
        policy: %{safety_scope: :round}
      )

    shot = %{id: "gate", description: "approve remediation"}

    assert %{
             "round_id" => "round_1",
             "shot_id" => "gate",
             "status" => "awaiting",
             "scope" => "round",
             "reason" => "approve remediation",
             "requested_at" => requested_at
           } = ServerSafety.request(round_state, shot)

    assert {:ok, _requested_at, _offset} = DateTime.from_iso8601(requested_at)

    assert %{
             "decision" => "approved",
             "reason" => "reviewed",
             "actor" => "human",
             "decided_at" => decided_at
           } = ServerSafety.output("approved", "reviewed", "human")

    assert {:ok, _decided_at, _offset} = DateTime.from_iso8601(decided_at)
  end

  test "rejected round status follows workflow policy" do
    assert :halted =
             ServerSafety.rejected_round_status(
               RoundState.new(id: "round_1", shell_id: "shell", shell_version: "1")
             )

    assert :failed =
             ServerSafety.rejected_round_status(
               RoundState.new(
                 id: "round_1",
                 shell_id: "shell",
                 shell_version: "1",
                 policy: %{on_safety_reject: :fail_round}
               )
             )
  end
end
