alias Twelvgaige.Developer.CLIQualification

path =
  System.get_env("TWELVGAIGE_CLI_QUALIFICATION_EVIDENCE") ||
    Path.expand("qualification/evidence/cli/developer-workflow.json")

case CLIQualification.run(evidence_path: path) do
  {:ok, evidence} ->
    IO.puts(Jason.encode!(evidence, pretty: true))

  {:error, reason} ->
    IO.puts(:stderr, "Developer CLI qualification failed: #{inspect(reason)}")
    System.halt(1)
end
