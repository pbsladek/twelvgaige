defmodule Twelvgaige.CLI.Commands.RoundModulesTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.CLI.Commands.RoundQuery
  alias Twelvgaige.CLI.Commands.RoundRun

  @workflow_path "test/fixtures/shells/simple_workflow.yaml"

  test "round run module defaults input to an empty object" do
    assert {:ok, output, 0} = RoundRun.run(@workflow_path, [])

    assert output =~ "Status: complete"
    assert output =~ "first [complete]"
    assert output =~ "second [complete]"
  end

  test "round run module emits JSON snapshots and validates input shape" do
    assert {:ok, output, 0} =
             RoundRun.run(@workflow_path, ["--input", ~s({"cluster":"dev"}), "--format", "json"])

    assert %{"shell_id" => "simple", "status" => "complete", "shots" => shots} =
             Jason.decode!(output)

    assert Enum.map(shots, & &1["status"]) == ["complete", "complete"]

    assert {:ok, output, 4} = RoundRun.run(@workflow_path, ["--input", ~s(["not", "object"])])
    assert output =~ "round input must be a JSON object"
  end

  test "round query module shows and watches daemon-owned rounds" do
    assert {:ok, round_id} = Twelvgaige.run_round(@workflow_path, %{"cluster" => "dev"})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, output, 0} = RoundQuery.show(round_id, ["--format", "json"])
    assert %{"id" => ^round_id, "status" => "complete"} = Jason.decode!(output)

    assert {:ok, output, 0} = RoundQuery.watch(round_id, ["--format", "ndjson"])

    assert [event] =
             output
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)

    assert event["round_id"] == round_id
    assert event["event_type"] == "round_completed"
  end

  test "round query module preserves not-found and watch option errors" do
    assert {:ok, output, 6} = RoundQuery.show("round_missing", ["--format", "json"])
    assert %{"error" => %{"reason" => "round_not_found"}} = Jason.decode!(output)

    assert {:ok, output, 4} = RoundQuery.watch("round_missing", ["--after-seq", "-1"])
    assert output =~ "--after-seq must be >= 0"
  end

  defp eventually(fun), do: eventually(fun, 100)

  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts_left) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts_left - 1)
    end
  end
end
