events_path =
  System.get_env("TWELVGAIGE_FAULT_EVIDENCE_EVENTS") ||
    raise "TWELVGAIGE_FAULT_EVIDENCE_EVENTS is required"

evidence_path =
  System.get_env("TWELVGAIGE_FAULT_EVIDENCE") ||
    Path.expand("qualification/evidence/lifecycle/fault-matrix.json")

case Twelvgaige.Lifecycle.FaultEvidence.compile(events_path, evidence_path) do
  {:ok, evidence} ->
    IO.puts(Jason.encode!(evidence, pretty: true))

  {:error, reason} ->
    raise "fault-matrix qualification failed: #{inspect(reason)}"
end
