defmodule Twelvgaige.CLI.CommandHelpersTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}

  test "common workspace errors include safe human and JSON remediation" do
    human = CommandHelpers.format_command_error(:workspace_apply_target_drifted_or_dirty, :human)
    assert human =~ "workspace_apply_target_drifted_or_dirty"
    assert human =~ "Next: git status --short"
    refute human =~ "reset"
    refute human =~ "clean -f"

    json =
      :workspace_not_found
      |> CommandHelpers.format_command_error(:json)
      |> Jason.decode!()

    assert json["error"]["reason"] == "workspace_not_found"
    assert json["error"]["remediation"] == ["twelvgaige workspace list"]
    assert ExitCode.for_error(:workspace_not_found) == 6
    assert ExitCode.for_error(:workspace_apply_confirmation_required) == 4
  end

  test "disk admission failures point to read-only retention and inventory commands" do
    output =
      CommandHelpers.format_command_error(
        {:workspace_storage_unavailable, %{available_bytes: 1}},
        :human
      )

    assert output =~ "twelvgaige workspace retention status"
    assert output =~ "twelvgaige workspace list"
  end

  test "client timeout output never claims the operation stopped" do
    error =
      Twelvgaige.Error.new(
        :timeout_error,
        :client_timeout,
        "client stopped waiting; operation status is unknown",
        retryable: true,
        details: %{
          request_id: "req_timeout",
          disposition: "unknown",
          operation_may_continue: true,
          lookup_command: "twelvgaige operation show req_timeout"
        }
      )

    human = CommandHelpers.format_command_error(error, :human)
    assert human =~ "operation status is unknown"
    assert human =~ "Next: twelvgaige operation show req_timeout"
    refute human =~ "operation stopped"

    json = error |> CommandHelpers.format_command_error(:json) |> Jason.decode!()
    assert json["error"]["reason"] == "client_timeout"
    assert json["error"]["details"]["request_id"] == "req_timeout"
    assert json["error"]["details"]["operation_may_continue"]
    assert json["error"]["remediation"] == ["twelvgaige operation show req_timeout"]
    assert ExitCode.for_error(error) == 3
  end
end
