defmodule Twelvgaige.Tool.CommandRunnerTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Tool.CommandRunner

  @canary_env "TWELVGAIGE_COMMAND_RUNNER_CANARY"

  setup do
    previous = System.get_env(@canary_env)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env(@canary_env)
        value -> System.put_env(@canary_env, value)
      end
    end)

    %{elixir: System.find_executable("elixir")}
  end

  test "scrubs ambient environment variables by default", %{elixir: elixir} do
    System.put_env(@canary_env, "ambient-secret")

    assert {:ok, result} =
             CommandRunner.run(
               elixir,
               ["-e", env_script()],
               max_output_bytes: 128
             )

    assert result.status == 0
    assert result.stdout == "missing"
  end

  test "passes explicit trusted environment values", %{elixir: elixir} do
    assert {:ok, result} =
             CommandRunner.run(
               elixir,
               ["-e", env_script()],
               env: [{@canary_env, "trusted"}],
               max_output_bytes: 128
             )

    assert result.status == 0
    assert result.stdout == "trusted"
  end

  test "enforces output byte caps", %{elixir: elixir} do
    assert {:error, error} =
             CommandRunner.run(
               elixir,
               ["-e", ~s|IO.write(String.duplicate("x", 32))|],
               max_output_bytes: 4
             )

    assert error.class == :output_error
    assert error.reason == :output_too_large
  end

  test "captures stdout and stderr separately on POSIX", %{elixir: elixir} do
    assert {:ok, result} =
             CommandRunner.run(
               elixir,
               ["-e", ~s|IO.write("out"); IO.write(:stderr, "err")|],
               max_output_bytes: 128
             )

    assert result.status == 0
    assert result.stdout == "out"
    assert result.stderr == "err"
  end

  test "enforces stderr byte caps while command is running", %{elixir: elixir} do
    assert {:error, error} =
             CommandRunner.run(
               elixir,
               ["-e", ~s|IO.write(:stderr, String.duplicate("x", 64)); Process.sleep(1_000)|],
               max_output_bytes: 1_024,
               max_stderr_bytes: 4
             )

    assert error.class == :output_error
    assert error.reason == :output_too_large
    assert error.details.stderr_bytes > 4
  end

  test "runs commands from explicit cwd", %{elixir: elixir} do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-command-runner-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(tmp)

    on_exit(fn -> File.rm_rf(tmp) end)

    assert {:ok, result} =
             CommandRunner.run(elixir, ["-e", ~s|IO.write(File.cwd!())|],
               cwd: tmp,
               max_output_bytes: 512
             )

    assert normalize_tmp_path(result.stdout) == normalize_tmp_path(tmp)
  end

  test "times out long-running commands", %{elixir: elixir} do
    assert {:error, error} =
             CommandRunner.run(elixir, ["-e", "Process.sleep(5_000)"],
               timeout_ms: 50,
               max_output_bytes: 128
             )

    assert error.class == :tool_error
    assert error.reason == :tool_timeout
  end

  test "can require absolute command paths" do
    assert {:error, error} =
             CommandRunner.run("elixir", ["--version"], require_absolute_binary?: true)

    assert error.class == :policy_error
    assert error.reason == :policy_denied
  end

  defp env_script do
    "IO.write(System.get_env(#{inspect(@canary_env)}) || \"missing\")"
  end

  defp normalize_tmp_path(path), do: String.replace_prefix(path, "/private/var/", "/var/")
end
