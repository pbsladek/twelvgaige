defmodule Twelvgaige.CLI.WorkspaceCommandTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.CLI.Commands.Workspace

  test "lists and shows explicit multi-repository workspace provenance" do
    endpoint = endpoint_file()

    sets = [
      %{
        "id" => "wsset_release_123",
        "owner_session_id" => "sess_owner",
        "finalized_at" => "2026-08-11T12:00:00Z",
        "repositories" => %{
          "app" => %{
            "id" => "ws_app",
            "base_commit" => "input-app",
            "head_commit" => "output-app"
          },
          "library" => %{
            "id" => "ws_library",
            "base_commit" => "input-library",
            "head_commit" => "output-library"
          }
        }
      }
    ]

    list_fun = fn _address, _opts -> {:ok, sets} end

    assert {:ok, list, 0} =
             Workspace.set(:list, ["--endpoint", endpoint], set_list_fun: list_fun)

    assert list =~ "wsset_release_123\tfinalized\t2"

    assert {:ok, shown, 0} =
             Workspace.set(:show, ["wsset_release", "--endpoint", endpoint],
               set_list_fun: list_fun,
               set_get_fun: fn _address, "wsset_release_123", _opts -> {:ok, hd(sets)} end
             )

    assert shown =~ "app: input-app -> output-app (ws_app)"
    assert shown =~ "library: input-library -> output-library (ws_library)"
  end

  test "retention status suggests an explicit sweep only when verified workspaces expired" do
    endpoint = endpoint_file()

    retention_status_fun = fn _address, _opts ->
      {:ok,
       %{
         "workspace_retention_days" => 7,
         "expired_workspaces" => ["ws_expired"],
         "last_run" => "never"
       }}
    end

    assert {:ok, output, 0} =
             Workspace.retention(:status, ["--endpoint", endpoint],
               retention_status_fun: retention_status_fun
             )

    assert output =~ "expired now: 1"
    assert output =~ "Next: twelvgaige workspace retention run"
  end

  test "lists, repository-filters, and resolves unambiguous workspace prefixes" do
    endpoint = endpoint_file()
    workspaces = workspaces()
    list_fun = fn _address, _opts -> {:ok, workspaces} end

    assert {:ok, output, 0} =
             Workspace.list(["--endpoint", endpoint, "--repo", "/repo/one"],
               list_fun: list_fun
             )

    assert output =~ "ws_alpha_123"
    refute output =~ "ws_beta_456"

    get_fun = fn _address, "ws_alpha_123", _opts -> {:ok, hd(workspaces)} end

    assert {:ok, path, 0} =
             Workspace.show(:path, "ws_alpha", ["--endpoint", endpoint],
               list_fun: list_fun,
               get_fun: get_fun
             )

    assert path == "/managed/ws_alpha_123\n"

    assert {:ok, last, 0} =
             Workspace.show(:show, "--last", ["--endpoint", endpoint, "--format", "json"],
               list_fun: list_fun,
               get_fun: fn _address, "ws_beta_456", _opts -> {:ok, List.last(workspaces)} end
             )

    assert Jason.decode!(last)["id"] == "ws_beta_456"
  end

  test "cleanup is dry-run-first and forwards explicit mutation authority" do
    endpoint = endpoint_file()
    parent = self()
    [workspace | _] = workspaces()
    list_fun = fn _address, _opts -> {:ok, [workspace]} end

    cleanup_fun = fn _address, "ws_alpha_123", opts ->
      send(parent, {:cleanup_opts, opts})

      {:ok,
       %{
         "workspace_id" => "ws_alpha_123",
         "dry_run" => not opts[:write?],
         "entries" => 10,
         "bytes" => 1_024,
         "expected_epoch" => 7
       }}
    end

    assert {:ok, preview, 0} =
             Workspace.show(:cleanup, "ws_alpha", ["--endpoint", endpoint],
               list_fun: list_fun,
               cleanup_fun: cleanup_fun
             )

    assert preview =~ "Re-run with --write --yes --expected-epoch 7"
    assert_receive {:cleanup_opts, dry_opts}
    refute dry_opts[:write?]

    assert {:ok, _output, code} =
             Workspace.show(
               :cleanup,
               "ws_alpha",
               ["--endpoint", endpoint, "--write", "--expected-epoch", "7"],
               list_fun: list_fun,
               cleanup_fun: cleanup_fun
             )

    assert code != 0

    assert {:ok, written, 0} =
             Workspace.show(
               :cleanup,
               "ws_alpha",
               [
                 "--endpoint",
                 endpoint,
                 "--write",
                 "--yes",
                 "--expected-epoch",
                 "7",
                 "--request-id",
                 "cleanup-request"
               ],
               list_fun: list_fun,
               cleanup_fun: cleanup_fun
             )

    assert written =~ "removed"
    assert_receive {:cleanup_opts, write_opts}
    assert write_opts[:write?]
    assert write_opts[:yes?]
    assert write_opts[:expected_epoch] == 7
    assert write_opts[:request_id] == "cleanup-request"
  end

  test "exports a verified artifact and applies to a review worktree dry-run-first" do
    endpoint = endpoint_file()
    parent = self()
    [workspace | _] = workspaces()
    list_fun = fn _address, _opts -> {:ok, [workspace]} end

    export_fun = fn _address, "ws_alpha_123", destination, opts ->
      send(parent, {:export_request, destination, opts})

      {:ok,
       %{
         "workspace_id" => "ws_alpha_123",
         "destination" => destination,
         "patch_bytes" => 42
       }}
    end

    output = Path.join(System.tmp_dir!(), "review-export")

    assert {:ok, exported, 0} =
             Workspace.show(
               :export,
               "ws_alpha",
               ["--endpoint", endpoint, "--output", output],
               list_fun: list_fun,
               export_fun: export_fun
             )

    assert exported =~ Path.expand(output)
    assert_receive {:export_request, destination, export_opts}
    assert destination == Path.expand(output)
    assert is_binary(export_opts[:request_id])

    apply_fun = fn _address, "ws_alpha_123", opts ->
      send(parent, {:apply_request, opts})

      if opts[:write?] do
        {:ok,
         %{
           "workspace_id" => "ws_alpha_123",
           "dry_run" => false,
           "path" => "/managed/reviews/ws_alpha_123",
           "verified_result_tree" => "tree-result"
         }}
      else
        {:ok,
         %{
           "workspace_id" => "ws_alpha_123",
           "dry_run" => true,
           "result_tree" => "tree-result",
           "expected_epoch" => 7
         }}
      end
    end

    assert {:ok, check, 0} =
             Workspace.show(:apply, "ws_alpha", ["--endpoint", endpoint],
               list_fun: list_fun,
               apply_fun: apply_fun
             )

    assert check =~ "Apply check passed"
    assert check =~ "--expected-epoch 7"
    assert_receive {:apply_request, check_opts}
    refute check_opts[:write?]

    assert {:ok, applied, 0} =
             Workspace.show(
               :apply,
               "ws_alpha",
               [
                 "--endpoint",
                 endpoint,
                 "--write",
                 "--yes",
                 "--expected-epoch",
                 "7",
                 "--request-id",
                 "apply-request"
               ],
               list_fun: list_fun,
               apply_fun: apply_fun
             )

    assert applied =~ "Verified review worktree"
    assert_receive {:apply_request, apply_opts}
    assert apply_opts[:write?]
    assert apply_opts[:yes?]
    assert apply_opts[:expected_epoch] == 7
    assert apply_opts[:request_id] == "apply-request"
  end

  test "reconciliation and review cleanup preserve dry-run and epoch authority" do
    endpoint = endpoint_file()
    parent = self()
    [workspace | _] = workspaces()
    list_fun = fn _address, _opts -> {:ok, [workspace]} end

    reconcile_fun = fn _address, "ws_alpha_123", opts ->
      send(parent, {:reconcile_request, opts})

      {:ok,
       %{
         "workspace_id" => "ws_alpha_123",
         "interrupted_kind" => "apply_current",
         "interrupted_request_id" => "apply-interrupted",
         "expected_epoch" => 7,
         "dry_run" => not opts[:write?],
         "recovery_commands" => ["twelvgaige workspace show ws_alpha_123"],
         "restoration" => %{
           "available" => true,
           "command" =>
             "twelvgaige workspace reconcile ws_alpha_123 --write --yes --expected-epoch 7 --action restore-backup"
         },
         "action" => opts[:action] || :quarantine
       }}
    end

    assert {:ok, preview, 0} =
             Workspace.show(:reconcile, "ws_alpha", ["--endpoint", endpoint],
               list_fun: list_fun,
               reconcile_fun: reconcile_fun
             )

    assert preview =~ "Reconciliation required"
    assert preview =~ "--action restore-backup"
    assert_receive {:reconcile_request, preview_opts}
    refute preview_opts[:write?]

    assert {:ok, resolved, 0} =
             Workspace.show(
               :reconcile,
               "ws_alpha",
               [
                 "--endpoint",
                 endpoint,
                 "--write",
                 "--yes",
                 "--expected-epoch",
                 "7",
                 "--action",
                 "quarantine"
               ],
               list_fun: list_fun,
               reconcile_fun: reconcile_fun
             )

    assert resolved =~ "reconciled as quarantined"
    assert_receive {:reconcile_request, quarantine_opts}
    assert quarantine_opts[:action] == :quarantine

    assert {:ok, restored, 0} =
             Workspace.show(
               :reconcile,
               "ws_alpha",
               [
                 "--endpoint",
                 endpoint,
                 "--write",
                 "--yes",
                 "--expected-epoch",
                 "7",
                 "--action",
                 "restore-backup"
               ],
               list_fun: list_fun,
               reconcile_fun: reconcile_fun
             )

    assert restored =~ "restored from its validated backup"
    assert_receive {:reconcile_request, restore_opts}
    assert restore_opts[:action] == :restore_backup

    review_cleanup_fun = fn _address, "ws_alpha_123", opts ->
      send(parent, {:review_cleanup_request, opts})

      {:ok,
       %{
         "workspace_id" => "ws_alpha_123",
         "review_path" => "/managed/reviews/ws_alpha_123",
         "expected_epoch" => 8,
         "dry_run" => not opts[:write?]
       }}
    end

    assert {:ok, cleanup, 0} =
             Workspace.show(:review_cleanup, "ws_alpha", ["--endpoint", endpoint],
               list_fun: list_fun,
               review_cleanup_fun: review_cleanup_fun
             )

    assert cleanup =~ "Review cleanup check passed"
    assert_receive {:review_cleanup_request, cleanup_opts}
    refute cleanup_opts[:write?]
  end

  defp workspaces do
    [
      %{
        "id" => "ws_alpha_123",
        "state" => "reviewable",
        "source_mode" => "committed",
        "repository" => "/repo/one",
        "path" => "/managed/ws_alpha_123",
        "base_commit" => "abc",
        "head_commit" => "def",
        "control_epoch" => 7
      },
      %{
        "id" => "ws_beta_456",
        "state" => "running",
        "source_mode" => "staged",
        "repository" => "/repo/two",
        "path" => "/managed/ws_beta_456",
        "base_commit" => "123",
        "control_epoch" => 2
      }
    ]
  end

  defp endpoint_file do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-workspace-cli-#{System.unique_integer([:positive])}"
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
