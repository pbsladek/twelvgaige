defmodule Twelvgaige.Tool.Builtins.Kubernetes.WriteToolsTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.Kubernetes.Delete
  alias Twelvgaige.Tool.Builtins.Kubernetes.Scale
  alias Twelvgaige.Tool.Executor

  test "kubectl_scale builds structured scale argv and returns redacted output" do
    runner = fn binary, args, opts ->
      send(self(), {:runner, binary, args, opts})
      {:ok, %{status: 0, stdout: "scaled token=secret\n", stderr: "", duration_ms: 9}}
    end

    assert {:ok, output} =
             Scale.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "payments",
                 "resource" => "deployments",
                 "name" => "api",
                 "replicas" => 3
               },
               command_runner: runner
             )

    assert_receive {:runner, "kubectl",
                    [
                      "--context",
                      "kind-dev",
                      "-n",
                      "payments",
                      "scale",
                      "deployments",
                      "api",
                      "--replicas",
                      "3"
                    ], [timeout_ms: 30_000]}

    assert output["verb"] == "scale"
    assert output["replicas"] == 3
    assert output["text_excerpt"] =~ "token=[REDACTED]"
  end

  test "kubectl_scale requires a namespaced workload resource" do
    assert {:error, error} =
             Scale.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "payments",
                 "resource" => "pods",
                 "name" => "api",
                 "replicas" => 1
               },
               command_runner: unused_runner()
             )

    assert error.reason == :kubernetes_resource_denied
    assert error.safety_required
  end

  test "kubectl_rollout_restart requires explicit confirmation and destructive safety" do
    parent = self()

    runner = fn binary, args, opts ->
      send(parent, {:runner, binary, args, opts})
      {:ok, %{status: 0, stdout: "deployment restarted\n", stderr: "", duration_ms: 10}}
    end

    input = %{
      "context" => "kind-dev",
      "namespace" => "payments",
      "resource" => "deployments",
      "name" => "api",
      "confirm" => true
    }

    assert {:error, policy} =
             Executor.execute("kubectl_rollout_restart", input,
               allowed_tools: ["kubectl_rollout_restart"],
               limiter: nil,
               max_safety: :idempotent_write,
               tool_opts: [command_runner: runner]
             )

    assert policy.class == :policy_error
    assert policy.reason == :policy_denied

    assert {:ok, output} =
             Executor.execute("kubectl_rollout_restart", input,
               allowed_tools: ["kubectl_rollout_restart"],
               limiter: nil,
               max_safety: :destructive,
               tool_opts: [command_runner: runner]
             )

    assert_receive {:runner, "kubectl",
                    [
                      "--context",
                      "kind-dev",
                      "-n",
                      "payments",
                      "rollout",
                      "restart",
                      "deployments/api"
                    ], [timeout_ms: 30_000]}

    assert output["verb"] == "rollout_restart"
  end

  test "kubectl_delete deletes only explicit namespaced objects after confirmation" do
    runner = fn binary, args, opts ->
      send(self(), {:runner, binary, args, opts})
      {:ok, %{status: 0, stdout: "pod deleted\n", stderr: "", duration_ms: 4}}
    end

    assert {:error, confirmation} =
             Delete.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "payments",
                 "resource" => "pods",
                 "name" => "api"
               },
               command_runner: unused_runner()
             )

    assert confirmation.class == :policy_error
    assert confirmation.reason == :policy_denied
    assert confirmation.safety_required

    assert {:ok, output} =
             Delete.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "payments",
                 "resource" => "pods",
                 "name" => "api",
                 "confirm" => true
               },
               command_runner: runner
             )

    assert_receive {:runner, "kubectl",
                    [
                      "--context",
                      "kind-dev",
                      "-n",
                      "payments",
                      "delete",
                      "pods",
                      "api"
                    ], [timeout_ms: 30_000]}

    assert output["verb"] == "delete"
    assert output["name"] == "api"
  end

  defp unused_runner do
    fn _binary, _args, _opts -> flunk("kubectl should not run") end
  end
end
