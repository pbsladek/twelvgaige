defmodule Twelvgaige.Manager.PrimitivesTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.{Handoff, Manager.Primitives}

  test "map is bounded and reduce is deterministic by typed result id" do
    assert {:error, {:manager_fanout_exceeded, 3, 2}} =
             Primitives.map([:a, :b, :c], 2, fn item, index -> {index, item} end)

    assert {:ok, [%{id: "a"}, %{id: "b"}]} =
             Primitives.map(["a", "b"], 2, fn item, _index -> %{id: item} end)

    assert {:ok, "ab"} =
             Primitives.reduce([%{id: "b"}, %{id: "a"}], "", fn result, acc ->
               acc <> result.id
             end)
  end

  test "quorum reports disagreement and independent verifier is mandatory" do
    assert {:ok, %{votes: 2, disagreement: true}} =
             Primitives.quorum([%{answer: 1}, %{answer: 1}, %{answer: 2}])

    handoff =
      Handoff.new(%{
        objective_status: :complete,
        summary: "done",
        workspace_id: "ws",
        base_commit: "abc",
        claims: [%{claim: "tests pass", evidence: "artifact:test"}]
      })

    assert {:error, :manager_verifier_not_independent} =
             Primitives.verify(handoff, "worker", "worker", fn _handoff -> {:ok, %{}} end)

    assert {:ok, %{status: :verified, verifier: "reviewer"}} =
             Primitives.verify(handoff, "worker", "reviewer", fn _handoff ->
               {:ok, %{test_artifact: "artifact:test"}}
             end)
  end

  test "run_workflow accepts only a registered workflow" do
    runner = fn workflow, input -> {:ok, {workflow, input}} end

    assert {:ok, {:definition, :input}} =
             Primitives.run_workflow("verify", %{"verify" => :definition}, :input, runner)

    assert {:error, {:manager_workflow_unregistered, "deploy"}} =
             Primitives.run_workflow("deploy", %{}, :input, runner)
  end
end
