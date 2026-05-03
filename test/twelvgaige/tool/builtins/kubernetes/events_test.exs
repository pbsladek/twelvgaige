defmodule Twelvgaige.Tool.Builtins.Kubernetes.EventsTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.Kubernetes.Events

  test "reads and normalizes events newest first" do
    runner = fn binary, args, _opts ->
      send(self(), {:runner, binary, args})

      {:ok,
       %{
         status: 0,
         stdout:
           Jason.encode!(%{
             "items" => [
               %{"reason" => "Old", "lastTimestamp" => "2026-01-01T00:00:00Z"},
               %{"reason" => "New", "eventTime" => "2026-01-02T00:00:00Z"}
             ]
           }),
         stderr: "",
         duration_ms: 5
       }}
    end

    assert {:ok, result} =
             Events.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "default",
                 "field_selector" => "involvedObject.kind=Pod"
               },
               command_runner: runner
             )

    assert_receive {:runner, "kubectl",
                    [
                      "--context",
                      "kind-dev",
                      "-n",
                      "default",
                      "get",
                      "events",
                      "--field-selector",
                      "involvedObject.kind=Pod",
                      "-o",
                      "json"
                    ]}

    assert [%{"reason" => "New"}, %{"reason" => "Old"}] = result["items"]
    assert result["summary"]["event_count"] == 2
  end
end
