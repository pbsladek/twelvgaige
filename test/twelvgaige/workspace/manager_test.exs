defmodule Twelvgaige.Workspace.ManagerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.Manager
  alias Twelvgaige.Workspace.Transport

  test "copy snapshots contain only declared paths and enforce one writer" do
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
    refute File.exists?(Path.join(workspace.path, "secret.txt"))

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

  defp temp_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
