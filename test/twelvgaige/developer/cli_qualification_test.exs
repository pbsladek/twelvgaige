defmodule Twelvgaige.Developer.CLIQualificationTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Developer.CLIQualification

  test "requires every public command latency and enforces each ceiling" do
    limits = CLIQualification.default_limits()
    assert %{status: "pass"} = CLIQualification.evaluate(limits)

    assert %{status: "fail", checks: checks} =
             CLIQualification.evaluate(Map.put(limits, :help_ms, limits.help_ms + 1))

    assert %{metric: :help_ms, status: "fail"} =
             Enum.find(checks, &(&1.metric == :help_ms))

    assert %{status: "fail", checks: missing} = CLIQualification.evaluate(%{})
    assert Enum.all?(missing, &(&1.status == "missing"))
  end

  test "runs the public no-mutation workflow and writes complete retained evidence" do
    evidence_path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-cli-qualification-test-#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn -> File.rm(evidence_path) end)

    assert {:ok, evidence} = CLIQualification.run(evidence_path: evidence_path)
    assert evidence.status == "pass"
    assert evidence.contracts.exhaustive_command_semantic_parser_parity == "pass"
    assert evidence.contracts.complete_typed_default_inventory == "pass"
    assert evidence.contracts.saved_plan_exact_handoff == "pass"
    assert evidence.contracts.session_plan_no_mutation == "pass"

    assert {:ok, %{type: :regular, mode: mode}} = File.lstat(evidence_path)
    assert Bitwise.band(mode, 0o077) == 0

    persisted = evidence_path |> File.read!() |> Jason.decode!()
    assert persisted["status"] == "pass"
    assert persisted["contracts"]["versioned_result_envelope"] == "pass"
  end
end
