defmodule Twelvgaige.Tool.Builtins.Kubernetes.DescribeTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.Kubernetes.Describe

  test "builds structured describe argv and redacts bounded text" do
    runner = fn binary, args, _opts ->
      send(self(), {:runner, binary, args})

      {:ok,
       %{
         status: 0,
         stdout: "Name: pod-a\nAuthorization: Bearer abc123\n",
         stderr: "",
         duration_ms: 3
       }}
    end

    assert {:ok, result} =
             Describe.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "default",
                 "resource" => "pods",
                 "name" => "pod-a"
               },
               command_runner: runner
             )

    assert_receive {:runner, "kubectl",
                    ["--context", "kind-dev", "-n", "default", "describe", "pods", "pod-a"]}

    assert result["text_excerpt"] =~ "Name: pod-a"
    assert result["text_excerpt"] =~ "Bearer [REDACTED]"
  end

  test "requires a resource name" do
    assert {:error, error} =
             Describe.execute(
               %{"context" => "kind-dev", "namespace" => "default", "resource" => "pods"},
               command_runner: fn _, _, _ -> flunk("kubectl should not run") end
             )

    assert error.reason == :tool_input_invalid
  end
end
