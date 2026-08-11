alias Twelvgaige.Developer.MigrationQualification

evidence_path =
  System.get_env("TWELVGAIGE_MIGRATION_EVIDENCE") ||
    Path.expand("qualification/evidence/migrations/previous-release.json")

case MigrationQualification.run(evidence_path: evidence_path) do
  {:ok, evidence} ->
    IO.puts(Jason.encode!(evidence, pretty: true))

  {:error, reason} ->
    IO.puts(:stderr, "Previous-release migration qualification failed: #{inspect(reason)}")
    System.halt(1)
end
