defmodule Twelvgaige.Workspace.RuntimeImportTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.RuntimeImport

  test "atomically replaces the complete managed snapshot, including deletions and safe symlinks" do
    root = temp_dir()
    destination = Path.join(root, "workspace")
    staging = Path.join(root, "workspace.runtime-staging-test")
    File.mkdir_p!(destination)
    File.mkdir_p!(Path.join(staging, "lib"))
    File.write!(Path.join(destination, "deleted.txt"), "old\n")
    File.write!(Path.join(staging, "lib/result.txt"), "new\n")
    File.ln_s!("lib/result.txt", Path.join(staging, "result-link"))

    assert {:ok,
            %{
              destination: ^destination,
              managed_snapshot_replaced: true,
              bytes: bytes,
              entries: entries
            }} =
             RuntimeImport.replace(staging, destination,
               allowed_export_roots: [root],
               max_export_bytes: 1_024
             )

    assert bytes > 0
    assert entries >= 4
    refute File.exists?(Path.join(destination, "deleted.txt"))
    assert File.read!(Path.join(destination, "lib/result.txt")) == "new\n"
    assert File.read_link!(Path.join(destination, "result-link")) == "lib/result.txt"
    refute File.exists?(staging)
    refute File.exists?(destination <> ".runtime-backup")
    refute File.exists?(destination <> ".runtime-import.json")
  end

  test "rejects an escaping runtime symlink before changing the managed snapshot" do
    root = temp_dir()
    destination = Path.join(root, "workspace")
    staging = Path.join(root, "workspace.runtime-staging-hostile")
    File.mkdir_p!(destination)
    File.mkdir_p!(staging)
    File.write!(Path.join(destination, "preserved.txt"), "preserved\n")
    File.ln_s!("../../outside", Path.join(staging, "escape"))

    assert {:error, :runtime_workspace_symlink_escapes_root} =
             RuntimeImport.replace(staging, destination,
               allowed_export_roots: [root],
               max_export_bytes: 1_024
             )

    assert File.read!(Path.join(destination, "preserved.txt")) == "preserved\n"
    assert File.exists?(staging)
  end

  test "recovers deterministically after every import side effect" do
    stages = [
      :intent_persisted,
      :original_moved,
      :staging_installed,
      :backup_removed,
      :journal_removed
    ]

    Enum.each(stages, fn stage ->
      root = temp_dir("-#{stage}")
      destination = Path.join(root, "workspace")
      staging = Path.join(root, "workspace.runtime-staging")
      File.mkdir_p!(destination)
      File.mkdir_p!(staging)
      File.write!(Path.join(destination, "original.txt"), "original")
      File.write!(Path.join(staging, "result.txt"), "result")

      assert catch_throw(
               RuntimeImport.replace(staging, destination,
                 allowed_export_roots: [root],
                 max_export_bytes: 1_024,
                 fault_fun: fn
                   ^stage -> throw({:simulated_crash, stage})
                   _other -> :ok
                 end
               )
             ) == {:simulated_crash, stage}

      assert :ok =
               RuntimeImport.recover(destination,
                 allowed_export_roots: [root],
                 max_export_bytes: 1_024
               )

      refute File.exists?(destination <> ".runtime-backup")
      refute File.exists?(destination <> ".runtime-import.json")

      if stage in [:intent_persisted, :original_moved] do
        assert File.read!(Path.join(destination, "original.txt")) == "original"
        refute File.exists?(staging)
      else
        assert File.read!(Path.join(destination, "result.txt")) == "result"
        refute File.exists?(staging)
      end
    end)
  end

  test "refuses an unjournaled backup and a journal with substituted identities" do
    root = temp_dir()
    destination = Path.join(root, "workspace")
    File.mkdir_p!(destination)
    File.mkdir_p!(destination <> ".runtime-backup")

    assert {:error, :runtime_workspace_untracked_backup} =
             RuntimeImport.recover(destination, allowed_export_roots: [root])

    File.rm_rf!(destination <> ".runtime-backup")

    File.write!(
      destination <> ".runtime-import.json",
      Jason.encode!(%{
        "schema_version" => 1,
        "phase" => "prepared",
        "staging" => Path.join(root, "staging"),
        "destination" => destination,
        "backup" => Path.join(root, "someone-elses-backup")
      })
    )

    assert {:error, :runtime_workspace_journal_identity_mismatch} =
             RuntimeImport.recover(destination, allowed_export_roots: [root])

    assert File.dir?(destination)
  end

  test "a retry with a new staging directory cleans the exact abandoned staging tree" do
    root = temp_dir()
    destination = Path.join(root, "workspace")
    abandoned = Path.join(root, "workspace.runtime-staging-abandoned")
    retry_staging = Path.join(root, "workspace.runtime-staging-retry")
    File.mkdir_p!(destination)
    File.mkdir_p!(abandoned)
    File.write!(Path.join(destination, "original.txt"), "original")
    File.write!(Path.join(abandoned, "abandoned.txt"), "abandoned")

    assert catch_throw(
             RuntimeImport.replace(abandoned, destination,
               allowed_export_roots: [root],
               max_export_bytes: 1_024,
               fault_fun: fn
                 :original_moved -> throw(:simulated_crash)
                 _stage -> :ok
               end
             )
           ) == :simulated_crash

    File.mkdir_p!(retry_staging)
    File.write!(Path.join(retry_staging, "result.txt"), "result")

    assert {:ok, _report} =
             RuntimeImport.replace(retry_staging, destination,
               allowed_export_roots: [root],
               max_export_bytes: 1_024
             )

    assert File.read!(Path.join(destination, "result.txt")) == "result"
    refute File.exists?(abandoned)
    refute File.exists?(retry_staging)
    refute File.exists?(destination <> ".runtime-backup")
    refute File.exists?(destination <> ".runtime-import.json")
  end

  defp temp_dir(suffix \\ "") do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-runtime-import-#{System.unique_integer([:positive])}#{suffix}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
