defmodule Twelvgaige.Workspace.GitCapabilityTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.Git.ManagedWorkspace
  alias Twelvgaige.Workspace.Git.SourceRead

  defp authorize(workspace, opts) do
    ManagedWorkspace.authorize(
      workspace,
      Keyword.put(opts, :audit_fun, fn _event -> :ok end)
    )
  end

  test "source capability exports no source mutation operations" do
    exports = SourceRead.__info__(:functions) |> Enum.map(&elem(&1, 0)) |> MapSet.new()

    assert MapSet.member?(exports, :read)
    assert MapSet.member?(exports, :copy_snapshot)

    refute MapSet.member?(exports, :apply_patch)
    refute MapSet.member?(exports, :create_worktree)
    refute MapSet.member?(exports, :remove_worktree)
    refute MapSet.member?(exports, :create_input_baseline)
    refute MapSet.member?(exports, :capture_result)
  end

  test "compiled production modules cannot bypass the capability interfaces" do
    allowed = [
      Twelvgaige.Workspace.Git,
      Twelvgaige.Workspace.Git.SourceRead,
      Twelvgaige.Workspace.Git.ManagedWorkspace
    ]

    {:ok, modules} = :application.get_key(:twelvgaige, :modules)

    bypasses =
      modules
      |> Enum.reject(&(&1 in allowed))
      |> Enum.flat_map(fn module ->
        with path when is_list(path) <- :code.which(module),
             {:ok, {^module, chunks}} <- :beam_lib.chunks(path, [:imports]) do
          chunks[:imports]
          |> Enum.filter(fn {target, _function, _arity} -> target == Twelvgaige.Workspace.Git end)
          |> Enum.map(&{module, &1})
        else
          _unavailable -> []
        end
      end)

    assert bypasses == []
  end

  test "managed authority binds canonical path, identity, lease, operation, and epoch" do
    root = tmp_dir!("managed-capability")

    workspace = %{id: "ws_capability", path: root, control_epoch: 7}

    assert {:ok, authority} =
             authorize(workspace,
               expected_epoch: 7,
               lease: "lease_session",
               operation_id: "op_finalize",
               request_id: "req_finalize",
               scope: :execution
             )

    assert :ok = ManagedWorkspace.validate(authority)

    assert {:ok, identity} = ManagedWorkspace.identity(authority)
    assert identity.workspace_id == "ws_capability"
    assert identity.operation_id == "op_finalize"
    assert identity.request_id == "req_finalize"
    assert identity.control_epoch == 7
    assert identity.scope == :execution
    refute Map.has_key?(identity, :root)
  end

  test "managed authority rejects missing and stale authority before Git execution" do
    root = tmp_dir!("managed-stale")
    workspace = %{id: "ws_stale", path: root, control_epoch: 3}

    assert {:error, :git_workspace_control_epoch_conflict} =
             authorize(workspace,
               expected_epoch: 2,
               lease: "lease",
               operation_id: "op",
               scope: :execution
             )

    assert {:error, :git_workspace_lease_required} =
             authorize(workspace,
               expected_epoch: 3,
               operation_id: "op",
               scope: :execution
             )

    assert {:ok, authority} =
             authorize(workspace,
               expected_epoch: 3,
               lease: "lease",
               operation_id: "op",
               scope: :execution
             )

    moved = root <> "-moved"
    File.rename!(root, moved)
    File.mkdir!(root)

    assert {:error, :git_workspace_path_identity_changed} =
             ManagedWorkspace.resolve_commit(authority, "HEAD",
               command_runner: fn _command, _args, _opts -> flunk("Git must not execute") end
             )
  end

  test "review registration authority is bound to its exact destination" do
    repository = tmp_dir!("review-registration")
    destination = Path.join(Path.dirname(repository), "review-target") |> Path.expand()
    workspace = %{id: "ws_review", path: repository, control_epoch: 4}

    assert {:ok, authority} =
             authorize(workspace,
               root: repository,
               target_path: destination,
               expected_epoch: 4,
               lease: "req_review",
               operation_id: "op_review",
               scope: :review_registration
             )

    assert {:error, :git_workspace_target_mismatch} =
             ManagedWorkspace.create_worktree(authority, destination <> "-other", "abc",
               command_runner: fn _command, _args, _opts -> flunk("Git must not execute") end
             )

    assert {:error, :git_workspace_scope_denied} =
             ManagedWorkspace.capture_result(authority, "abc",
               command_runner: fn _command, _args, _opts -> flunk("Git must not execute") end
             )
  end

  test "snapshot copy requires durable registration identity" do
    assert {:error, :git_snapshot_registration_required} =
             SourceRead.copy_snapshot("/source", "/destination", "abc")
  end

  test "read-only result capture uses an isolated object directory" do
    repository = tmp_dir!("isolated-result-objects")
    git!(repository, ["init", "--quiet"])
    git!(repository, ["config", "user.name", "Capability Test"])
    git!(repository, ["config", "user.email", "capability@localhost"])
    File.write!(Path.join(repository, "tracked.txt"), "base\n")
    git!(repository, ["add", "--all"])
    git!(repository, ["commit", "--quiet", "-m", "base"])
    baseline = git_output!(repository, ["rev-parse", "HEAD"]) |> String.trim()

    before = object_inventory(repository)
    File.write!(Path.join(repository, "tracked.txt"), "changed\n")

    assert {:ok, result} = SourceRead.capture_worktree_result(repository, baseline)
    assert result.no_change == false
    assert result.patch =~ "changed"
    assert object_inventory(repository) == before
  end

  test "each managed Git mutation emits sanitized intent and terminal evidence" do
    root = tmp_dir!("mutation-audit")
    parent = self()
    workspace = %{id: "ws_audit", path: root, control_epoch: 9}

    assert {:ok, authority} =
             ManagedWorkspace.authorize(workspace,
               expected_epoch: 9,
               lease: "lease_audit",
               operation_id: "op_audit",
               request_id: "req_audit",
               scope: :direct_apply,
               audit_fun: fn event ->
                 send(parent, {:git_audit, event})
                 :ok
               end
             )

    runner = fn "git", args, _opts ->
      send(parent, {:git_run, args})
      {:ok, ""}
    end

    assert :ok =
             ManagedWorkspace.apply_patch(authority, "secret patch bytes", command_runner: runner)

    assert_receive {:git_audit, intent}
    assert_receive {:git_run, ["-C", ^root, "apply" | _rest]}
    assert_receive {:git_audit, terminal}

    assert intent.phase == :intent
    assert terminal.phase == :completed
    assert intent.mutation_id == terminal.mutation_id
    assert intent.command_class == :apply
    assert intent.workspace_id == "ws_audit"
    assert intent.operation_id == "op_audit"
    assert intent.request_id == "req_audit"
    assert intent.lease == "lease_audit"
    assert intent.control_epoch == 9
    assert terminal.evidence == %{status: "completed", output_bytes: 0}

    serialized = inspect([intent, terminal])
    refute serialized =~ root
    refute serialized =~ "secret patch bytes"
    refute serialized =~ "source-overlay.patch"
  end

  test "audit intent failure prevents Git and terminal failure remains visible" do
    root = tmp_dir!("mutation-audit-failure")
    workspace = %{id: "ws_audit_failure", path: root, control_epoch: 1}

    assert {:ok, denied} =
             ManagedWorkspace.authorize(workspace,
               expected_epoch: 1,
               lease: "lease",
               operation_id: "op",
               scope: :direct_apply,
               audit_fun: fn _event -> {:error, :audit_unavailable} end
             )

    assert {:error, {:git_mutation_audit_intent_failed, :audit_unavailable}} =
             ManagedWorkspace.apply_patch(denied, "patch",
               command_runner: fn _command, _args, _opts -> flunk("Git must not execute") end
             )

    counter = start_supervised!({Agent, fn -> 0 end})

    assert {:ok, terminal_failure} =
             ManagedWorkspace.authorize(workspace,
               expected_epoch: 1,
               lease: "lease",
               operation_id: "op",
               scope: :direct_apply,
               audit_fun: fn _event ->
                 if Agent.get_and_update(counter, &{&1, &1 + 1}) == 0,
                   do: :ok,
                   else: {:error, :audit_write_failed}
               end
             )

    assert {:error, {:git_mutation_audit_terminal_failed, :audit_write_failed}} =
             ManagedWorkspace.apply_patch(terminal_failure, "patch",
               command_runner: fn _command, _args, _opts -> {:ok, ""} end
             )
  end

  defp tmp_dir!(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-#{name}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    Path.expand(path)
  end

  defp object_inventory(repository) do
    repository
    |> Path.join(".git/objects/**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(fn path -> {Path.relative_to(path, repository), File.read!(path)} end)
  end

  defp git!(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
  end

  defp git_output!(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {output, 0} -> output
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
  end
end
