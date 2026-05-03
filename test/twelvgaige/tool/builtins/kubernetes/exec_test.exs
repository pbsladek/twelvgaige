defmodule Twelvgaige.Tool.Builtins.Kubernetes.ExecTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.Kubernetes.Exec
  alias Twelvgaige.Tool.Executor

  test "kubectl_exec requires explicit runtime opt-in before running kubectl" do
    input = exec_input()

    assert {:error, error} =
             Exec.execute(input,
               command_runner: unused_runner()
             )

    assert error.class == :policy_error
    assert error.reason == :policy_denied
    assert error.safety_required
    assert error.details.required == "allow_kubectl_exec: true"
  end

  test "kubectl_exec builds structured argv and returns redacted bounded output" do
    runner = fn binary, args, opts ->
      send(self(), {:runner, binary, args, opts})
      {:ok, %{status: 0, stdout: "token=secret\nok\n", stderr: "", duration_ms: 12}}
    end

    assert {:ok, output} =
             Exec.execute(exec_input(),
               allow_kubectl_exec: true,
               command_runner: runner
             )

    assert_receive {:runner, "kubectl",
                    [
                      "--context",
                      "kind-dev",
                      "-n",
                      "payments",
                      "exec",
                      "api-pod",
                      "--",
                      "printenv",
                      "APP"
                    ], [timeout_ms: 30_000]}

    assert output["verb"] == "exec"
    assert output["resource"] == "pods"
    assert output["command"] == ["printenv", "APP"]
    assert output["text_excerpt"] =~ "token=[REDACTED]"
    refute output["truncated"]
  end

  test "kubectl_exec supports an explicit container argument" do
    runner = fn binary, args, opts ->
      send(self(), {:runner, binary, args, opts})
      {:ok, %{status: 0, stdout: "ok\n", stderr: "", duration_ms: 8}}
    end

    input = Map.put(exec_input(), "container", "app")

    assert {:ok, _output} =
             Exec.execute(input,
               allow_kubectl_exec: true,
               command_runner: runner
             )

    assert_receive {:runner, "kubectl",
                    [
                      "--context",
                      "kind-dev",
                      "-n",
                      "payments",
                      "exec",
                      "api-pod",
                      "--container",
                      "app",
                      "--",
                      "printenv",
                      "APP"
                    ], [timeout_ms: 30_000]}
  end

  test "kubectl_exec requires irreversible executor safety" do
    parent = self()

    runner = fn binary, args, opts ->
      send(parent, {:runner, binary, args, opts})
      {:ok, %{status: 0, stdout: "ok\n", stderr: "", duration_ms: 5}}
    end

    assert {:error, policy} =
             Executor.execute("kubectl_exec", exec_input(),
               allowed_tools: ["kubectl_exec"],
               limiter: nil,
               max_safety: :destructive,
               tool_opts: [allow_kubectl_exec: true, command_runner: runner]
             )

    assert policy.class == :policy_error
    assert policy.reason == :policy_denied
    assert policy.details.tool_safety == :irreversible
    refute_received {:runner, _, _, _}

    assert {:ok, output} =
             Executor.execute("kubectl_exec", exec_input(),
               allowed_tools: ["kubectl_exec"],
               limiter: nil,
               max_safety: :irreversible,
               tool_opts: [allow_kubectl_exec: true, command_runner: runner]
             )

    assert_receive {:runner, "kubectl", _args, [timeout_ms: 30_000]}
    assert output["verb"] == "exec"
  end

  test "kubectl_exec blocks shell interpreters unless separately allowed" do
    input = exec_input(%{"command" => ["sh", "-c", "echo should-not-run"]})

    assert {:error, error} =
             Exec.execute(input,
               allow_kubectl_exec: true,
               command_runner: unused_runner()
             )

    assert error.class == :policy_error
    assert error.reason == :policy_denied
    assert error.details.required == "allow_shell: true"
  end

  test "kubectl_exec still uses argv when shell interpreters are explicitly allowed" do
    runner = fn binary, args, opts ->
      send(self(), {:runner, binary, args, opts})
      {:ok, %{status: 0, stdout: "ok\n", stderr: "", duration_ms: 6}}
    end

    input = exec_input(%{"command" => ["sh", "-c", "echo ok"]})

    assert {:ok, output} =
             Exec.execute(input,
               allow_kubectl_exec: true,
               allow_shell: true,
               command_runner: runner
             )

    assert_receive {:runner, "kubectl",
                    [
                      "--context",
                      "kind-dev",
                      "-n",
                      "payments",
                      "exec",
                      "api-pod",
                      "--",
                      "sh",
                      "-c",
                      "echo ok"
                    ], [timeout_ms: 30_000]}

    assert output["command"] == ["sh", "-c", "echo ok"]
  end

  defp exec_input(overrides \\ %{}) do
    Map.merge(
      %{
        "context" => "kind-dev",
        "namespace" => "payments",
        "name" => "api-pod",
        "command" => ["printenv", "APP"],
        "confirm" => true
      },
      overrides
    )
  end

  defp unused_runner do
    fn _binary, _args, _opts -> flunk("kubectl should not run") end
  end
end
