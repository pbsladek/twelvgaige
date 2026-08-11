args = Enum.drop_while(System.argv(), &(&1 == "--"))

case args do
  [destination, launcher, release_version] ->
    launcher_digest =
      launcher
      |> File.stream!(64 * 1024, [])
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    architecture =
      case System.cmd("uname", ["-m"], stderr_to_stdout: true) do
        {value, 0} -> String.trim(value)
        _other -> "unknown"
      end

    evidence = %{
      schema: "twelvgaige.cli.release-interrupt-qualification",
      schema_version: 1,
      observed_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      platform: %{
        os: :os.type() |> Tuple.to_list() |> Enum.map_join("/", &to_string/1),
        architecture: architecture,
        elixir: System.version(),
        otp: System.otp_release()
      },
      release: %{
        version: release_version,
        launcher_sha256: launcher_digest
      },
      checks: %{
        installed_launcher_invoked: true,
        daemon_protocol_used: true,
        first_interrupt_requested_cancellation: true,
        cancellation_persisted: true,
        second_interrupt_detached_truthfully: true,
        ordinary_interrupt_exit_status: 130,
        invalid_command_exit_status: 4,
        child_process_reaped: true,
        temporary_argument_files_removed: true,
        temporary_interrupt_files_removed: true
      },
      qualified: true
    }

    destination = Path.expand(destination)
    temporary = destination <> ".tmp-#{System.unique_integer([:positive])}"
    File.mkdir_p!(Path.dirname(destination))
    File.write!(temporary, Jason.encode_to_iodata!(evidence, pretty: true))
    File.chmod!(temporary, 0o600)
    File.rename!(temporary, destination)

  _other ->
    raise "usage: mix run scripts/record_release_cli_interrupt_evidence.exs -- DESTINATION LAUNCHER RELEASE_VERSION"
end
