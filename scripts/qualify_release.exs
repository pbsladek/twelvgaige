alias Twelvgaige.Operations.ReleaseGate

root = Path.expand("..", __DIR__)
report = ReleaseGate.evaluate(root, require_artifacts?: true)
destination = Path.join(root, "qualification/evidence/release-qualification.json")

evidence = %{
  schema_version: 1,
  generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
  result: if(report.status == :pass, do: "pass", else: "fail"),
  release_gate: report
}

File.write!(destination, Jason.encode_to_iodata!(evidence, pretty: true))

if report.status == :pass do
  IO.puts("Release qualification passed; evidence: #{destination}")
else
  failed =
    report.checks
    |> Enum.filter(&(&1.result.status == :fail))
    |> Enum.map(& &1.id)

  raise "Release qualification failed: #{inspect(failed)}; evidence: #{destination}"
end
