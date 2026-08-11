defmodule Twelvgaige.CLI.SessionResultTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.CLI.Commands.SessionResult

  test "resolves a session prefix and exports its workspace" do
    endpoint = endpoint_file()
    parent = self()

    sessions = [
      %{"id" => "sess_alpha_123", "workspace_id" => "ws_alpha", "repository" => "/repo"}
    ]

    deps = [
      list_fun: fn _address, _opts -> {:ok, sessions} end,
      get_fun: fn _address, "sess_alpha_123", _opts -> {:ok, hd(sessions)} end,
      export_fun: fn _address, "ws_alpha", destination, opts ->
        send(parent, {:session_export, destination, opts})
        {:ok, %{"destination" => destination, "patch_bytes" => 21}}
      end
    ]

    assert {:ok, output, 0} =
             SessionResult.export(
               "sess_alpha",
               ["--endpoint", endpoint, "--output", "./review"],
               deps
             )

    assert output =~ "Exported session sess_alpha_123"
    assert_receive {:session_export, destination, opts}
    assert destination == Path.expand("./review")
    assert is_binary(opts[:request_id])
  end

  test "session apply is dry-run-first and requires explicit write authority" do
    endpoint = endpoint_file()
    session = %{"id" => "sess_apply", "workspace_id" => "ws_apply", "repository" => "/repo"}
    parent = self()

    deps = [
      list_fun: fn _address, _opts -> {:ok, [session]} end,
      get_fun: fn _address, "sess_apply", _opts -> {:ok, session} end,
      apply_fun: fn _address, "ws_apply", opts ->
        send(parent, {:session_apply, opts})
        {:ok, %{"dry_run" => not opts[:write?], "expected_epoch" => 9, "path" => "/review"}}
      end
    ]

    assert {:ok, check, 0} =
             SessionResult.apply("sess_apply", ["--endpoint", endpoint], deps)

    assert check =~ "Apply check passed"
    assert_receive {:session_apply, check_opts}
    refute check_opts[:write?]

    assert {:ok, _error, code} =
             SessionResult.apply(
               "sess_apply",
               ["--endpoint", endpoint, "--write", "--expected-epoch", "9"],
               deps
             )

    assert code != 0

    assert {:ok, applied, 0} =
             SessionResult.apply(
               "sess_apply",
               [
                 "--endpoint",
                 endpoint,
                 "--write",
                 "--yes",
                 "--expected-epoch",
                 "9",
                 "--request-id",
                 "session-apply-request"
               ],
               deps
             )

    assert applied =~ "/review"
    assert_receive {:session_apply, apply_opts}
    assert apply_opts[:request_id] == "session-apply-request"
  end

  defp endpoint_file do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-session-result-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "breech.endpoint.json")
    on_exit(fn -> File.rm_rf!(root) end)

    :ok =
      Endpoint.write(%{address: {:tcp, {127, 0, 0, 1}, 4321}, token: "control-token"},
        path: path
      )

    path
  end
end
