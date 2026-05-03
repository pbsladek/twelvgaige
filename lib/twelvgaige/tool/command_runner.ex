defmodule Twelvgaige.Tool.CommandRunner do
  @moduledoc """
  Default command runner for structured tool argv.

  Tests inject a function runner into tools, so normal tests do not start OS
  commands. This module is only used when a caller intentionally allows a tool
  to invoke the local executable.
  """

  alias Twelvgaige.Error

  @default_env_allowlist ~w(PATH HOME USER LOGNAME LANG LC_ALL LC_CTYPE SSL_CERT_FILE SSL_CERT_DIR KUBECONFIG)
  @default_max_output_bytes 1_048_576
  @poll_interval_ms 25

  @type result :: %{
          status: non_neg_integer(),
          stdout: String.t(),
          stderr: String.t(),
          duration_ms: non_neg_integer()
        }

  @spec run(String.t(), [String.t()], keyword()) :: {:ok, result()} | {:error, Error.t()}
  def run(binary, args, opts \\ []) when is_binary(binary) and is_list(args) do
    with {:ok, binary} <- command_binary(binary, opts),
         {:ok, policy} <- command_policy(opts) do
      timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)
      started = System.monotonic_time(:millisecond)

      if posix_port_runner?(opts) do
        run_posix_port(binary, args, policy, opts, started, timeout_ms)
      else
        run_system_cmd(binary, args, policy, opts, started, timeout_ms)
      end
    end
  end

  defp command_binary(binary, opts) do
    binary =
      opts
      |> Keyword.get(:binary_paths, %{})
      |> binary_path(binary)
      |> case do
        nil -> Keyword.get(opts, :binary_path, binary)
        path -> path
      end

    cond do
      not is_binary(binary) or binary == "" ->
        policy_error("command binary must be a non-empty string", %{binary: inspect(binary)})

      Keyword.get(opts, :require_absolute_binary?, false) and Path.type(binary) != :absolute ->
        policy_error("command binary must be an absolute path", %{binary: binary})

      true ->
        {:ok, binary}
    end
  end

  defp binary_path(paths, binary) when is_map(paths) do
    Map.get(paths, binary, Map.get(paths, existing_atom(binary)))
  rescue
    ArgumentError -> Map.get(paths, binary)
  end

  defp binary_path(paths, binary) when is_list(paths),
    do: Keyword.get(paths, existing_atom(binary))

  defp binary_path(_paths, _binary), do: nil

  defp existing_atom(binary) do
    String.to_existing_atom(binary)
  rescue
    ArgumentError -> nil
  end

  defp command_policy(opts) do
    with {:ok, cd} <- command_cwd(opts),
         {:ok, env_mods} <- command_env_mods(opts),
         {:ok, effective_env} <- effective_env(opts) do
      {:ok,
       %{
         cd: cd,
         env_mods: env_mods,
         effective_env: effective_env
       }}
    end
  end

  defp command_cwd(opts) do
    cwd = Keyword.get(opts, :cwd, Keyword.get(opts, :cd))

    cond do
      is_nil(cwd) and Keyword.get(opts, :require_cwd?, false) ->
        policy_error("command cwd is required", %{})

      is_nil(cwd) ->
        {:ok, nil}

      is_binary(cwd) and File.dir?(cwd) ->
        {:ok, Path.expand(cwd)}

      true ->
        policy_error("command cwd must be an existing directory", %{cwd: inspect(cwd)})
    end
  end

  defp command_env_mods(opts) do
    if Keyword.get(opts, :scrub_env?, true) do
      allowlist =
        opts
        |> Keyword.get(:env_allowlist, @default_env_allowlist)
        |> Enum.map(&to_string/1)
        |> MapSet.new()

      denied =
        System.get_env()
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(allowlist, &1))
        |> Enum.map(&{&1, nil})

      {:ok, denied ++ normalize_env(Keyword.get(opts, :env, []))}
    else
      {:ok, normalize_env(Keyword.get(opts, :env, []))}
    end
  rescue
    error ->
      policy_error("command environment policy is invalid", %{reason: Exception.message(error)})
  end

  defp effective_env(opts) do
    env =
      if Keyword.get(opts, :scrub_env?, true) do
        allowlist =
          opts
          |> Keyword.get(:env_allowlist, @default_env_allowlist)
          |> Enum.map(&to_string/1)
          |> MapSet.new()

        System.get_env()
        |> Enum.filter(fn {key, _value} -> MapSet.member?(allowlist, key) end)
      else
        System.get_env()
      end

    {:ok, merge_env(env, normalize_env(Keyword.get(opts, :env, [])))}
  rescue
    error ->
      policy_error("command environment policy is invalid", %{reason: Exception.message(error)})
  end

  defp normalize_env(env) when is_list(env) do
    Enum.map(env, fn {key, value} -> {to_string(key), normalize_env_value(value)} end)
  end

  defp normalize_env(_env), do: []

  defp normalize_env_value(nil), do: nil
  defp normalize_env_value(value), do: to_string(value)

  defp merge_env(base, overrides) do
    base
    |> Enum.reduce(%{}, fn {key, value}, acc -> Map.put(acc, to_string(key), to_string(value)) end)
    |> then(fn env ->
      Enum.reduce(overrides, env, fn
        {key, nil}, acc -> Map.delete(acc, key)
        {key, value}, acc -> Map.put(acc, key, value)
      end)
    end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp run_system_cmd(binary, args, policy, opts, started, timeout_ms) do
    command_opts =
      [
        stderr_to_stdout: true,
        env: policy.env_mods
      ]
      |> maybe_put(:cd, policy.cd)

    task = Task.async(fn -> System.cmd(binary, args, command_opts) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, status}} ->
        with :ok <- ensure_output_cap(output, "", binary, opts) do
          {:ok,
           %{
             status: status,
             stdout: output,
             stderr: "",
             duration_ms: System.monotonic_time(:millisecond) - started
           }}
        end

      nil ->
        timeout_error(binary, timeout_ms)

      {:exit, reason} ->
        command_exit_error(binary, reason)
    end
  end

  defp run_posix_port(binary, args, policy, opts, started, timeout_ms) do
    try do
      with {:ok, env_binary} <- required_executable("env"),
           {:ok, sh_binary} <- required_executable("sh"),
           {:ok, temp_dir} <- create_temp_dir(),
           paths <- command_output_paths(temp_dir),
           {:ok, port_info} <-
             open_command_port(env_binary, sh_binary, binary, args, policy, paths) do
        wait_for_port(port_info, paths, binary, opts, started, timeout_ms)
      end
    after
      cleanup_temp_dir(Process.get(:twelvgaige_command_temp_dir))
      Process.delete(:twelvgaige_command_temp_dir)
    end
  end

  defp posix_port_runner?(opts) do
    Keyword.get(opts, :posix_port_runner?, match?({:unix, _name}, :os.type()))
  end

  defp required_executable(binary) do
    case System.find_executable(binary) do
      nil ->
        policy_error("required command runner helper not found", %{binary: binary})

      path ->
        {:ok, path}
    end
  end

  defp create_temp_dir do
    root = System.tmp_dir!()
    name = "twelvgaige-command-#{System.unique_integer([:positive, :monotonic])}"
    path = Path.join(root, name)

    case File.mkdir(path) do
      :ok ->
        Process.put(:twelvgaige_command_temp_dir, path)
        {:ok, path}

      {:error, reason} ->
        {:error,
         Error.new(:tool_error, :tool_retryable, "failed to create command temp directory",
           retryable: true,
           details: %{reason: inspect(reason)}
         )}
    end
  end

  defp command_output_paths(temp_dir) do
    %{
      stdout: Path.join(temp_dir, "stdout"),
      stderr: Path.join(temp_dir, "stderr")
    }
  end

  defp open_command_port(env_binary, sh_binary, binary, args, policy, paths) do
    shell_script = "exec \"$@\" >\"$TWELVGAIGE_STDOUT_FILE\" 2>\"$TWELVGAIGE_STDERR_FILE\""

    env_assignments =
      (policy.effective_env ++
         [
           {"TWELVGAIGE_STDOUT_FILE", paths.stdout},
           {"TWELVGAIGE_STDERR_FILE", paths.stderr}
         ])
      |> Enum.map(fn {key, value} -> "#{key}=#{value}" end)

    command_args =
      ["-i"] ++
        env_assignments ++
        [
          sh_binary,
          "-c",
          shell_script,
          "twelvgaige-command",
          binary | Enum.map(args, &to_string/1)
        ]

    {executable, port_args, process_group?} =
      case waitable_setsid() do
        nil -> {env_binary, command_args, false}
        setsid -> {setsid, ["--wait", env_binary | command_args], true}
      end

    port_opts =
      [
        :binary,
        :exit_status,
        {:args, port_args}
      ]
      |> maybe_put(:cd, policy.cd)

    port = Port.open({:spawn_executable, executable}, port_opts)

    {:ok,
     %{
       port: port,
       os_pid: port_os_pid(port),
       process_group?: process_group?
     }}
  rescue
    error ->
      {:error,
       Error.new(:tool_error, :tool_retryable, "failed to start command",
         retryable: true,
         details: %{binary: binary, reason: Exception.message(error)}
       )}
  end

  defp waitable_setsid do
    with setsid when is_binary(setsid) <- System.find_executable("setsid"),
         {help, _status} <- System.cmd(setsid, ["--help"], stderr_to_stdout: true),
         true <- String.contains?(help, "--wait") do
      setsid
    else
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} when is_integer(pid) -> pid
      _other -> nil
    end
  end

  defp wait_for_port(port_info, paths, binary, opts, started, timeout_ms) do
    deadline = started + timeout_ms

    receive do
      {port, {:exit_status, status}} when port == port_info.port ->
        with :ok <- ensure_stream_caps(paths, binary, opts),
             {:ok, stdout} <- read_output(paths.stdout, binary, :stdout),
             {:ok, stderr} <- read_output(paths.stderr, binary, :stderr),
             :ok <- ensure_output_cap(stdout, stderr, binary, opts) do
          {:ok,
           %{
             status: status,
             stdout: stdout,
             stderr: stderr,
             duration_ms: System.monotonic_time(:millisecond) - started
           }}
        end

      {port, {:data, _data}} when port == port_info.port ->
        wait_for_port(port_info, paths, binary, opts, started, timeout_ms)
    after
      poll_delay(deadline) ->
        cond do
          System.monotonic_time(:millisecond) >= deadline ->
            terminate_port(port_info)
            timeout_error(binary, timeout_ms)

          stream_caps_exceeded?(paths, opts) ->
            terminate_port(port_info)
            output_cap_error(paths, binary, opts)

          true ->
            wait_for_port(port_info, paths, binary, opts, started, timeout_ms)
        end
    end
  end

  defp poll_delay(deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    min(remaining, @poll_interval_ms)
  end

  defp terminate_port(%{process_group?: true, os_pid: pid, port: port}) when is_integer(pid) do
    signal_process_group(pid, "TERM")
    Process.sleep(25)
    signal_process_group(pid, "KILL")
    close_port(port)
  end

  defp terminate_port(%{port: port}) do
    close_port(port)
  end

  defp signal_process_group(pid, signal) do
    case System.find_executable("kill") do
      nil -> :ok
      kill -> System.cmd(kill, ["-#{signal}", "-#{pid}"], stderr_to_stdout: true)
    end

    :ok
  rescue
    _error -> :ok
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _error -> :ok
  end

  defp stream_caps_exceeded?(paths, opts) do
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)
    max_stdout_bytes = Keyword.get(opts, :max_stdout_bytes, max_output_bytes)
    max_stderr_bytes = Keyword.get(opts, :max_stderr_bytes, max_output_bytes)

    cap_exceeded?(output_size(paths.stdout) + output_size(paths.stderr), max_output_bytes) or
      cap_exceeded?(output_size(paths.stdout), max_stdout_bytes) or
      cap_exceeded?(output_size(paths.stderr), max_stderr_bytes)
  end

  defp ensure_stream_caps(paths, binary, opts) do
    if stream_caps_exceeded?(paths, opts) do
      output_cap_error(paths, binary, opts)
    else
      :ok
    end
  end

  defp output_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      {:error, _reason} -> 0
    end
  end

  defp read_output(path, binary, stream) do
    case File.read(path) do
      {:ok, output} ->
        {:ok, output}

      {:error, :enoent} ->
        {:ok, ""}

      {:error, reason} ->
        {:error,
         Error.new(:tool_error, :tool_retryable, "failed to read command output",
           retryable: true,
           details: %{binary: binary, stream: stream, reason: inspect(reason)}
         )}
    end
  end

  defp ensure_output_cap(stdout, stderr, binary, opts) do
    output = stdout <> stderr
    max_output_bytes = Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)

    if is_integer(max_output_bytes) and max_output_bytes > 0 and
         byte_size(output) > max_output_bytes do
      {:error,
       Error.new(:output_error, :output_too_large, "command output exceeded byte limit",
         details: %{binary: binary, bytes: byte_size(output), max_output_bytes: max_output_bytes}
       )}
    else
      :ok
    end
  end

  defp cap_exceeded?(size, cap) when is_integer(cap) and cap > 0, do: size > cap
  defp cap_exceeded?(_size, _cap), do: false

  defp max_output_bytes(opts), do: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes)

  defp output_cap_error(paths, binary, opts) do
    {:error,
     Error.new(:output_error, :output_too_large, "command output exceeded byte limit",
       details: %{
         binary: binary,
         stdout_bytes: output_size(paths.stdout),
         stderr_bytes: output_size(paths.stderr),
         max_output_bytes: max_output_bytes(opts),
         max_stdout_bytes: Keyword.get(opts, :max_stdout_bytes, max_output_bytes(opts)),
         max_stderr_bytes: Keyword.get(opts, :max_stderr_bytes, max_output_bytes(opts))
       }
     )}
  end

  defp timeout_error(binary, timeout_ms) do
    {:error,
     Error.new(:tool_error, :tool_timeout, "command execution timed out",
       retryable: true,
       details: %{binary: binary, timeout_ms: timeout_ms}
     )}
  end

  defp command_exit_error(binary, reason) do
    {:error,
     Error.new(:tool_error, :tool_retryable, "command execution failed",
       retryable: true,
       details: %{binary: binary, reason: Exception.format_exit(reason)}
     )}
  end

  defp cleanup_temp_dir(nil), do: :ok
  defp cleanup_temp_dir(path), do: File.rm_rf(path)

  defp policy_error(message, details) do
    {:error,
     Error.new(:policy_error, :policy_denied, message,
       safety_required: true,
       details: details
     )}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
