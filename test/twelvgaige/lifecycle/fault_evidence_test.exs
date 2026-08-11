defmodule Twelvgaige.Lifecycle.FaultEvidenceTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Lifecycle.{FaultEvidence, FaultMatrix}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-fault-evidence-#{System.unique_integer([:positive])}"
      )

    events = Path.join(root, "events")
    previous = System.get_env("TWELVGAIGE_FAULT_EVIDENCE_EVENTS")
    System.put_env("TWELVGAIGE_FAULT_EVIDENCE_EVENTS", events)

    on_exit(fn ->
      File.rm_rf(root)

      if previous,
        do: System.put_env("TWELVGAIGE_FAULT_EVIDENCE_EVENTS", previous),
        else: System.delete_env("TWELVGAIGE_FAULT_EVIDENCE_EVENTS")
    end)

    %{root: root, events: events}
  end

  test "qualification requires one exact passing record for every declared case", context do
    for fault_case <- FaultMatrix.cases() do
      assert :ok =
               FaultEvidence.record_case(fault_case.id, :safe_resume, %{suite: "evidence_test"})
    end

    destination = Path.join(context.root, "fault-matrix.json")
    assert {:ok, evidence} = FaultEvidence.compile(context.events, destination)
    assert evidence.qualified
    assert evidence.case_count == MapSet.size(FaultMatrix.case_ids())
    assert File.regular?(destination)

    [missing | _rest] = FaultMatrix.cases()
    File.rm!(Path.join(context.events, missing.id <> ".json"))

    assert {:error, {:fault_evidence_cases_incomplete, report}} =
             FaultEvidence.compile(context.events, destination)

    assert report.missing == [missing.id]
    assert report.unknown == []
  end

  test "a repeated case is idempotent only when its evidence is identical", _context do
    case_id = FaultMatrix.cases() |> hd() |> Map.fetch!(:id)
    metadata = %{suite: "evidence_test"}

    assert :ok = FaultEvidence.record_case(case_id, :safe_resume, metadata)
    assert :ok = FaultEvidence.record_case(case_id, :safe_resume, metadata)

    assert {:error, {:fault_evidence_case_conflict, ^case_id}} =
             FaultEvidence.record_case(case_id, :needs_reconciliation, metadata)
  end
end
