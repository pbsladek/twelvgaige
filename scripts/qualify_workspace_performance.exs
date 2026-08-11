alias Twelvgaige.Workspace.PerformanceQualification

evidence_path =
  System.get_env("TWELVGAIGE_WORKSPACE_PERF_EVIDENCE") ||
    Path.expand("qualification/evidence/workspace/performance.json")

case PerformanceQualification.run(evidence_path: evidence_path) do
  {:ok, evidence} ->
    IO.puts(Jason.encode!(evidence, pretty: true))

  {:error, reason} ->
    IO.puts(:stderr, "Workspace performance qualification failed: #{inspect(reason)}")
    System.halt(1)
end
