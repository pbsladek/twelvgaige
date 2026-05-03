defmodule Twelvgaige.Tool.Builtins.Kubernetes.LogsTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.Kubernetes.Logs

  test "builds structured logs argv, caps tail lines, and redacts output" do
    runner = fn binary, args, _opts ->
      send(self(), {:runner, binary, args})

      {:ok,
       %{
         status: 0,
         stdout: "ready\npassword: hunter2\n",
         stderr: "",
         duration_ms: 4
       }}
    end

    assert {:ok, result} =
             Logs.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "default",
                 "name" => "pod-a",
                 "container" => "web",
                 "tail_lines" => 2_000,
                 "since_seconds" => 60
               },
               command_runner: runner
             )

    assert_receive {:runner, "kubectl",
                    [
                      "--context",
                      "kind-dev",
                      "-n",
                      "default",
                      "logs",
                      "pod-a",
                      "--tail",
                      "1000",
                      "--since",
                      "60s",
                      "--container",
                      "web"
                    ]}

    assert result["tail_lines"] == 1_000
    assert result["container"] == "web"
    assert result["log_excerpt"] =~ "password=[REDACTED]"
    assert result["line_count"] == 2
  end
end
