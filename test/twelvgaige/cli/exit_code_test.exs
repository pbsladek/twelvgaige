defmodule Twelvgaige.CLI.ExitCodeTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Error
  alias Twelvgaige.Round.Snapshot

  test "maps round run snapshots to deterministic exit codes" do
    assert ExitCode.for_snapshot(snapshot(:complete)) == 0
    assert ExitCode.for_snapshot(snapshot(:awaiting_safety)) == 1
    assert ExitCode.for_snapshot(snapshot(:halted)) == 2

    assert ExitCode.for_snapshot(
             snapshot(:failed, Error.new(:timeout_error, :shot_timeout, "timed out"))
           ) == 3

    assert ExitCode.for_snapshot(
             snapshot(:failed, Error.new(:policy_error, :policy_denied, "denied"))
           ) == 7

    assert ExitCode.for_snapshot(
             snapshot(:failed, Error.new(:internal_error, :shot_crash, "crashed"))
           ) == 8

    assert ExitCode.for_snapshot(
             snapshot(:failed, Error.new(:llm_error, :llm_unknown, "provider failed"))
           ) == 1
  end

  test "maps command errors to deterministic exit codes" do
    assert ExitCode.for_error(Error.new(:input_error, :invalid_shell, "bad input")) == 4
    assert ExitCode.for_error(:invalid_ipc_address) == 4
    assert ExitCode.for_error(:daemon_unavailable) == 5
    assert ExitCode.for_error(Error.new(:policy_error, :daemon_auth_failed, "auth failed")) == 5
    assert ExitCode.for_error(:not_found) == 6
    assert ExitCode.for_error(Error.new(:tool_error, :unknown_tool, "missing tool")) == 6
    assert ExitCode.for_error(Error.new(:policy_error, :network_policy_denied, "denied")) == 7
    assert ExitCode.for_error(Error.new(:store_error, :store_unavailable, "store down")) == 8
    assert ExitCode.for_error(:unexpected) == 8
  end

  test "maps a missing shell file to not-found instead of invalid-shell" do
    error =
      Error.new(:input_error, :invalid_shell, "unable to read shell file",
        details: %{file_path: "missing.yaml", reason: ":enoent"}
      )

    assert ExitCode.for_error(error) == 6
  end

  defp snapshot(status, error \\ nil) do
    Snapshot.new(
      id: "round_1",
      shell_id: "shell",
      shell_version: "1.0.0",
      status: status,
      error: error
    )
  end
end
