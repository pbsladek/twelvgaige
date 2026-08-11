defmodule Twelvgaige.Workspace.ManagerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.Manager
  alias Twelvgaige.Workspace.Operation
  alias Twelvgaige.Workspace.DirectApply
  alias Twelvgaige.Workspace.Transport
  alias Twelvgaige.Artifact.Store, as: ArtifactStore
  alias Twelvgaige.Lifecycle.FaultEvidence
  alias Twelvgaige.Operations.Store, as: OperationsStore

  test "copy snapshots contain complete source, enforce one writer, and quarantine policy output" do
    root = temp_dir("manager")
    repository = temp_dir("repository")
    System.cmd("git", ["-C", repository, "init", "--quiet"])
    System.cmd("git", ["-C", repository, "config", "user.name", "Test"])
    System.cmd("git", ["-C", repository, "config", "user.email", "test@localhost"])
    File.mkdir_p!(Path.join(repository, "lib"))
    File.write!(Path.join(repository, "lib/allowed.txt"), "allowed")
    File.write!(Path.join(repository, "secret.txt"), "excluded")
    System.cmd("git", ["-C", repository, "add", "--all"])
    System.cmd("git", ["-C", repository, "commit", "--quiet", "-m", "base"])

    manager = start_supervised!({Manager, name: nil, root: root})

    assert {:ok, workspace} =
             Manager.create(repository,
               server: manager,
               transport: :copy_snapshot,
               allowed_paths: ["lib"]
             )

    assert File.exists?(Path.join(workspace.path, "lib/allowed.txt"))
    assert File.exists?(Path.join(workspace.path, "secret.txt"))
    assert workspace.workspace_baseline_commit == workspace.base_commit

    File.write!(Path.join(workspace.path, "result.txt"), "declared result")
    export_root = temp_dir("export")
    assert {:ok, [_path]} = Transport.export_declared(workspace, ["result.txt"], export_root)
    assert File.read!(Path.join(export_root, "result.txt")) == "declared result"

    assert {:error, {"../escape", :path_traversal}} =
             Transport.export_declared(workspace, ["../escape"], export_root)

    assert %{mode: :copy, writable_host_mount: false} = Transport.mount_contract(workspace)

    assert {:ok, _workspace} = Manager.bind_owner(workspace.id, "session-1", server: manager)

    assert {:error, :workspace_writer_already_leased} =
             Manager.bind_owner(workspace.id, "session-2", server: manager)

    assert {:error, :workspace_writer_not_quiesced} =
             Manager.finalize(workspace.id, server: manager)

    assert {:ok, quiesced} =
             Manager.quiesce(
               workspace.id,
               %{
                 runtime_stopped: true,
                 runtime_identity: "test-runtime",
                 stopped_at: ~U[2026-08-11 12:00:00Z]
               },
               server: manager
             )

    assert quiesced.state == :quiesced

    assert {:ok, finalized, report} = Manager.finalize(workspace.id, server: manager)
    assert finalized.state == :quarantined
    assert finalized.result_manifest.outcomes["policy_compliance"] == "rejected"
    assert report.integrity == :verified
    assert Enum.any?(report.out_of_policy, &(&1["status"] == "added"))

    assert {:error, :bind_worktree_requires_interactive} =
             Manager.create(repository, server: manager, transport: :bind_worktree)

    assert {:error, :workspace_id_conflict} =
             Manager.create(repository,
               server: manager,
               workspace_id: workspace.id,
               transport: :copy_snapshot
             )

    assert {:error, :workspace_id_invalid} =
             Manager.create(repository,
               server: manager,
               workspace_id: "../escape",
               transport: :copy_snapshot
             )
  end

  test "finalization persists the verified result before releasing the workspace" do
    root = temp_dir("artifact-manager")
    repository = temp_dir("artifact-repository")
    System.cmd("git", ["-C", repository, "init", "--quiet"])
    System.cmd("git", ["-C", repository, "config", "user.name", "Test"])
    System.cmd("git", ["-C", repository, "config", "user.email", "test@localhost"])
    File.write!(Path.join(repository, "base.txt"), "base")
    System.cmd("git", ["-C", repository, "add", "--all"])
    System.cmd("git", ["-C", repository, "commit", "--quiet", "-m", "base"])

    artifact_store =
      start_supervised!(
        {ArtifactStore,
         name: nil, root: Path.join(root, "artifacts"), key: :crypto.strong_rand_bytes(32)},
        id: :workspace_artifact_store
      )

    manager =
      start_supervised!(
        {Manager, name: nil, root: Path.join(root, "workspaces"), artifact_store: artifact_store},
        id: :workspace_artifact_manager
      )

    assert {:ok, workspace} = Manager.create(repository, server: manager)
    assert {:ok, _workspace} = Manager.bind_owner(workspace.id, "session-result", server: manager)
    File.write!(Path.join(workspace.path, "result.txt"), "captured")

    assert {:ok, _workspace} =
             Manager.quiesce(
               workspace.id,
               %{
                 runtime_stopped: true,
                 runtime_identity: "sandbox-result",
                 stopped_at: ~U[2026-08-11 12:00:00Z]
               },
               server: manager
             )

    assert {:ok, finalized, report} = Manager.finalize(workspace.id, server: manager)
    assert finalized.state == :reviewable
    assert DateTime.diff(finalized.retention_expires_at, finalized.finalized_at, :day) == 7
    assert finalized.result_artifact_ref == report.artifact_ref
    assert report.manifest.outcomes["artifact_integrity"] == "verified"

    assert {:ok, %{manifest: stored_manifest, patch: patch, bundle: nil}} =
             ArtifactStore.get(report.artifact_ref, server: artifact_store)

    assert stored_manifest.manifest_digest == report.manifest.manifest_digest
    assert patch =~ "result.txt"

    assert {:ok, cleanup_plan} = Manager.cleanup(workspace.id, server: manager)
    assert cleanup_plan.dry_run
    assert cleanup_plan.path == workspace.path
    assert cleanup_plan.bytes > 0
    assert File.dir?(workspace.path)

    assert {:error, :workspace_cleanup_confirmation_required} =
             Manager.cleanup(workspace.id,
               server: manager,
               write: true,
               expected_epoch: finalized.control_epoch
             )

    cleanup_opts = [
      server: manager,
      write: true,
      yes: true,
      expected_epoch: finalized.control_epoch,
      request_id: "request-cleanup-result"
    ]

    assert {:ok, cleanup} = Manager.cleanup(workspace.id, cleanup_opts)
    refute cleanup.dry_run
    assert cleanup.deleted
    refute File.exists?(workspace.path)

    assert {:ok, replayed_cleanup} = Manager.cleanup(workspace.id, cleanup_opts)
    assert replayed_cleanup.replayed

    assert {:ok, %{manifest: ^stored_manifest, patch: ^patch, bundle: nil}} =
             ArtifactStore.get(report.artifact_ref, server: artifact_store)

    assert {:ok, %{state: :deleted}} = Manager.get(workspace.id, server: manager)
  end

  test "restart recovers durable workspace identity and quarantines an unknown writer" do
    root = temp_dir("durable-manager")
    repository = temp_dir("durable-repository")
    System.cmd("git", ["-C", repository, "init", "--quiet"])
    System.cmd("git", ["-C", repository, "config", "user.name", "Test"])
    System.cmd("git", ["-C", repository, "config", "user.email", "test@localhost"])
    File.write!(Path.join(repository, "base.txt"), "base")
    System.cmd("git", ["-C", repository, "add", "--all"])
    System.cmd("git", ["-C", repository, "commit", "--quiet", "-m", "base"])

    store =
      start_supervised!(
        {OperationsStore, name: nil, path: Path.join(root, "operations.sqlite3")},
        id: :workspace_durable_store
      )

    manager_opts = [
      name: nil,
      root: Path.join(root, "workspaces"),
      operations_store: store
    ]

    manager = start_supervised!({Manager, manager_opts}, id: :workspace_durable_manager)
    assert {:ok, workspace} = Manager.create(repository, server: manager)
    assert {:ok, running} = Manager.bind_owner(workspace.id, "session-live", server: manager)
    assert running.state == :running

    assert :ok = stop_supervised(:workspace_durable_manager)

    restarted =
      start_supervised!({Manager, manager_opts}, id: :workspace_durable_manager_restarted)

    assert {:ok, recovered} = Manager.get(workspace.id, server: restarted)
    assert recovered.path == workspace.path
    assert recovered.base_commit == workspace.base_commit
    assert recovered.state == :quarantined
    assert recovered.quarantine_reason == :workspace_restart_writer_unknown

    assert {:error, :workspace_not_bindable} =
             Manager.bind_owner(workspace.id, "session-other", server: restarted)

    assert {:ok, [listed]} = Manager.list(server: restarted)
    assert listed.id == workspace.id
  end

  test "staged source is part of the handoff patch but is not reported as agent work" do
    root = temp_dir("staged-manager")
    repository = temp_dir("staged-manager-repository")
    System.cmd("git", ["-C", repository, "init", "--quiet"])
    System.cmd("git", ["-C", repository, "config", "user.name", "Test"])
    System.cmd("git", ["-C", repository, "config", "user.email", "test@localhost"])
    File.write!(Path.join(repository, "base.txt"), "base")
    System.cmd("git", ["-C", repository, "add", "--all"])
    System.cmd("git", ["-C", repository, "commit", "--quiet", "-m", "base"])
    File.write!(Path.join(repository, "staged.txt"), "developer input")
    System.cmd("git", ["-C", repository, "add", "staged.txt"])

    manager = start_supervised!({Manager, name: nil, root: root}, id: :staged_workspace_manager)

    assert {:ok, workspace} =
             Manager.create(repository, server: manager, source_mode: :staged)

    assert workspace.source_mode == :staged
    refute workspace.workspace_baseline_commit == workspace.base_commit
    assert {:ok, _workspace} = Manager.bind_owner(workspace.id, "session-staged", server: manager)

    assert {:ok, _workspace} =
             Manager.quiesce(
               workspace.id,
               %{
                 runtime_stopped: true,
                 runtime_identity: "sandbox-staged",
                 stopped_at: ~U[2026-08-11 12:00:00Z]
               },
               server: manager
             )

    assert {:ok, finalized, report} = Manager.finalize(workspace.id, server: manager)
    assert finalized.result_manifest.no_change
    assert report.patch =~ "staged.txt"
    assert report.changed_paths != []
  end

  test "workspace creation is replay-safe by request ID and rejects changed intent" do
    root = temp_dir("idempotent-manager")
    repository = git_repository("idempotent-repository")

    store =
      start_supervised!(
        {OperationsStore, name: nil, path: Path.join(root, "operations.sqlite3")},
        id: :workspace_idempotent_store
      )

    manager =
      start_supervised!(
        {Manager, name: nil, root: Path.join(root, "workspaces"), operations_store: store},
        id: :workspace_idempotent_manager
      )

    opts = [
      server: manager,
      workspace_id: "ws_idempotent",
      request_id: "request-create-idempotent"
    ]

    assert {:ok, first} = Manager.create(repository, opts)
    assert {:ok, replayed} = Manager.create(repository, opts)
    assert replayed.id == first.id
    assert replayed.path == first.path
    assert replayed.creation_operation_id == first.creation_operation_id

    assert {:error, :workspace_idempotency_conflict} =
             Manager.create(repository, Keyword.put(opts, :base_ref, "HEAD~1"))

    assert {:ok, operation} =
             Manager.get_operation("request-create-idempotent", server: manager)

    assert operation.status == :completed
    assert operation.result.workspace_id == first.id

    finalize_opts = [
      server: manager,
      request_id: "request-finalize-idempotent",
      expected_epoch: first.control_epoch
    ]

    assert {:ok, finalized, first_report} = Manager.finalize(first.id, finalize_opts)
    assert first_report.manifest.manifest_digest == finalized.result_manifest.manifest_digest

    assert {:ok, replayed_final, replayed_report} = Manager.finalize(first.id, finalize_opts)
    assert replayed_final.id == finalized.id
    assert replayed_report.replayed
    assert replayed_report.patch == nil
    assert replayed_report.manifest.manifest_digest == first_report.manifest.manifest_digest

    assert {:error, :workspace_idempotency_conflict} =
             Manager.finalize(
               first.id,
               Keyword.put(finalize_opts, :test_verification, :failed)
             )

    assert {:ok, audit_records} =
             OperationsStore.list(:workspace_git_mutation, server: store)

    assert length(audit_records) > 10
    assert Enum.all?(audit_records, &(&1.retention_class == :security))

    audit_events = Enum.map(audit_records, & &1.value)

    assert Enum.all?(audit_events, fn event ->
             event.workspace_id == first.id and
               event.operation_id in [first.creation_operation_id, finalized.last_operation_id] and
               event.phase in [:intent, :completed, :failed] and
               is_atom(event.command_class)
           end)

    assert audit_events
           |> Enum.group_by(& &1.mutation_id, & &1.phase)
           |> Enum.all?(fn {_mutation_id, phases} ->
             Enum.sort(phases) in [[:completed, :intent], [:failed, :intent]]
           end)

    serialized = inspect(audit_events)
    refute serialized =~ repository
    refute serialized =~ "base.txt"
    refute serialized =~ "source-overlay.patch"
  end

  test "restart marks an interrupted workspace mutation for reconciliation" do
    root = temp_dir("interrupted-manager")
    repository = git_repository("interrupted-repository")

    store =
      start_supervised!(
        {OperationsStore, name: nil, path: Path.join(root, "operations.sqlite3")},
        id: :workspace_interrupted_store
      )

    manager_opts = [
      name: nil,
      root: Path.join(root, "workspaces"),
      operations_store: store
    ]

    manager = start_supervised!({Manager, manager_opts}, id: :workspace_interrupted_manager)

    assert {:ok, workspace} =
             Manager.create(repository,
               server: manager,
               workspace_id: "ws_interrupted_base",
               request_id: "request-create-base"
             )

    operation =
      Operation.new(
        :finalize,
        workspace.id,
        %{
          "kind" => "finalize",
          "workspace_id" => workspace.id,
          "expected_epoch" => workspace.control_epoch
        },
        request_id: "request-interrupted-finalize"
      )
      |> Operation.transition(:side_effects_started)

    assert :ok =
             OperationsStore.put(:workspace_operation, operation.request_id, operation,
               server: store,
               retention_class: :security
             )

    assert :ok = stop_supervised(:workspace_interrupted_manager)

    restarted =
      start_supervised!({Manager, manager_opts}, id: :workspace_interrupted_manager_restarted)

    assert {:ok, recovered_operation} =
             Manager.get_operation(operation.request_id, server: restarted)

    assert recovered_operation.status == :needs_reconciliation
    assert recovered_operation.error == :workspace_operation_interrupted

    assert {:ok, recovered_workspace} = Manager.get(workspace.id, server: restarted)
    assert recovered_workspace.state == :needs_reconciliation

    assert recovered_workspace.quarantine_reason ==
             {:workspace_operation_interrupted, operation.request_id}
  end

  test "crash after atomic export publication preserves the result and requires explicit reconciliation" do
    root = temp_dir("export-publish-crash")
    repository = git_repository("export-publish-crash-repository")

    store =
      start_supervised!(
        {OperationsStore, name: nil, path: Path.join(root, "operations.sqlite3")},
        id: :workspace_export_crash_store
      )

    artifact_store =
      start_supervised!(
        {ArtifactStore,
         name: nil, root: Path.join(root, "artifacts"), key: :crypto.strong_rand_bytes(32)},
        id: :workspace_export_crash_artifacts
      )

    fault = fn event ->
      if event.id == "export.export_publish.after", do: exit(:simulated_export_crash), else: :ok
    end

    manager_opts = [
      name: nil,
      root: Path.join(root, "workspaces"),
      operations_store: store,
      artifact_store: artifact_store,
      fault_checkpoint_fun: fault
    ]

    {:ok, manager} = Manager.start_link(manager_opts)
    Process.unlink(manager)

    assert {:ok, workspace} =
             Manager.create(repository,
               server: manager,
               workspace_id: "ws_export_crash",
               request_id: "request-export-crash-create"
             )

    File.write!(Path.join(workspace.path, "exported.txt"), "preserved result\n")

    assert {:ok, finalized, _report} =
             Manager.finalize(workspace.id,
               server: manager,
               request_id: "request-export-crash-finalize"
             )

    destination = Path.join(root, "published-result")
    monitor = Process.monitor(manager)

    ExUnit.CaptureLog.capture_log(fn ->
      assert catch_exit(
               Manager.export(finalized.id, destination,
                 server: manager,
                 write?: true,
                 request_id: "request-export-crash"
               )
             )
    end)

    assert_receive {:DOWN, ^monitor, :process, ^manager, :simulated_export_crash}
    assert File.regular?(Path.join(destination, "manifest.json"))
    assert File.regular?(Path.join(destination, "result.patch"))

    restart_opts = Keyword.delete(manager_opts, :fault_checkpoint_fun)
    {:ok, restarted} = Manager.start_link(restart_opts)
    Process.unlink(restarted)

    assert {:ok, operation} =
             Manager.get_operation("request-export-crash", server: restarted)

    assert operation.status == :needs_reconciliation
    assert operation.error == :workspace_operation_interrupted

    assert {:ok, recovered} = Manager.get(finalized.id, server: restarted)
    assert recovered.state == :needs_reconciliation

    assert recovered.quarantine_reason ==
             {:workspace_operation_interrupted, "request-export-crash"}

    assert {:ok, recovery} = Manager.reconcile(recovered.id, server: restarted)
    assert recovery.interrupted_kind == :export
    assert Enum.any?(recovery.recovery_commands, &String.contains?(&1, "workspace export"))
    assert recovery.export_resume.available

    reconcile_opts = [
      server: restarted,
      write?: true,
      yes?: true,
      action: :resume_export,
      expected_epoch: recovered.control_epoch,
      request_id: "request-export-crash-reconcile"
    ]

    assert {:ok, resumed} = Manager.reconcile(recovered.id, reconcile_opts)
    assert resumed.action == :resume_export
    assert resumed.resumed
    assert resumed.state == :reviewable

    assert {:ok, replayed_resume} = Manager.reconcile(recovered.id, reconcile_opts)
    assert replayed_resume.replayed

    GenServer.stop(restarted)
  end

  test "public workspace lifecycles emit both sides of every successful external boundary" do
    root = temp_dir("lifecycle-boundaries")
    repository = git_repository("lifecycle-boundaries-repository")

    store =
      start_supervised!(
        {OperationsStore, name: nil, path: Path.join(root, "operations.sqlite3")},
        id: :workspace_lifecycle_boundary_store
      )

    artifact_store =
      start_supervised!(
        {ArtifactStore,
         name: nil, root: Path.join(root, "artifacts"), key: :crypto.strong_rand_bytes(32)},
        id: :workspace_lifecycle_boundary_artifacts
      )

    checkpoints = start_supervised!({Agent, fn -> [] end}, id: :workspace_lifecycle_checkpoints)

    manager =
      start_supervised!(
        {Manager,
         name: nil,
         root: Path.join(root, "workspaces"),
         operations_store: store,
         artifact_store: artifact_store,
         fault_checkpoint_fun: fn event ->
           Agent.update(checkpoints, &[event.id | &1])
           :ok
         end},
        id: :workspace_lifecycle_boundary_manager
      )

    assert {:ok, workspace} =
             Manager.create(repository,
               server: manager,
               workspace_id: "ws_lifecycle_boundaries",
               request_id: "request-lifecycle-create"
             )

    File.write!(Path.join(workspace.path, "result.txt"), "lifecycle result\n")

    assert {:ok, finalized, _report} =
             Manager.finalize(workspace.id,
               server: manager,
               request_id: "request-lifecycle-finalize"
             )

    assert {:ok, _export} =
             Manager.export(finalized.id, Path.join(root, "export"),
               server: manager,
               write?: true,
               request_id: "request-lifecycle-export"
             )

    assert {:ok, review} =
             Manager.apply(finalized.id,
               server: manager,
               write?: true,
               yes?: true,
               expected_epoch: finalized.control_epoch,
               request_id: "request-lifecycle-review"
             )

    assert {:ok, after_review_cleanup} =
             Manager.cleanup_review(finalized.id,
               server: manager,
               write?: true,
               yes?: true,
               expected_epoch: review.control_epoch,
               request_id: "request-lifecycle-review-cleanup"
             )

    assert after_review_cleanup.removed

    assert {:ok, direct} =
             Manager.apply(finalized.id,
               server: manager,
               target: :current_worktree,
               write?: true,
               yes?: true,
               expected_epoch: after_review_cleanup.control_epoch,
               request_id: "request-lifecycle-direct"
             )

    assert direct.verified_result_tree == finalized.result_manifest.result_tree

    assert {:ok, cleanup} =
             Manager.cleanup(finalized.id,
               server: manager,
               write: true,
               yes: true,
               expected_epoch: direct.control_epoch,
               request_id: "request-lifecycle-cleanup"
             )

    assert cleanup.deleted

    checkpoint_ids = checkpoints |> Agent.get(& &1) |> MapSet.new()

    successful_boundaries = %{
      create: [
        :intent_persist,
        :side_effects_started_persist,
        :workspace_materialize,
        :workspace_record_persist,
        :completed_persist
      ],
      capture: [:result_tree_capture, :commit_bundle_capture],
      finalize: [
        :intent_persist,
        :side_effects_started_persist,
        :artifact_publish,
        :workspace_record_persist,
        :completed_persist
      ],
      export: [
        :intent_persist,
        :side_effects_started_persist,
        :export_stage,
        :export_publish,
        :completed_persist
      ],
      review_apply: [
        :intent_persist,
        :side_effects_started_persist,
        :review_registration,
        :review_patch_apply,
        :review_result_verify,
        :workspace_record_persist,
        :completed_persist
      ],
      review_cleanup: [
        :intent_persist,
        :side_effects_started_persist,
        :review_registration_remove,
        :workspace_record_persist,
        :completed_persist
      ],
      direct_apply: [
        :intent_persist,
        :side_effects_started_persist,
        :backup_publish,
        :current_worktree_patch_apply,
        :current_worktree_result_verify,
        :workspace_record_persist,
        :completed_persist
      ],
      cleanup: [
        :intent_persist,
        :side_effects_started_persist,
        :managed_path_remove,
        :workspace_record_persist,
        :completed_persist
      ]
    }

    for {lifecycle, boundaries} <- successful_boundaries,
        boundary <- boundaries,
        position <- [:before, :after] do
      assert "#{lifecycle}.#{boundary}.#{position}" in checkpoint_ids
    end
  end

  @tag :fault_matrix
  test "create fault matrix terminates before and after every successful boundary" do
    repository = git_repository("create-fault-matrix-repository")

    boundaries = [
      :intent_persist,
      :side_effects_started_persist,
      :workspace_materialize,
      :workspace_record_persist,
      :completed_persist
    ]

    for boundary <- boundaries, position <- [:before, :after] do
      target = "create.#{boundary}.#{position}"
      root = temp_dir("create-fault-#{boundary}-#{position}")
      store_path = Path.join(root, "operations.sqlite3")
      {:ok, store} = OperationsStore.start_link(name: nil, path: store_path)
      Process.unlink(store)

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        fault_checkpoint_fun: fn event ->
          if event.id == target, do: exit({:simulated_create_crash, target}), else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)
      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.create(repository,
                   server: manager,
                   workspace_id: "ws_create_fault",
                   request_id: "request-create-fault"
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager, {:simulated_create_crash, ^target}}

      restart_opts = Keyword.delete(manager_opts, :fault_checkpoint_fun)
      {:ok, restarted} = Manager.start_link(restart_opts)
      Process.unlink(restarted)

      cond do
        boundary in [:intent_persist, :side_effects_started_persist] or
            {boundary, position} == {:workspace_materialize, :before} ->
          assert {:ok, retried} =
                   Manager.create(repository,
                     server: restarted,
                     workspace_id: "ws_create_fault",
                     request_id: "request-create-fault"
                   )

          assert retried.state == :ready

        {boundary, position} == {:completed_persist, :after} ->
          assert {:ok, replayed} =
                   Manager.create(repository,
                     server: restarted,
                     workspace_id: "ws_create_fault",
                     request_id: "request-create-fault"
                   )

          assert replayed.state == :ready

        true ->
          assert {:ok, operation} =
                   Manager.get_operation("request-create-fault", server: restarted)

          assert operation.status == :needs_reconciliation

          assert {:ok, recovered} = Manager.get("ws_create_fault", server: restarted)
          assert recovered.state == :needs_reconciliation
      end

      outcome =
        if boundary in [:intent_persist, :side_effects_started_persist] or
             {boundary, position} in [
               {:workspace_materialize, :before},
               {:completed_persist, :after}
             ],
           do: :safe_resume,
           else: :needs_reconciliation

      FaultEvidence.record_case(target, outcome, %{suite: "workspace_manager"})

      GenServer.stop(restarted)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "finalize fault matrix terminates before and after every successful boundary" do
    repository = git_repository("finalize-fault-matrix-repository")

    boundaries = [
      {:finalize, :intent_persist},
      {:finalize, :side_effects_started_persist},
      {:capture, :result_tree_capture},
      {:capture, :commit_bundle_capture},
      {:finalize, :artifact_publish},
      {:finalize, :workspace_record_persist},
      {:finalize, :completed_persist}
    ]

    for {lifecycle, boundary} <- boundaries, position <- [:before, :after] do
      target = "#{lifecycle}.#{boundary}.#{position}"
      root = temp_dir("finalize-fault-#{boundary}-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      {:ok, artifact_store} =
        ArtifactStore.start_link(
          name: nil,
          root: Path.join(root, "artifacts"),
          key: :crypto.strong_rand_bytes(32)
        )

      Process.unlink(artifact_store)

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        artifact_store: artifact_store,
        fault_checkpoint_fun: fn event ->
          if event.id == target, do: exit({:simulated_finalize_crash, target}), else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: manager,
                 workspace_id: "ws_finalize_fault",
                 request_id: "request-finalize-fault-create"
               )

      File.write!(Path.join(workspace.path, "result.txt"), "finalize fault result\n")
      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.finalize(workspace.id,
                   server: manager,
                   request_id: "request-finalize-fault"
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager, {:simulated_finalize_crash, ^target}}

      restart_opts = Keyword.delete(manager_opts, :fault_checkpoint_fun)
      {:ok, restarted} = Manager.start_link(restart_opts)
      Process.unlink(restarted)

      cond do
        {lifecycle, boundary, position} == {:finalize, :intent_persist, :before} ->
          assert {:ok, finalized, report} =
                   Manager.finalize(workspace.id,
                     server: restarted,
                     request_id: "request-finalize-fault"
                   )

          assert finalized.state == :reviewable
          assert report.integrity == :verified

        {lifecycle, boundary, position} == {:finalize, :completed_persist, :after} ->
          assert {:ok, finalized, report} =
                   Manager.finalize(workspace.id,
                     server: restarted,
                     request_id: "request-finalize-fault"
                   )

          assert finalized.state == :reviewable
          assert report.replayed

        true ->
          assert {:ok, operation} =
                   Manager.get_operation("request-finalize-fault", server: restarted)

          assert operation.status == :needs_reconciliation

          assert {:ok, recovered} = Manager.get(workspace.id, server: restarted)
          assert recovered.state == :needs_reconciliation

          assert {:ok, recovery} = Manager.reconcile(workspace.id, server: restarted)
          assert recovery.interrupted_kind == :finalize
      end

      outcome =
        if {lifecycle, boundary, position} in [
             {:finalize, :intent_persist, :before},
             {:finalize, :completed_persist, :after}
           ],
           do: :safe_resume,
           else: :needs_reconciliation

      FaultEvidence.record_case(target, outcome, %{suite: "workspace_manager"})

      GenServer.stop(restarted)
      GenServer.stop(artifact_store)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "export fault matrix resumes safely before and after every successful boundary" do
    repository = git_repository("export-fault-matrix-repository")

    boundaries = [
      :intent_persist,
      :side_effects_started_persist,
      :export_stage,
      :export_publish,
      :completed_persist
    ]

    for boundary <- boundaries, position <- [:before, :after] do
      target = "export.#{boundary}.#{position}"
      root = temp_dir("export-fault-#{boundary}-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      {:ok, artifact_store} =
        ArtifactStore.start_link(
          name: nil,
          root: Path.join(root, "artifacts"),
          key: :crypto.strong_rand_bytes(32)
        )

      Process.unlink(artifact_store)

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        artifact_store: artifact_store,
        fault_checkpoint_fun: fn event ->
          if event.id == target, do: exit({:simulated_export_crash, target}), else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: manager,
                 workspace_id: "ws_export_fault",
                 request_id: "request-export-fault-create"
               )

      File.write!(Path.join(workspace.path, "result.txt"), "export fault result\n")

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: manager,
                 request_id: "request-export-fault-finalize"
               )

      destination = Path.join(root, "exported-result")
      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.export(finalized.id, destination,
                   server: manager,
                   write?: true,
                   request_id: "request-export-fault"
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager, {:simulated_export_crash, ^target}}

      restart_opts = Keyword.delete(manager_opts, :fault_checkpoint_fun)
      {:ok, restarted} = Manager.start_link(restart_opts)
      Process.unlink(restarted)

      cond do
        {boundary, position} == {:intent_persist, :before} ->
          assert {:ok, exported} =
                   Manager.export(finalized.id, destination,
                     server: restarted,
                     write?: true,
                     request_id: "request-export-fault"
                   )

          refute exported.dry_run

        {boundary, position} == {:completed_persist, :after} ->
          assert {:ok, replayed} =
                   Manager.export(finalized.id, destination,
                     server: restarted,
                     write?: true,
                     request_id: "request-export-fault"
                   )

          assert replayed.replayed

        true ->
          assert {:ok, recovered} = Manager.get(finalized.id, server: restarted)
          assert recovered.state == :needs_reconciliation

          assert {:ok, preview} = Manager.reconcile(recovered.id, server: restarted)
          assert preview.export_resume.available
          assert preview.export_resume.destination == destination

          assert {:ok, resumed} =
                   Manager.reconcile(recovered.id,
                     server: restarted,
                     write?: true,
                     yes?: true,
                     action: :resume_export,
                     expected_epoch: recovered.control_epoch,
                     request_id: "request-export-fault-reconcile"
                   )

          assert resumed.action == :resume_export
          assert resumed.state == :reviewable
          assert resumed.resumed
      end

      assert File.regular?(Path.join(destination, "manifest.json"))
      assert File.regular?(Path.join(destination, "result.patch"))
      FaultEvidence.record_case(target, :safe_resume, %{suite: "workspace_manager"})
      GenServer.stop(restarted)
      GenServer.stop(artifact_store)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "export reconciliation persists workspace state before and after interruption" do
    for position <- [:before, :after] do
      target = "export.workspace_record_persist.#{position}"
      repository = git_repository("export-record-fault-#{position}-repository")
      root = temp_dir("export-record-fault-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      {:ok, artifact_store} =
        ArtifactStore.start_link(
          name: nil,
          root: Path.join(root, "artifacts"),
          key: :crypto.strong_rand_bytes(32)
        )

      Process.unlink(artifact_store)

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        artifact_store: artifact_store,
        fault_checkpoint_fun: fn event ->
          cond do
            event.id == "export.completed_persist.before" -> {:error, :force_reconciliation}
            event.id == target -> exit({:simulated_export_record_crash, target})
            true -> :ok
          end
        end
      ]

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: manager,
                 workspace_id: "ws_export_record_fault",
                 request_id: "request-export-record-create"
               )

      File.write!(Path.join(workspace.path, "result.txt"), "export record result\n")

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: manager,
                 request_id: "request-export-record-finalize"
               )

      destination = Path.join(root, "exported-result")
      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.export(finalized.id, destination,
                   server: manager,
                   write?: true,
                   request_id: "request-export-record"
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager,
                      {:simulated_export_record_crash, ^target}}

      {:ok, restarted} =
        Manager.start_link(Keyword.delete(manager_opts, :fault_checkpoint_fun))

      Process.unlink(restarted)
      assert {:ok, recovered} = Manager.get(finalized.id, server: restarted)
      assert recovered.state == :needs_reconciliation
      assert {:ok, preview} = Manager.reconcile(recovered.id, server: restarted)
      assert preview.export_resume.available

      assert {:ok, resumed} =
               Manager.reconcile(recovered.id,
                 server: restarted,
                 write?: true,
                 yes?: true,
                 action: :resume_export,
                 expected_epoch: recovered.control_epoch,
                 request_id: "request-export-record-reconcile"
               )

      assert resumed.state == :reviewable
      assert File.regular?(Path.join(destination, "manifest.json"))
      assert File.regular?(Path.join(destination, "result.patch"))
      FaultEvidence.record_case(target, :safe_resume, %{suite: "workspace_manager"})
      GenServer.stop(restarted)
      GenServer.stop(artifact_store)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "cleanup fault matrix converges to durable deletion at every successful boundary" do
    repository = git_repository("cleanup-fault-matrix-repository")

    boundaries = [
      :intent_persist,
      :side_effects_started_persist,
      :managed_path_remove,
      :workspace_record_persist,
      :completed_persist
    ]

    for boundary <- boundaries, position <- [:before, :after] do
      target = "cleanup.#{boundary}.#{position}"
      root = temp_dir("cleanup-fault-#{boundary}-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        fault_checkpoint_fun: fn event ->
          if event.id == target, do: exit({:simulated_cleanup_crash, target}), else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: manager,
                 workspace_id: "ws_cleanup_fault",
                 request_id: "request-cleanup-fault-create"
               )

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: manager,
                 request_id: "request-cleanup-fault-finalize"
               )

      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.cleanup(finalized.id,
                   server: manager,
                   write: true,
                   yes: true,
                   expected_epoch: finalized.control_epoch,
                   request_id: "request-cleanup-fault"
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager, {:simulated_cleanup_crash, ^target}}

      restart_opts = Keyword.delete(manager_opts, :fault_checkpoint_fun)
      {:ok, restarted} = Manager.start_link(restart_opts)
      Process.unlink(restarted)

      cond do
        {boundary, position} == {:intent_persist, :before} ->
          assert {:ok, cleaned} =
                   Manager.cleanup(finalized.id,
                     server: restarted,
                     write: true,
                     yes: true,
                     expected_epoch: finalized.control_epoch,
                     request_id: "request-cleanup-fault"
                   )

          assert cleaned.deleted

        {boundary, position} == {:completed_persist, :after} ->
          assert {:ok, replayed} =
                   Manager.cleanup(finalized.id,
                     server: restarted,
                     write: true,
                     yes: true,
                     expected_epoch: finalized.control_epoch,
                     request_id: "request-cleanup-fault"
                   )

          assert replayed.replayed

        true ->
          assert {:ok, recovered} = Manager.get(finalized.id, server: restarted)
          assert recovered.state == :needs_reconciliation

          assert {:ok, preview} = Manager.reconcile(recovered.id, server: restarted)
          assert preview.cleanup_resume.available

          assert {:ok, resumed} =
                   Manager.reconcile(recovered.id,
                     server: restarted,
                     write?: true,
                     yes?: true,
                     action: :resume_cleanup,
                     expected_epoch: recovered.control_epoch,
                     request_id: "request-cleanup-fault-reconcile"
                   )

          assert resumed.action == :resume_cleanup
          assert resumed.state == :deleted
          assert resumed.deleted
      end

      assert {:ok, deleted} = Manager.get(finalized.id, server: restarted)
      assert deleted.state == :deleted
      refute File.exists?(finalized.path)
      FaultEvidence.record_case(target, :safe_resume, %{suite: "workspace_manager"})
      GenServer.stop(restarted)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "retention cleanup uses the same interruption-safe deletion matrix" do
    repository = git_repository("retention-fault-matrix-repository")
    finalized_at = ~U[2026-08-11 12:00:00Z]
    sweep_at = DateTime.add(finalized_at, 1, :second)

    boundaries = [
      :intent_persist,
      :side_effects_started_persist,
      :managed_path_remove,
      :workspace_record_persist,
      :completed_persist
    ]

    for boundary <- boundaries, position <- [:before, :after] do
      target = "retention_cleanup.#{boundary}.#{position}"
      root = temp_dir("retention-fault-#{boundary}-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        workspace_retention_days: 0,
        retention_interval_ms: :infinity,
        fault_checkpoint_fun: fn event ->
          if event.id == target, do: exit({:simulated_retention_crash, target}), else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: manager,
                 workspace_id: "ws_retention_fault",
                 request_id: "request-retention-fault-create",
                 now: finalized_at
               )

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: manager,
                 request_id: "request-retention-fault-finalize",
                 now: finalized_at
               )

      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(Manager.run_retention(server: manager, now: sweep_at))
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager, {:simulated_retention_crash, ^target}}

      restart_opts = Keyword.delete(manager_opts, :fault_checkpoint_fun)
      {:ok, restarted} = Manager.start_link(restart_opts)
      Process.unlink(restarted)

      cond do
        {boundary, position} == {:intent_persist, :before} ->
          assert {:ok, report} = Manager.run_retention(server: restarted, now: sweep_at)
          assert [%{workspace_id: "ws_retention_fault", deleted: true}] = report.removed

        {boundary, position} == {:completed_persist, :after} ->
          assert {:ok, deleted} = Manager.get(finalized.id, server: restarted)
          assert deleted.state == :deleted

        true ->
          assert {:ok, recovered} = Manager.get(finalized.id, server: restarted)
          assert recovered.state == :needs_reconciliation

          assert {:ok, preview} = Manager.reconcile(recovered.id, server: restarted)
          assert preview.cleanup_resume.available

          assert {:ok, resumed} =
                   Manager.reconcile(recovered.id,
                     server: restarted,
                     write?: true,
                     yes?: true,
                     action: :resume_cleanup,
                     expected_epoch: recovered.control_epoch,
                     request_id: "request-retention-fault-reconcile"
                   )

          assert resumed.state == :deleted
      end

      assert {:ok, deleted} = Manager.get(finalized.id, server: restarted)
      assert deleted.state == :deleted
      refute File.exists?(finalized.path)
      FaultEvidence.record_case(target, :safe_resume, %{suite: "workspace_manager"})
      GenServer.stop(restarted)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "direct apply fault matrix restores or quarantines every successful boundary" do
    boundaries = [
      :intent_persist,
      :side_effects_started_persist,
      :backup_publish,
      :current_worktree_patch_apply,
      :current_worktree_result_verify,
      :workspace_record_persist,
      :completed_persist
    ]

    for boundary <- boundaries, position <- [:before, :after] do
      target = "direct_apply.#{boundary}.#{position}"
      repository = git_repository("direct-apply-fault-#{boundary}-#{position}-repository")
      root = temp_dir("direct-apply-fault-#{boundary}-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      {:ok, artifact_store} =
        ArtifactStore.start_link(
          name: nil,
          root: Path.join(root, "artifacts"),
          key: :crypto.strong_rand_bytes(32)
        )

      Process.unlink(artifact_store)

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        artifact_store: artifact_store,
        fault_checkpoint_fun: fn event ->
          if event.id == target, do: exit({:simulated_direct_apply_crash, target}), else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: manager,
                 workspace_id: "ws_direct_apply_fault",
                 request_id: "request-direct-apply-fault-create"
               )

      File.write!(Path.join(workspace.path, "applied.txt"), "direct apply fault result\n")

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: manager,
                 request_id: "request-direct-apply-fault-finalize"
               )

      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.apply(finalized.id,
                   server: manager,
                   target: :current_worktree,
                   write?: true,
                   yes?: true,
                   expected_epoch: finalized.control_epoch,
                   request_id: "request-direct-apply-fault"
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager,
                      {:simulated_direct_apply_crash, ^target}}

      restart_opts = Keyword.delete(manager_opts, :fault_checkpoint_fun)
      {:ok, restarted} = Manager.start_link(restart_opts)
      Process.unlink(restarted)

      cond do
        {boundary, position} == {:intent_persist, :before} ->
          assert {:ok, applied} =
                   Manager.apply(finalized.id,
                     server: restarted,
                     target: :current_worktree,
                     write?: true,
                     yes?: true,
                     expected_epoch: finalized.control_epoch,
                     request_id: "request-direct-apply-fault"
                   )

          assert applied.verified_result_tree == finalized.result_manifest.result_tree

        {boundary, position} == {:completed_persist, :after} ->
          assert {:ok, replayed} =
                   Manager.apply(finalized.id,
                     server: restarted,
                     target: :current_worktree,
                     write?: true,
                     yes?: true,
                     expected_epoch: finalized.control_epoch,
                     request_id: "request-direct-apply-fault"
                   )

          assert replayed.replayed

        true ->
          assert {:ok, recovered} = Manager.get(finalized.id, server: restarted)
          assert recovered.state == :needs_reconciliation
          assert {:ok, preview} = Manager.reconcile(recovered.id, server: restarted)

          if preview.restoration.available do
            assert {:ok, restored} =
                     Manager.reconcile(recovered.id,
                       server: restarted,
                       write?: true,
                       yes?: true,
                       action: :restore_backup,
                       expected_epoch: recovered.control_epoch,
                       request_id: "request-direct-apply-fault-reconcile"
                     )

            assert restored.action == :restore_backup
            assert restored.state == :reviewable
            refute File.exists?(Path.join(repository, "applied.txt"))
          else
            assert {:ok, quarantined} =
                     Manager.reconcile(recovered.id,
                       server: restarted,
                       write?: true,
                       yes?: true,
                       action: :quarantine,
                       expected_epoch: recovered.control_epoch,
                       request_id: "request-direct-apply-fault-reconcile"
                     )

            assert quarantined.state == :quarantined
            refute File.exists?(Path.join(repository, "applied.txt"))
          end
      end

      outcome =
        if {boundary, position} in [
             {:intent_persist, :before},
             {:completed_persist, :after}
           ],
           do: :safe_resume,
           else: :needs_reconciliation

      FaultEvidence.record_case(target, outcome, %{suite: "workspace_manager"})

      GenServer.stop(restarted)
      GenServer.stop(artifact_store)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "review apply fault matrix safely discards unchanged interrupted worktrees" do
    boundaries = [
      :intent_persist,
      :side_effects_started_persist,
      :review_registration,
      :review_patch_apply,
      :review_result_verify,
      :workspace_record_persist,
      :completed_persist
    ]

    for boundary <- boundaries, position <- [:before, :after] do
      target = "review_apply.#{boundary}.#{position}"
      repository = git_repository("review-apply-fault-#{boundary}-#{position}-repository")
      root = temp_dir("review-apply-fault-#{boundary}-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      {:ok, artifact_store} =
        ArtifactStore.start_link(
          name: nil,
          root: Path.join(root, "artifacts"),
          key: :crypto.strong_rand_bytes(32)
        )

      Process.unlink(artifact_store)

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        artifact_store: artifact_store,
        fault_checkpoint_fun: fn event ->
          if event.id == target, do: exit({:simulated_review_apply_crash, target}), else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: manager,
                 workspace_id: "ws_review_apply_fault",
                 request_id: "request-review-apply-fault-create"
               )

      File.write!(Path.join(workspace.path, "reviewed.txt"), "review apply fault result\n")

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: manager,
                 request_id: "request-review-apply-fault-finalize"
               )

      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.apply(finalized.id,
                   server: manager,
                   write?: true,
                   yes?: true,
                   expected_epoch: finalized.control_epoch,
                   request_id: "request-review-apply-fault"
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager,
                      {:simulated_review_apply_crash, ^target}}

      restart_opts = Keyword.delete(manager_opts, :fault_checkpoint_fun)
      {:ok, restarted} = Manager.start_link(restart_opts)
      Process.unlink(restarted)

      cond do
        {boundary, position} == {:intent_persist, :before} ->
          assert {:ok, applied} =
                   Manager.apply(finalized.id,
                     server: restarted,
                     write?: true,
                     yes?: true,
                     expected_epoch: finalized.control_epoch,
                     request_id: "request-review-apply-fault"
                   )

          assert File.dir?(applied.path)

        {boundary, position} == {:completed_persist, :after} ->
          assert {:ok, replayed} =
                   Manager.apply(finalized.id,
                     server: restarted,
                     write?: true,
                     yes?: true,
                     expected_epoch: finalized.control_epoch,
                     request_id: "request-review-apply-fault"
                   )

          assert replayed.replayed

        true ->
          assert {:ok, recovered} = Manager.get(finalized.id, server: restarted)
          assert recovered.state == :needs_reconciliation
          assert {:ok, preview} = Manager.reconcile(recovered.id, server: restarted)
          assert preview.review_discard.available

          assert {:ok, discarded} =
                   Manager.reconcile(recovered.id,
                     server: restarted,
                     write?: true,
                     yes?: true,
                     action: :discard_review,
                     expected_epoch: recovered.control_epoch,
                     request_id: "request-review-apply-fault-reconcile"
                   )

          assert discarded.action == :discard_review
          assert discarded.state == :reviewable
          refute File.exists?(discarded.review_path)
      end

      assert {:ok, ""} = Twelvgaige.Workspace.Git.SourceRead.status(repository)

      outcome =
        if {boundary, position} in [
             {:intent_persist, :before},
             {:completed_persist, :after}
           ],
           do: :safe_resume,
           else: :validated_compensation

      FaultEvidence.record_case(target, outcome, %{suite: "workspace_manager"})
      GenServer.stop(restarted)
      GenServer.stop(artifact_store)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "review cleanup fault matrix resolves both present and already-removed worktrees" do
    boundaries = [
      :intent_persist,
      :side_effects_started_persist,
      :review_registration_remove,
      :workspace_record_persist,
      :completed_persist
    ]

    for boundary <- boundaries, position <- [:before, :after] do
      target = "review_cleanup.#{boundary}.#{position}"
      repository = git_repository("review-cleanup-fault-#{boundary}-#{position}-repository")
      root = temp_dir("review-cleanup-fault-#{boundary}-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      {:ok, artifact_store} =
        ArtifactStore.start_link(
          name: nil,
          root: Path.join(root, "artifacts"),
          key: :crypto.strong_rand_bytes(32)
        )

      Process.unlink(artifact_store)

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        artifact_store: artifact_store,
        fault_checkpoint_fun: fn event ->
          if event.id == target, do: exit({:simulated_review_cleanup_crash, target}), else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: manager,
                 workspace_id: "ws_review_cleanup_fault",
                 request_id: "request-review-cleanup-fault-create"
               )

      File.write!(Path.join(workspace.path, "reviewed.txt"), "review cleanup fault result\n")

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: manager,
                 request_id: "request-review-cleanup-fault-finalize"
               )

      assert {:ok, review} =
               Manager.apply(finalized.id,
                 server: manager,
                 write?: true,
                 yes?: true,
                 expected_epoch: finalized.control_epoch,
                 request_id: "request-review-cleanup-fault-apply"
               )

      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.cleanup_review(finalized.id,
                   server: manager,
                   write?: true,
                   yes?: true,
                   expected_epoch: review.control_epoch,
                   request_id: "request-review-cleanup-fault"
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager,
                      {:simulated_review_cleanup_crash, ^target}}

      restart_opts = Keyword.delete(manager_opts, :fault_checkpoint_fun)
      {:ok, restarted} = Manager.start_link(restart_opts)
      Process.unlink(restarted)

      cond do
        {boundary, position} == {:intent_persist, :before} ->
          assert {:ok, cleaned} =
                   Manager.cleanup_review(finalized.id,
                     server: restarted,
                     write?: true,
                     yes?: true,
                     expected_epoch: review.control_epoch,
                     request_id: "request-review-cleanup-fault"
                   )

          assert cleaned.removed

        {boundary, position} == {:completed_persist, :after} ->
          assert {:ok, replayed} =
                   Manager.cleanup_review(finalized.id,
                     server: restarted,
                     write?: true,
                     yes?: true,
                     expected_epoch: review.control_epoch,
                     request_id: "request-review-cleanup-fault"
                   )

          assert replayed.replayed

        true ->
          assert {:ok, recovered} = Manager.get(finalized.id, server: restarted)
          assert recovered.state == :needs_reconciliation
          assert {:ok, preview} = Manager.reconcile(recovered.id, server: restarted)
          assert preview.review_discard.available

          assert {:ok, discarded} =
                   Manager.reconcile(recovered.id,
                     server: restarted,
                     write?: true,
                     yes?: true,
                     action: :discard_review,
                     expected_epoch: recovered.control_epoch,
                     request_id: "request-review-cleanup-fault-reconcile"
                   )

          assert discarded.state == :reviewable
          assert discarded.removed
      end

      refute File.exists?(review.path)
      assert {:ok, ""} = Twelvgaige.Workspace.Git.SourceRead.status(repository)

      outcome =
        if {boundary, position} in [
             {:intent_persist, :before},
             {:completed_persist, :after}
           ],
           do: :safe_resume,
           else: :validated_compensation

      FaultEvidence.record_case(target, outcome, %{suite: "workspace_manager"})
      GenServer.stop(restarted)
      GenServer.stop(artifact_store)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "reconcile fault matrix preserves both interrupted operations across every durable boundary" do
    repository = git_repository("reconcile-fault-matrix-repository")

    boundaries = [
      :intent_persist,
      :side_effects_started_persist,
      :workspace_record_persist,
      :interrupted_operation_resolve,
      :completed_persist
    ]

    for boundary <- boundaries, position <- [:before, :after] do
      target = "reconcile.#{boundary}.#{position}"
      root = temp_dir("reconcile-fault-#{boundary}-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      base_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        retention_interval_ms: :infinity
      ]

      {:ok, creator} = Manager.start_link(base_opts)
      Process.unlink(creator)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: creator,
                 workspace_id: "ws_reconcile_fault",
                 request_id: "request-reconcile-fault-create"
               )

      interrupted =
        Operation.new(
          :finalize,
          workspace.id,
          %{
            "kind" => "finalize",
            "workspace_id" => workspace.id,
            "expected_epoch" => workspace.control_epoch
          },
          request_id: "request-reconcile-fault-interrupted"
        )
        |> Operation.transition(:side_effects_started)

      assert :ok =
               OperationsStore.put(:workspace_operation, interrupted.request_id, interrupted,
                 server: store,
                 retention_class: :security
               )

      GenServer.stop(creator)

      manager_opts =
        Keyword.put(base_opts, :fault_checkpoint_fun, fn event ->
          if event.id == target, do: exit({:simulated_reconcile_crash, target}), else: :ok
        end)

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)
      assert {:ok, recovered} = Manager.get(workspace.id, server: manager)
      assert recovered.state == :needs_reconciliation
      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.reconcile(recovered.id,
                   server: manager,
                   write?: true,
                   yes?: true,
                   action: :quarantine,
                   expected_epoch: recovered.control_epoch,
                   request_id: "request-reconcile-fault"
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager, {:simulated_reconcile_crash, ^target}}

      {:ok, restarted} = Manager.start_link(base_opts)
      Process.unlink(restarted)

      if {boundary, position} == {:completed_persist, :after} do
        assert {:ok, replayed} =
                 Manager.reconcile(workspace.id,
                   server: restarted,
                   write?: true,
                   yes?: true,
                   action: :quarantine,
                   expected_epoch: recovered.control_epoch,
                   request_id: "request-reconcile-fault"
                 )

        assert replayed.replayed
      else
        assert {:ok, pending} = Manager.get(workspace.id, server: restarted)
        assert pending.state == :needs_reconciliation

        request_id =
          if {boundary, position} == {:intent_persist, :before},
            do: "request-reconcile-fault",
            else: "request-reconcile-fault-recovery"

        assert {:ok, quarantined} =
                 Manager.reconcile(workspace.id,
                   server: restarted,
                   write?: true,
                   yes?: true,
                   action: :quarantine,
                   expected_epoch: pending.control_epoch,
                   request_id: request_id
                 )

        assert quarantined.state == :quarantined
      end

      assert {:ok, final_workspace} = Manager.get(workspace.id, server: restarted)
      assert final_workspace.state == :quarantined

      outcome =
        if {boundary, position} == {:completed_persist, :after},
          do: :safe_resume,
          else: :needs_reconciliation

      FaultEvidence.record_case(target, outcome, %{suite: "workspace_manager"})
      GenServer.stop(restarted)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "terminal fault matrix persists failed and reconciliation states for every workspace lifecycle" do
    lifecycle_operations = [
      {:create, :create, "request-terminal-create"},
      {:finalize, :finalize, "request-terminal-finalize"},
      {:export, :export, "request-terminal-export"},
      {:review_apply, :apply_review, "request-terminal-review-apply"},
      {:direct_apply, :apply_current, "request-terminal-direct-apply"},
      {:reconcile, :reconcile, "request-terminal-reconcile"},
      {:review_cleanup, :cleanup_review, "request-terminal-review-cleanup"},
      {:cleanup, :cleanup, "request-terminal-cleanup"},
      {:retention_cleanup, :cleanup, "req_retention_terminal"}
    ]

    for {lifecycle, kind, request_id} <- lifecycle_operations,
        {status, boundary} <- [
          {:failed, :failed_persist},
          {:needs_reconciliation, :needs_reconciliation_persist}
        ],
        position <- [:before, :after] do
      target = "#{lifecycle}.#{boundary}.#{position}"
      root = temp_dir("terminal-fault-#{lifecycle}-#{status}-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      operation =
        Operation.new(kind, "ws_terminal_fault", %{"kind" => kind}, request_id: request_id)
        |> Operation.transition(status, %{error: :simulated_terminal_state})

      assert :ok =
               OperationsStore.put(:workspace_operation, operation.request_id, operation,
                 server: store,
                 retention_class: :security
               )

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        retention_interval_ms: :infinity,
        fault_checkpoint_fun: fn event ->
          if event.id == target, do: exit({:simulated_terminal_crash, target}), else: :ok
        end
      ]

      previous_trap_exit = Process.flag(:trap_exit, true)

      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, {:simulated_terminal_crash, ^target}} = Manager.start_link(manager_opts)
      end)

      Process.flag(:trap_exit, previous_trap_exit)

      {:ok, recovered} =
        Manager.start_link(Keyword.delete(manager_opts, :fault_checkpoint_fun))

      Process.unlink(recovered)

      assert {:ok, persisted} = Manager.get_operation(request_id, server: recovered)
      assert persisted.status == status
      assert persisted.error == :simulated_terminal_state
      outcome = if status == :failed, do: :safe_resume, else: :needs_reconciliation
      FaultEvidence.record_case(target, outcome, %{suite: "workspace_manager"})
      GenServer.stop(recovered)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "backup restoration remains recoverable when reconciliation itself is terminated" do
    for position <- [:before, :after] do
      target = "reconcile.backup_restore.#{position}"
      repository = git_repository("restore-reconcile-fault-#{position}-repository")
      root = temp_dir("restore-reconcile-fault-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      {:ok, artifact_store} =
        ArtifactStore.start_link(
          name: nil,
          root: Path.join(root, "artifacts"),
          key: :crypto.strong_rand_bytes(32)
        )

      Process.unlink(artifact_store)

      manager_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        artifact_store: artifact_store,
        retention_interval_ms: :infinity,
        fault_checkpoint_fun: fn event ->
          if event.id == target, do: exit({:simulated_restore_reconcile_crash, target}), else: :ok
        end
      ]

      {:ok, manager} = Manager.start_link(manager_opts)
      Process.unlink(manager)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: manager,
                 workspace_id: "ws_restore_reconcile_fault",
                 request_id: "request-restore-reconcile-create"
               )

      File.write!(Path.join(workspace.path, "restored.txt"), "restore reconciliation result\n")

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: manager,
                 request_id: "request-restore-reconcile-finalize"
               )

      interrupt_after_apply = fn target_workspace, result, backup_root, opts ->
        assert {:ok, _applied} =
                 DirectApply.apply(target_workspace, result, backup_root, opts)

        {:error, :simulated_after_apply_failure}
      end

      assert {:error,
              {:workspace_operation_needs_reconciliation, "request-restore-reconcile-apply",
               :simulated_after_apply_failure}} =
               Manager.apply(finalized.id,
                 server: manager,
                 target: :current_worktree,
                 write?: true,
                 yes?: true,
                 expected_epoch: finalized.control_epoch,
                 request_id: "request-restore-reconcile-apply",
                 direct_apply_fun: interrupt_after_apply
               )

      assert File.exists?(Path.join(repository, "restored.txt"))
      assert {:ok, interrupted} = Manager.get(finalized.id, server: manager)
      assert {:ok, preview} = Manager.reconcile(interrupted.id, server: manager)
      assert preview.restoration.available
      monitor = Process.monitor(manager)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.reconcile(interrupted.id,
                   server: manager,
                   write?: true,
                   yes?: true,
                   action: :restore_backup,
                   expected_epoch: interrupted.control_epoch,
                   request_id: "request-restore-reconcile"
                 )
               )
      end)

      assert_receive {:DOWN, ^monitor, :process, ^manager,
                      {:simulated_restore_reconcile_crash, ^target}}

      {:ok, restarted} =
        Manager.start_link(Keyword.delete(manager_opts, :fault_checkpoint_fun))

      Process.unlink(restarted)
      assert {:ok, pending} = Manager.get(finalized.id, server: restarted)
      assert pending.state == :needs_reconciliation
      assert {:ok, nested_preview} = Manager.reconcile(pending.id, server: restarted)
      assert nested_preview.restoration.available

      assert {:ok, restored} =
               Manager.reconcile(pending.id,
                 server: restarted,
                 write?: true,
                 yes?: true,
                 action: :restore_backup,
                 expected_epoch: pending.control_epoch,
                 request_id: "request-restore-reconcile-recovery"
               )

      assert restored.state == :reviewable
      refute File.exists?(Path.join(repository, "restored.txt"))

      FaultEvidence.record_case(target, :validated_compensation, %{
        suite: "workspace_manager"
      })

      GenServer.stop(restarted)
      GenServer.stop(artifact_store)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "export resume remains recoverable when reconciliation itself is terminated" do
    for position <- [:before, :after] do
      export_target = "export.export_stage.after"
      reconcile_target = "reconcile.export_resume.#{position}"
      repository = git_repository("export-reconcile-fault-#{position}-repository")
      root = temp_dir("export-reconcile-fault-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      {:ok, artifact_store} =
        ArtifactStore.start_link(
          name: nil,
          root: Path.join(root, "artifacts"),
          key: :crypto.strong_rand_bytes(32)
        )

      Process.unlink(artifact_store)

      base_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        artifact_store: artifact_store,
        retention_interval_ms: :infinity
      ]

      export_opts =
        Keyword.put(base_opts, :fault_checkpoint_fun, fn event ->
          if event.id == export_target,
            do: exit({:simulated_export_stage_crash, export_target}),
            else: :ok
        end)

      {:ok, exporter} = Manager.start_link(export_opts)
      Process.unlink(exporter)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: exporter,
                 workspace_id: "ws_export_reconcile_fault",
                 request_id: "request-export-reconcile-create"
               )

      File.write!(Path.join(workspace.path, "exported.txt"), "nested export result\n")

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: exporter,
                 request_id: "request-export-reconcile-finalize"
               )

      destination = Path.join(root, "exported-result")
      export_monitor = Process.monitor(exporter)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.export(finalized.id, destination,
                   server: exporter,
                   write?: true,
                   request_id: "request-export-reconcile-export"
                 )
               )
      end)

      assert_receive {:DOWN, ^export_monitor, :process, ^exporter,
                      {:simulated_export_stage_crash, ^export_target}}

      reconcile_opts =
        Keyword.put(base_opts, :fault_checkpoint_fun, fn event ->
          if event.id == reconcile_target,
            do: exit({:simulated_export_reconcile_crash, reconcile_target}),
            else: :ok
        end)

      {:ok, reconciler} = Manager.start_link(reconcile_opts)
      Process.unlink(reconciler)
      assert {:ok, interrupted} = Manager.get(finalized.id, server: reconciler)
      reconcile_monitor = Process.monitor(reconciler)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.reconcile(interrupted.id,
                   server: reconciler,
                   write?: true,
                   yes?: true,
                   action: :resume_export,
                   expected_epoch: interrupted.control_epoch,
                   request_id: "request-export-reconcile"
                 )
               )
      end)

      assert_receive {:DOWN, ^reconcile_monitor, :process, ^reconciler,
                      {:simulated_export_reconcile_crash, ^reconcile_target}}

      {:ok, restarted} = Manager.start_link(base_opts)
      Process.unlink(restarted)
      assert {:ok, pending} = Manager.get(finalized.id, server: restarted)
      assert pending.state == :needs_reconciliation
      assert {:ok, preview} = Manager.reconcile(pending.id, server: restarted)
      assert preview.export_resume.available

      assert {:ok, resumed} =
               Manager.reconcile(pending.id,
                 server: restarted,
                 write?: true,
                 yes?: true,
                 action: :resume_export,
                 expected_epoch: pending.control_epoch,
                 request_id: "request-export-reconcile-recovery"
               )

      assert resumed.state == :reviewable
      assert File.regular?(Path.join(destination, "manifest.json"))
      assert File.regular?(Path.join(destination, "result.patch"))
      FaultEvidence.record_case(reconcile_target, :safe_resume, %{suite: "workspace_manager"})
      GenServer.stop(restarted)
      GenServer.stop(artifact_store)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "cleanup resume remains recoverable when reconciliation itself is terminated" do
    for position <- [:before, :after] do
      cleanup_target = "cleanup.managed_path_remove.before"
      reconcile_target = "reconcile.cleanup_resume.#{position}"
      repository = git_repository("cleanup-reconcile-fault-#{position}-repository")
      root = temp_dir("cleanup-reconcile-fault-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      base_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        retention_interval_ms: :infinity
      ]

      cleanup_opts =
        Keyword.put(base_opts, :fault_checkpoint_fun, fn event ->
          if event.id == cleanup_target,
            do: exit({:simulated_cleanup_remove_crash, cleanup_target}),
            else: :ok
        end)

      {:ok, cleaner} = Manager.start_link(cleanup_opts)
      Process.unlink(cleaner)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: cleaner,
                 workspace_id: "ws_cleanup_reconcile_fault",
                 request_id: "request-cleanup-reconcile-create"
               )

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: cleaner,
                 request_id: "request-cleanup-reconcile-finalize"
               )

      cleanup_monitor = Process.monitor(cleaner)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.cleanup(finalized.id,
                   server: cleaner,
                   write: true,
                   yes: true,
                   expected_epoch: finalized.control_epoch,
                   request_id: "request-cleanup-reconcile-cleanup"
                 )
               )
      end)

      assert_receive {:DOWN, ^cleanup_monitor, :process, ^cleaner,
                      {:simulated_cleanup_remove_crash, ^cleanup_target}}

      reconcile_opts =
        Keyword.put(base_opts, :fault_checkpoint_fun, fn event ->
          if event.id == reconcile_target,
            do: exit({:simulated_cleanup_reconcile_crash, reconcile_target}),
            else: :ok
        end)

      {:ok, reconciler} = Manager.start_link(reconcile_opts)
      Process.unlink(reconciler)
      assert {:ok, interrupted} = Manager.get(finalized.id, server: reconciler)
      reconcile_monitor = Process.monitor(reconciler)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.reconcile(interrupted.id,
                   server: reconciler,
                   write?: true,
                   yes?: true,
                   action: :resume_cleanup,
                   expected_epoch: interrupted.control_epoch,
                   request_id: "request-cleanup-reconcile"
                 )
               )
      end)

      assert_receive {:DOWN, ^reconcile_monitor, :process, ^reconciler,
                      {:simulated_cleanup_reconcile_crash, ^reconcile_target}}

      {:ok, restarted} = Manager.start_link(base_opts)
      Process.unlink(restarted)
      assert {:ok, pending} = Manager.get(finalized.id, server: restarted)
      assert pending.state == :needs_reconciliation
      assert {:ok, preview} = Manager.reconcile(pending.id, server: restarted)
      assert preview.cleanup_resume.available

      assert {:ok, resumed} =
               Manager.reconcile(pending.id,
                 server: restarted,
                 write?: true,
                 yes?: true,
                 action: :resume_cleanup,
                 expected_epoch: pending.control_epoch,
                 request_id: "request-cleanup-reconcile-recovery"
               )

      assert resumed.state == :deleted
      refute File.exists?(finalized.path)
      FaultEvidence.record_case(reconcile_target, :safe_resume, %{suite: "workspace_manager"})
      GenServer.stop(restarted)
      GenServer.stop(store)
    end
  end

  @tag :fault_matrix
  test "review discard remains recoverable when reconciliation itself is terminated" do
    for position <- [:before, :after] do
      review_target = "review_apply.review_patch_apply.before"
      reconcile_target = "reconcile.review_discard.#{position}"
      repository = git_repository("review-reconcile-fault-#{position}-repository")
      root = temp_dir("review-reconcile-fault-#{position}")

      {:ok, store} =
        OperationsStore.start_link(name: nil, path: Path.join(root, "operations.sqlite3"))

      Process.unlink(store)

      {:ok, artifact_store} =
        ArtifactStore.start_link(
          name: nil,
          root: Path.join(root, "artifacts"),
          key: :crypto.strong_rand_bytes(32)
        )

      Process.unlink(artifact_store)

      base_opts = [
        name: nil,
        root: Path.join(root, "workspaces"),
        operations_store: store,
        artifact_store: artifact_store,
        retention_interval_ms: :infinity
      ]

      review_opts =
        Keyword.put(base_opts, :fault_checkpoint_fun, fn event ->
          if event.id == review_target,
            do: exit({:simulated_review_patch_crash, review_target}),
            else: :ok
        end)

      {:ok, reviewer} = Manager.start_link(review_opts)
      Process.unlink(reviewer)

      assert {:ok, workspace} =
               Manager.create(repository,
                 server: reviewer,
                 workspace_id: "ws_review_reconcile_fault",
                 request_id: "request-review-reconcile-create"
               )

      File.write!(Path.join(workspace.path, "reviewed.txt"), "nested review result\n")

      assert {:ok, finalized, _report} =
               Manager.finalize(workspace.id,
                 server: reviewer,
                 request_id: "request-review-reconcile-finalize"
               )

      review_monitor = Process.monitor(reviewer)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.apply(finalized.id,
                   server: reviewer,
                   write?: true,
                   yes?: true,
                   expected_epoch: finalized.control_epoch,
                   request_id: "request-review-reconcile-apply"
                 )
               )
      end)

      assert_receive {:DOWN, ^review_monitor, :process, ^reviewer,
                      {:simulated_review_patch_crash, ^review_target}}

      reconcile_opts =
        Keyword.put(base_opts, :fault_checkpoint_fun, fn event ->
          if event.id == reconcile_target,
            do: exit({:simulated_review_reconcile_crash, reconcile_target}),
            else: :ok
        end)

      {:ok, reconciler} = Manager.start_link(reconcile_opts)
      Process.unlink(reconciler)
      assert {:ok, interrupted} = Manager.get(finalized.id, server: reconciler)
      assert {:ok, preview} = Manager.reconcile(interrupted.id, server: reconciler)
      assert preview.review_discard.available
      review_path = preview.review_discard.path
      reconcile_monitor = Process.monitor(reconciler)

      ExUnit.CaptureLog.capture_log(fn ->
        assert catch_exit(
                 Manager.reconcile(interrupted.id,
                   server: reconciler,
                   write?: true,
                   yes?: true,
                   action: :discard_review,
                   expected_epoch: interrupted.control_epoch,
                   request_id: "request-review-reconcile"
                 )
               )
      end)

      assert_receive {:DOWN, ^reconcile_monitor, :process, ^reconciler,
                      {:simulated_review_reconcile_crash, ^reconcile_target}}

      {:ok, restarted} = Manager.start_link(base_opts)
      Process.unlink(restarted)
      assert {:ok, pending} = Manager.get(finalized.id, server: restarted)
      assert pending.state == :needs_reconciliation
      assert {:ok, nested_preview} = Manager.reconcile(pending.id, server: restarted)
      assert nested_preview.review_discard.available

      assert {:ok, discarded} =
               Manager.reconcile(pending.id,
                 server: restarted,
                 write?: true,
                 yes?: true,
                 action: :discard_review,
                 expected_epoch: pending.control_epoch,
                 request_id: "request-review-reconcile-recovery"
               )

      assert discarded.state == :reviewable
      refute File.exists?(review_path)
      assert {:ok, ""} = Twelvgaige.Workspace.Git.SourceRead.status(repository)

      FaultEvidence.record_case(reconcile_target, :validated_compensation, %{
        suite: "workspace_manager"
      })

      GenServer.stop(restarted)
      GenServer.stop(artifact_store)
      GenServer.stop(store)
    end
  end

  test "storage admission preserves protected result capacity before creating a path" do
    root = temp_dir("storage-admission")
    repository = git_repository("storage-admission-repository")

    manager =
      start_supervised!(
        {Manager,
         name: nil, root: root, disk_available_fun: fn ^root -> {:ok, 1_024 * 1_024 * 1_024} end},
        id: :workspace_storage_admission_manager
      )

    assert {:error, {:workspace_storage_unavailable, details}} =
             Manager.create(repository,
               server: manager,
               workspace_id: "ws_storage_denied",
               request_id: "request-storage-denied"
             )

    assert details.required_bytes > details.available_bytes
    refute File.exists?(Path.join(root, "ws_storage_denied"))
    assert {:ok, []} = Manager.list_operations(server: manager)

    assert {:ok, admitted} =
             Manager.create(repository,
               server: manager,
               workspace_id: "ws_storage_admitted",
               execution_reserve_bytes: 0,
               result_reserve_bytes: 0,
               verification_reserve_bytes: 0
             )

    assert admitted.storage_reservation.total_bytes == 0
    assert admitted.storage_reservation.protected_finalization_bytes == 512 * 1_024 * 1_024
  end

  test "exports and applies a verified result into an isolated review worktree" do
    root = temp_dir("review-apply")
    repository = git_repository("review-apply-repository")

    artifact_store =
      start_supervised!(
        {ArtifactStore,
         name: nil, root: Path.join(root, "artifacts"), key: :crypto.strong_rand_bytes(32)},
        id: :review_apply_artifact_store
      )

    manager =
      start_supervised!(
        {Manager,
         name: nil,
         root: Path.join(root, "workspaces"),
         artifact_store: artifact_store,
         execution_reserve_bytes: 0},
        id: :review_apply_workspace_manager
      )

    assert {:ok, workspace} = Manager.create(repository, server: manager)
    File.write!(Path.join(workspace.path, "reviewed.txt"), "review me\n")
    git!(workspace.path, ["add", "reviewed.txt"])
    git!(workspace.path, ["commit", "--quiet", "-m", "reviewed result"])
    assert {:ok, finalized, _report} = Manager.finalize(workspace.id, server: manager)

    export_path = Path.join(root, "export")

    assert {:ok, dry_export} =
             Manager.export(workspace.id, export_path, server: manager)

    assert dry_export.dry_run
    refute File.exists?(export_path)

    assert {:ok, written_export} =
             Manager.export(workspace.id, export_path,
               server: manager,
               write?: true,
               request_id: "request-review-export"
             )

    refute written_export.dry_run
    assert File.read!(Path.join(export_path, "result.patch")) =~ "reviewed.txt"
    assert File.read!(Path.join(export_path, "result.bundle")) =~ "# v2 git bundle"
    assert written_export.bundle_bytes > 0
    assert "result.bundle" in written_export.files
    assert {:ok, _manifest} = Jason.decode(File.read!(Path.join(export_path, "manifest.json")))

    assert {:ok, replayed_export} =
             Manager.export(workspace.id, export_path,
               server: manager,
               write?: true,
               request_id: "request-review-export"
             )

    assert replayed_export.replayed

    assert {:error, :workspace_idempotency_conflict} =
             Manager.export(workspace.id, export_path <> "-changed",
               server: manager,
               write?: true,
               request_id: "request-review-export"
             )

    {source_head, 0} = System.cmd("git", ["-C", repository, "rev-parse", "HEAD"])
    {source_status, 0} = System.cmd("git", ["-C", repository, "status", "--porcelain=v2"])

    assert {:ok, check} = Manager.apply(workspace.id, server: manager)
    assert check.dry_run
    assert check.applicable
    refute Map.has_key?(check, :path)

    apply_opts = [
      server: manager,
      write?: true,
      yes?: true,
      expected_epoch: finalized.control_epoch,
      request_id: "request-review-apply"
    ]

    assert {:ok, applied} = Manager.apply(workspace.id, apply_opts)
    refute applied.dry_run
    assert applied.verified_result_tree == finalized.result_manifest.result_tree
    assert File.read!(Path.join(applied.path, "reviewed.txt")) == "review me\n"

    assert {:ok, replayed} = Manager.apply(workspace.id, apply_opts)
    assert replayed.replayed
    assert replayed.path == applied.path

    File.write!(Path.join(applied.path, "reviewed.txt"), "human edit\n")

    assert {:error, :review_worktree_has_uncaptured_changes} =
             Manager.cleanup_review(workspace.id, server: manager)

    File.write!(Path.join(applied.path, "reviewed.txt"), "review me\n")

    assert {:ok, cleanup_check} = Manager.cleanup_review(workspace.id, server: manager)
    assert cleanup_check.dry_run
    assert cleanup_check.review_path == applied.path

    review_cleanup_opts = [
      server: manager,
      write?: true,
      yes?: true,
      expected_epoch: applied.control_epoch,
      request_id: "request-review-cleanup"
    ]

    assert {:ok, removed} = Manager.cleanup_review(workspace.id, review_cleanup_opts)
    assert removed.removed
    refute File.exists?(applied.path)

    assert {:ok, replayed_removal} =
             Manager.cleanup_review(workspace.id, review_cleanup_opts)

    assert replayed_removal.replayed

    assert System.cmd("git", ["-C", repository, "rev-parse", "HEAD"]) == {source_head, 0}
    assert System.cmd("git", ["-C", repository, "status", "--porcelain=v2"]) == {source_status, 0}
  end

  test "direct apply requires an explicit target and retains a recovery backup" do
    root = temp_dir("direct-apply")
    repository = git_repository("direct-apply-repository")

    artifact_store =
      start_supervised!(
        {ArtifactStore,
         name: nil, root: Path.join(root, "artifacts"), key: :crypto.strong_rand_bytes(32)},
        id: :direct_apply_artifact_store
      )

    manager =
      start_supervised!(
        {Manager, name: nil, root: Path.join(root, "workspaces"), artifact_store: artifact_store},
        id: :direct_apply_workspace_manager
      )

    assert {:ok, workspace} = Manager.create(repository, server: manager)
    File.write!(Path.join(workspace.path, "direct.txt"), "direct result\n")
    assert {:ok, finalized, _report} = Manager.finalize(workspace.id, server: manager)

    assert {:ok, check} =
             Manager.apply(workspace.id, server: manager, target: :current_worktree)

    assert check.dry_run
    assert check.target == "current-worktree"
    refute File.exists?(Path.join(repository, "direct.txt"))

    opts = [
      server: manager,
      target: :current_worktree,
      write?: true,
      yes?: true,
      expected_epoch: finalized.control_epoch,
      request_id: "request-direct-apply",
      now: ~U[2026-08-11 18:00:00Z]
    ]

    assert {:ok, applied} = Manager.apply(workspace.id, opts)
    assert applied.target == "current-worktree"
    assert File.read!(Path.join(repository, "direct.txt")) == "direct result\n"
    assert File.dir?(applied.backup_path)
    assert File.exists?(Path.join(applied.backup_path, "backup.json"))
    assert File.exists?(Path.join(applied.backup_path, "index"))
    assert DateTime.compare(applied.backup_expires_at, ~U[2026-08-18 18:00:00Z]) == :eq

    assert {:ok, replayed} = Manager.apply(workspace.id, opts)
    assert replayed.replayed
    assert replayed.backup_path == applied.backup_path

    {status, 0} = System.cmd("git", ["-C", repository, "status", "--porcelain=v2"])
    assert status =~ "direct.txt"
  end

  test "interrupted direct apply preserves evidence and reconciles only by explicit quarantine" do
    root = temp_dir("direct-reconcile")
    repository = git_repository("direct-reconcile-repository")

    artifact_store =
      start_supervised!(
        {ArtifactStore,
         name: nil, root: Path.join(root, "artifacts"), key: :crypto.strong_rand_bytes(32)},
        id: :direct_reconcile_artifact_store
      )

    manager =
      start_supervised!(
        {Manager, name: nil, root: Path.join(root, "workspaces"), artifact_store: artifact_store},
        id: :direct_reconcile_workspace_manager
      )

    assert {:ok, workspace} = Manager.create(repository, server: manager)
    File.write!(Path.join(workspace.path, "interrupted.txt"), "result\n")
    assert {:ok, finalized, _report} = Manager.finalize(workspace.id, server: manager)

    base_opts = [
      server: manager,
      target: :current_worktree,
      write?: true,
      yes?: true,
      expected_epoch: finalized.control_epoch
    ]

    assert {:error, :simulated_before_backup} =
             Manager.apply(
               workspace.id,
               base_opts ++
                 [
                   request_id: "request-before-backup",
                   direct_apply_fun: fn _workspace, _result, _root, _opts ->
                     {:error, :simulated_before_backup}
                   end
                 ]
             )

    assert {:ok, still_reviewable} = Manager.get(workspace.id, server: manager)
    assert still_reviewable.state == :reviewable

    interrupt = fn _workspace, _result, backup_root, opts ->
      backup_path = DirectApply.backup_path(backup_root, opts[:request_id])
      File.mkdir_p!(backup_path)
      File.write!(Path.join(repository, "partial.txt"), "partial write\n")
      {:error, :simulated_after_repository_write}
    end

    assert {:error,
            {:workspace_operation_needs_reconciliation, "request-after-write",
             :simulated_after_repository_write}} =
             Manager.apply(
               workspace.id,
               base_opts ++
                 [request_id: "request-after-write", direct_apply_fun: interrupt]
             )

    assert File.exists?(Path.join(repository, "partial.txt"))
    assert {:ok, interrupted} = Manager.get(workspace.id, server: manager)
    assert interrupted.state == :needs_reconciliation

    assert {:ok, preview} = Manager.reconcile(workspace.id, server: manager)
    assert preview.dry_run
    assert preview.interrupted_request_id == "request-after-write"
    assert preview.action == :quarantine

    reconcile_opts = [
      server: manager,
      write?: true,
      yes?: true,
      action: :quarantine,
      expected_epoch: interrupted.control_epoch,
      request_id: "request-reconcile-direct"
    ]

    assert {:ok, resolved} = Manager.reconcile(workspace.id, reconcile_opts)
    assert resolved.state == :quarantined
    refute resolved.dry_run
    assert File.exists?(Path.join(repository, "partial.txt"))

    assert {:ok, replayed} = Manager.reconcile(workspace.id, reconcile_opts)
    assert replayed.replayed

    assert {:ok, quarantined} = Manager.get(workspace.id, server: manager)
    assert quarantined.state == :quarantined
  end

  test "interrupted direct apply restores only from validated evidence without source drift" do
    root = temp_dir("direct-restore")
    repository = git_repository("direct-restore-repository")

    artifact_store =
      start_supervised!(
        {ArtifactStore,
         name: nil, root: Path.join(root, "artifacts"), key: :crypto.strong_rand_bytes(32)},
        id: :direct_restore_artifact_store
      )

    manager =
      start_supervised!(
        {Manager, name: nil, root: Path.join(root, "workspaces"), artifact_store: artifact_store},
        id: :direct_restore_workspace_manager
      )

    assert {:ok, workspace} = Manager.create(repository, server: manager)
    File.write!(Path.join(workspace.path, "interrupted.txt"), "result\n")
    assert {:ok, finalized, _report} = Manager.finalize(workspace.id, server: manager)

    interrupt = fn workspace, result, backup_root, opts ->
      with {:ok, _report} <- DirectApply.apply(workspace, result, backup_root, opts) do
        {:error, :simulated_after_repository_write}
      end
    end

    assert {:error,
            {:workspace_operation_needs_reconciliation, "request-restore-write",
             :simulated_after_repository_write}} =
             Manager.apply(workspace.id,
               server: manager,
               target: :current_worktree,
               write?: true,
               yes?: true,
               expected_epoch: finalized.control_epoch,
               request_id: "request-restore-write",
               direct_apply_fun: interrupt
             )

    assert File.read!(Path.join(repository, "interrupted.txt")) == "result\n"
    assert {:ok, interrupted} = Manager.get(workspace.id, server: manager)
    assert interrupted.state == :needs_reconciliation

    assert {:ok, preview} = Manager.reconcile(workspace.id, server: manager)
    assert preview.restoration.available
    assert preview.restoration.backup_path =~ "backup-"

    restore_opts = [
      server: manager,
      write?: true,
      yes?: true,
      action: :restore_backup,
      expected_epoch: interrupted.control_epoch,
      request_id: "request-restore-direct"
    ]

    assert {:ok, restored} = Manager.reconcile(workspace.id, restore_opts)
    assert restored.state == :reviewable
    assert restored.status == :restored
    refute File.exists?(Path.join(repository, "interrupted.txt"))
    assert {"", 0} = System.cmd("git", ["-C", repository, "status", "--porcelain=v2"])

    assert {:ok, replayed} = Manager.reconcile(workspace.id, restore_opts)
    assert replayed.replayed
  end

  test "retention sweep removes only expired recoverable workspaces" do
    root = temp_dir("retention-sweep")
    repository = git_repository("retention-sweep-repository")

    artifact_store =
      start_supervised!(
        {ArtifactStore,
         name: nil, root: Path.join(root, "artifacts"), key: :crypto.strong_rand_bytes(32)},
        id: :retention_sweep_artifact_store
      )

    manager =
      start_supervised!(
        {Manager,
         name: nil,
         root: Path.join(root, "workspaces"),
         artifact_store: artifact_store,
         workspace_retention_days: 7,
         retention_interval_ms: :infinity},
        id: :retention_sweep_workspace_manager
      )

    assert {:ok, workspace} = Manager.create(repository, server: manager)
    File.write!(Path.join(workspace.path, "retained.txt"), "retained\n")

    assert {:ok, finalized, _report} =
             Manager.finalize(workspace.id,
               server: manager,
               now: ~U[2026-08-01 12:00:00Z]
             )

    assert {:ok, before} =
             Manager.run_retention(server: manager, now: ~U[2026-08-08 11:59:59Z])

    assert before.removed == []
    assert File.dir?(finalized.path)

    assert {:ok, after_expiry} =
             Manager.run_retention(server: manager, now: ~U[2026-08-08 12:00:00Z])

    assert [%{workspace_id: workspace_id, deleted: true}] = after_expiry.removed
    assert workspace_id == workspace.id
    refute File.exists?(finalized.path)

    assert {:ok, status} = Manager.retention_status(server: manager)
    assert status.workspace_retention_days == 7
    assert status.expired_workspaces == []
    assert status.last_run == ~U[2026-08-08 12:00:00Z]
  end

  defp git_repository(name) do
    repository = temp_dir(name)
    System.cmd("git", ["-C", repository, "init", "--quiet"])
    System.cmd("git", ["-C", repository, "config", "user.name", "Test"])
    System.cmd("git", ["-C", repository, "config", "user.email", "test@localhost"])
    File.write!(Path.join(repository, "base.txt"), "base")
    System.cmd("git", ["-C", repository, "add", "--all"])
    System.cmd("git", ["-C", repository, "commit", "--quiet", "-m", "base"])
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
