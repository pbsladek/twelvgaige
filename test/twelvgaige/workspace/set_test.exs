defmodule Twelvgaige.Workspace.SetTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.Manager
  alias Twelvgaige.Workspace.Set
  alias Twelvgaige.Operations.Store

  test "cross-repository snapshots record every source and resulting commit under one owner" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-workspace-set-#{System.unique_integer([:positive])}"
      )

    repo_a = create_repository(Path.join(root, "repo-a"), "a.txt")
    repo_b = create_repository(Path.join(root, "repo-b"), "b.txt")
    store_path = Path.join(root, "operations.sqlite3")
    store = start_supervised!({Store, name: nil, path: store_path})

    manager =
      start_supervised!(
        {Manager, name: nil, root: Path.join(root, "workspaces"), operations_store: store}
      )

    assert {:ok, set} =
             Manager.create_set(%{app: repo_a, library: repo_b},
               server: manager,
               set_id: "wsset_cross_repo",
               owner_session_id: "session_owner",
               transport: :copy_snapshot
             )

    assert %Set{} = set
    assert {:ok, [listed]} = Manager.list_sets(server: manager)
    assert listed.id == set.id
    assert Map.keys(set.repositories) |> Enum.sort() == ["app", "library"]

    assert Enum.all?(set.repositories, fn {_name, workspace} ->
             workspace.owner_session_id == "session_owner" and is_binary(workspace.base_commit)
           end)

    assert {:ok, %{value: active_record}} =
             Store.get(:workspace_set_provenance, set.id, server: store)

    assert active_record.status == :active
    assert Map.keys(active_record.inputs) |> Enum.sort() == ["app", "library"]
    assert Enum.all?(active_record.outputs, fn {_name, commit} -> is_nil(commit) end)

    app_workspace = set.repositories["app"]

    assert {:error, :workspace_writer_already_leased} =
             Manager.bind_owner(app_workspace.id, "session_other", server: manager)

    File.write!(Path.join(app_workspace.path, "new.txt"), "result\n")
    git!(app_workspace.path, ["add", "--all"])
    git!(app_workspace.path, ["commit", "--quiet", "-m", "result"])

    Enum.each(set.repositories, fn {_name, workspace} ->
      assert {:ok, _workspace} =
               Manager.quiesce(
                 workspace.id,
                 %{
                   runtime_stopped: true,
                   runtime_identity: "workspace-set-test",
                   stopped_at: ~U[2026-08-11 12:00:00Z]
                 },
                 server: manager
               )
    end)

    assert {:ok, finalized, provenance} = Manager.finalize_set(set.id, server: manager)
    assert Map.keys(provenance.inputs) |> Enum.sort() == ["app", "library"]
    assert Map.keys(provenance.outputs) |> Enum.sort() == ["app", "library"]
    assert provenance.inputs["app"] != provenance.outputs["app"]

    assert Enum.all?(provenance.inputs, fn {_name, commit} ->
             Regex.match?(~r/^[0-9a-f]{40,64}$/, commit)
           end)

    assert Enum.all?(provenance.outputs, fn {_name, commit} ->
             Regex.match?(~r/^[0-9a-f]{40,64}$/, commit)
           end)

    assert finalized.finalized_at

    assert {:ok, %{value: durable_record}} =
             Store.get(:workspace_set_provenance, set.id, server: store)

    assert durable_record.status == :finalized
    assert durable_record.owner_session_id == "session_owner"
    assert durable_record.inputs == provenance.inputs
    assert durable_record.outputs == provenance.outputs
    assert durable_record.repositories["app"].base_commit == provenance.inputs["app"]
    assert durable_record.repositories["app"].resulting_commit == provenance.outputs["app"]

    GenServer.stop(store)
    restarted = start_supervised!({Store, name: nil, path: store_path}, id: :restarted_store)

    assert {:ok, %{value: recovered}} =
             Store.get(:workspace_set_provenance, set.id, server: restarted)

    assert recovered.inputs == provenance.inputs
    assert recovered.outputs == provenance.outputs
  end

  defp create_repository(path, filename) do
    File.mkdir_p!(path)
    git!(path, ["init", "--quiet"])
    git!(path, ["config", "user.name", "Twelvgaige Test"])
    git!(path, ["config", "user.email", "test@localhost"])
    File.write!(Path.join(path, filename), "base\n")
    git!(path, ["add", "--all"])
    git!(path, ["commit", "--quiet", "-m", "base"])
    path
  end

  defp git!(path, args) do
    case System.cmd("git", ["-C", path | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
  end
end
