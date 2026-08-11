alias Twelvgaige.CLI.Dispatcher

shells =
  System.get_env("TWELVGAIGE_COMPLETION_SHELLS", "bash,zsh,fish")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))

temporary_root =
  Path.join(
    System.tmp_dir!(),
    "twelvgaige-completion-check-#{System.unique_integer([:positive])}"
  )

File.mkdir!(temporary_root)
File.chmod!(temporary_root, 0o700)

try do
  Enum.each(shells, fn shell ->
    executable =
      System.find_executable(shell) ||
        raise "required completion shell is unavailable: #{shell}"

    {:ok, script, 0} = Dispatcher.run(["completion", shell])
    path = Path.join(temporary_root, "twelvgaige.#{shell}")
    File.write!(path, script, [:binary, :exclusive])
    File.chmod!(path, 0o600)

    case System.cmd(executable, ["-n", path], stderr_to_stdout: true) do
      {_output, 0} -> IO.puts("#{shell} completion syntax: pass")
      {output, status} -> raise "#{shell} completion syntax failed (#{status}): #{output}"
    end
  end)
after
  File.rm_rf!(temporary_root)
end
