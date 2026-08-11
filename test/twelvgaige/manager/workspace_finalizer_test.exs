defmodule Twelvgaige.Manager.WorkspaceFinalizerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Handoff
  alias Twelvgaige.Manager.{Budget, ChildRecord, WorkspaceFinalizer}
  alias Twelvgaige.Workspace.Manager, as: WorkspaceManager

  test "gates successful handoff on quiescence and verified workspace capture" do
    repository = repository_fixture()
    root = temp_dir("workspace-finalizer")
    manager = start_supervised!({WorkspaceManager, name: nil, root: root})
    child = child("ws_finalizer")

    assert {:ok, workspace} =
             WorkspaceManager.create(repository,
               server: manager,
               workspace_id: child.workspace_id
             )

    assert {:ok, _workspace} =
             WorkspaceManager.bind_owner(workspace.id, child.delegated_session_id,
               server: manager
             )

    File.write!(Path.join(workspace.path, "result.txt"), "captured")

    result =
      {:ok,
       %{
         handoff:
           Handoff.new(%{
             objective_status: :complete,
             summary: "done",
             workspace_id: workspace.id,
             base_commit: workspace.base_commit
           }),
         usage: %{tokens: 1, cost_micros: 0, time_ms: 1, tool_calls: 0},
         runtime_quiescence: %{
           runtime_stopped: true,
           runtime_identity: "sandbox-finalizer",
           stopped_at: ~U[2026-08-11 12:00:00Z]
         }
       }}

    assert {:ok, %{handoff: handoff, workspace_result: manifest}} =
             WorkspaceFinalizer.finalize(child, result, workspace_manager: manager)

    assert handoff.observed.result_manifest_digest == manifest.manifest_digest
    assert handoff.observed.result_tree == manifest.result_tree

    assert {:ok, %{state: :reviewable, result_manifest: ^manifest}} =
             WorkspaceManager.get(workspace.id, server: manager)
  end

  test "quarantines a workspace when the runtime cannot prove it stopped" do
    repository = repository_fixture()
    root = temp_dir("workspace-finalizer-missing")
    manager = start_supervised!({WorkspaceManager, name: nil, root: root})
    child = child("ws_finalizer_missing")

    assert {:ok, workspace} =
             WorkspaceManager.create(repository,
               server: manager,
               workspace_id: child.workspace_id
             )

    assert {:ok, _workspace} =
             WorkspaceManager.bind_owner(workspace.id, child.delegated_session_id,
               server: manager
             )

    assert {:error, {:manager_workspace_finalization_failed, :manager_runtime_quiescence_missing}} =
             WorkspaceFinalizer.finalize(
               child,
               {:ok, %{handoff: :missing_evidence}},
               workspace_manager: manager
             )

    assert {:ok, quarantined} = WorkspaceManager.get(workspace.id, server: manager)
    assert quarantined.state == :quarantined
    assert quarantined.quarantine_reason == :manager_runtime_quiescence_missing
  end

  test "captures partial work from a failed execution after quiescence" do
    repository = repository_fixture()
    root = temp_dir("workspace-finalizer-failure")
    manager = start_supervised!({WorkspaceManager, name: nil, root: root})
    child = child("ws_finalizer_failure")

    assert {:ok, workspace} =
             WorkspaceManager.create(repository,
               server: manager,
               workspace_id: child.workspace_id
             )

    assert {:ok, _workspace} =
             WorkspaceManager.bind_owner(workspace.id, child.delegated_session_id,
               server: manager
             )

    File.write!(Path.join(workspace.path, "partial.txt"), "recover me")

    evidence = %{
      usage: Budget.zero(),
      runtime_quiescence: %{
        runtime_stopped: true,
        runtime_identity: "sandbox-failed",
        stopped_at: ~U[2026-08-11 12:30:00Z]
      }
    }

    assert {:error, :deadline_exceeded,
            %{handoff: %Handoff{} = handoff, workspace_result: manifest}} =
             WorkspaceFinalizer.finalize(
               child,
               {:error, :deadline_exceeded, evidence},
               workspace_manager: manager
             )

    assert handoff.objective_status == :failed
    assert handoff.observed.result_tree == manifest.result_tree
    assert handoff.diff_artifact == nil
    refute manifest.no_change

    assert {:ok, %{state: :reviewable, result_manifest: ^manifest}} =
             WorkspaceManager.get(workspace.id, server: manager)
  end

  test "rejects a claimed stop that lacks a concrete runtime identity" do
    repository = repository_fixture()
    root = temp_dir("workspace-finalizer-invalid-evidence")
    manager = start_supervised!({WorkspaceManager, name: nil, root: root})
    child = child("ws_finalizer_invalid")

    assert {:ok, workspace} =
             WorkspaceManager.create(repository,
               server: manager,
               workspace_id: child.workspace_id
             )

    assert {:ok, _workspace} =
             WorkspaceManager.bind_owner(workspace.id, child.delegated_session_id,
               server: manager
             )

    result =
      {:error, :cancelled,
       %{
         usage: Budget.zero(),
         runtime_quiescence: %{
           runtime_stopped: true,
           runtime_identity: nil,
           stopped_at: ~U[2026-08-11 12:30:00Z]
         }
       }}

    assert {:error, {:manager_workspace_finalization_failed, :manager_runtime_quiescence_invalid}} =
             WorkspaceFinalizer.finalize(child, result, workspace_manager: manager)

    assert {:ok, %{state: :quarantined}} = WorkspaceManager.get(workspace.id, server: manager)
  end

  test "records only credential-free sandbox evidence as independent test verification" do
    repository = repository_fixture()
    root = temp_dir("workspace-finalizer-verification")
    manager = start_supervised!({WorkspaceManager, name: nil, root: root})
    child = child("ws_finalizer_verification")

    assert {:ok, workspace} =
             WorkspaceManager.create(repository,
               server: manager,
               workspace_id: child.workspace_id
             )

    assert {:ok, _workspace} =
             WorkspaceManager.bind_owner(workspace.id, child.delegated_session_id,
               server: manager
             )

    result =
      {:ok,
       %{
         handoff:
           Handoff.new(%{
             objective_status: :complete,
             summary: "done",
             workspace_id: workspace.id,
             base_commit: workspace.base_commit
           }),
         usage: %{tokens: 1, cost_micros: 0, time_ms: 1, tool_calls: 0},
         runtime_quiescence: %{
           runtime_stopped: true,
           runtime_identity: "sandbox-verification",
           stopped_at: ~U[2026-08-11 12:00:00Z]
         }
       }}

    executor = fn request ->
      {:ok,
       %{
         request_digest: request.request_digest,
         backend: :podman,
         network_mode: :none,
         credentials_present: false,
         provider_environment_present: false,
         workspace_copy: true,
         commands: [%{argv: ["mix", "test"], exit_status: 0}]
       }}
    end

    assert {:ok, %{verification: %{status: :passed}, workspace_result: manifest}} =
             WorkspaceFinalizer.finalize(child, result,
               workspace_manager: manager,
               verification_commands: [["mix", "test"]],
               verification_executor: executor
             )

    assert manifest.outcomes["test_verification"] == "passed"
  end

  defp child(workspace_id) do
    %ChildRecord{
      id: "mgrchild_#{workspace_id}",
      plan_id: "mgr_plan",
      task_id: "task",
      attempt: 0,
      round_id: "round",
      shot_id: "shot",
      parent_session_id: "parent",
      delegated_session_id: "session-child",
      workspace_id: workspace_id,
      task: %{agent: "codex"},
      budget: Budget.zero(),
      created_at: ~U[2026-08-11 11:00:00Z]
    }
  end

  defp repository_fixture do
    repository = temp_dir("workspace-finalizer-repo")
    git!(repository, ["init", "--quiet"])
    git!(repository, ["config", "user.name", "Test"])
    git!(repository, ["config", "user.email", "test@localhost"])
    File.write!(Path.join(repository, "base.txt"), "base")
    git!(repository, ["add", "--all"])
    git!(repository, ["commit", "--quiet", "-m", "base"])
    repository
  end

  defp git!(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
  end

  defp temp_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
