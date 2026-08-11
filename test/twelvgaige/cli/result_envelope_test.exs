defmodule Twelvgaige.CLI.ResultEnvelopeTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.ResultEnvelope

  test "wraps successful map and list payloads in one versioned JSON contract" do
    assert {:ok, map_output, 0} =
             ResultEnvelope.wrap(
               {:ok,
                Jason.encode!(%{
                  status: "running",
                  request_id: "req_123",
                  workspace_id: "ws_123"
                }), 0},
               ["workspace", "show", "ws_123", "--format", "json"]
             )

    assert Jason.decode!(map_output) == %{
             "schema" => "twelvgaige.cli.result",
             "schema_version" => 1,
             "command" => "workspace show",
             "disposition" => "succeeded",
             "exit_code" => 0,
             "request_id" => "req_123",
             "resource_ids" => %{"workspace_id" => "ws_123"},
             "result" => %{
               "status" => "running",
               "request_id" => "req_123",
               "workspace_id" => "ws_123"
             }
           }

    assert {:ok, list_output, 0} =
             ResultEnvelope.wrap(
               {:ok, Jason.encode!([%{id: "round_1"}]), 0},
               ["round", "list", "--format", "json"]
             )

    assert {:ok, [%{"id" => "round_1"}]} =
             list_output |> Jason.decode!() |> ResultEnvelope.result()
  end

  test "promotes a typed command error without retaining the legacy wrapper" do
    output = Jason.encode!(%{error: %{reason: "workspace_not_found", message: "not found"}})

    assert {:ok, wrapped, 6} =
             ResultEnvelope.wrap(
               {:ok, output, 6},
               ["workspace", "show", "missing", "--format", "json"]
             )

    assert Jason.decode!(wrapped) == %{
             "schema" => "twelvgaige.cli.result",
             "schema_version" => 1,
             "command" => "workspace show",
             "disposition" => "failed",
             "exit_code" => 6,
             "error" => %{"reason" => "workspace_not_found", "message" => "not found"}
           }
  end

  test "turns an unstructured JSON-mode response into a stable internal failure" do
    assert {:ok, wrapped, 8} =
             ResultEnvelope.wrap(
               {:ok, "legacy text\n", 0},
               ["repo", "inspect", "--format", "json"]
             )

    assert {:error,
            %{
              "reason" => "unstructured_command_output",
              "message" => "legacy text"
            }} = wrapped |> Jason.decode!() |> ResultEnvelope.result()
  end

  test "wraps every NDJSON record and appends exactly one terminal record" do
    source = Jason.encode!(%{event_type: "started", seq: 1}) <> "\n" <> Jason.encode!(%{seq: 2})

    assert {:ok, wrapped, 0} =
             ResultEnvelope.wrap(
               {:ok, source, 0},
               ["round", "watch", "round_1", "--format", "ndjson"]
             )

    records = wrapped |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert Enum.map(records, & &1["event_index"]) == [0, 1, 2]
    assert Enum.map(records, & &1["event_type"]) == ["started", "data", "terminal"]
    assert Enum.count(records, & &1["terminal"]) == 1

    assert List.last(records) == %{
             "schema" => "twelvgaige.cli.event",
             "schema_version" => 1,
             "command" => "round watch",
             "event_index" => 2,
             "event_type" => "terminal",
             "terminal" => true,
             "disposition" => "succeeded",
             "exit_code" => 0,
             "event_count" => 2
           }
  end

  test "an empty NDJSON response still contains its terminal disposition" do
    assert {:ok, wrapped, 0} =
             ResultEnvelope.wrap(
               {:ok, "", 0},
               ["round", "watch", "round_1", "--format", "ndjson"]
             )

    assert [terminal] = wrapped |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert terminal["terminal"]
    assert terminal["event_count"] == 0
  end

  test "uses stable identities for nested command families" do
    assert ResultEnvelope.command(["workspace", "set", "show", "set_1", "--format", "json"]) ==
             "workspace set show"

    assert ResultEnvelope.command(["operations", "audit", "status", "--format", "json"]) ==
             "operations audit status"
  end
end
