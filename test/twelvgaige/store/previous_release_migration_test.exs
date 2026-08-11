defmodule Twelvgaige.Store.PreviousReleaseMigrationTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Audit.Chain
  alias Twelvgaige.Developer.MigrationQualification
  alias Twelvgaige.Round.{Recovery, Snapshot}
  alias Twelvgaige.Store.SQLite, as: SQLiteStore
  alias Twelvgaige.Workspace.{Canonical, ResultManifest}

  @fixture_root Path.expand("../../../qualification/fixtures/migrations", __DIR__)
  @store_name :previous_release_migration_store

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-previous-release-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  test "v0.0.3 persisted records remain readable and interrupted work is reconciled", %{
    root: root
  } do
    store_path = materialize_previous_store!(root)
    start_supervised!({SQLiteStore, name: @store_name, path: store_path})

    assert {:ok, complete} = GenServer.call(@store_name, {:get_round, "previous_complete"})
    assert %Snapshot{schema_version: 1, encoding_version: 1, status: :complete} = complete
    assert Snapshot.to_map(complete).id == "previous_complete"

    assert {:ok, complete_manifest} =
             GenServer.call(@store_name, {:get_manifest, "previous_complete"})

    assert complete_manifest.round_id == "previous_complete"

    assert {:ok, complete_audit} =
             GenServer.call(@store_name, {:list_audit_events, "previous_complete", []})

    assert length(complete_audit) == 2
    assert :ok = Chain.verify(complete_audit)

    assert {:ok, [interrupted]} = GenServer.call(@store_name, :list_incomplete_rounds)
    assert %Snapshot{schema_version: 1, encoding_version: 1, version: 1} = interrupted

    assert {:ok, attempts} =
             GenServer.call(
               @store_name,
               {:list_attempt_journals, "previous_interrupted"}
             )

    assert {:ok, tools} =
             GenServer.call(@store_name, {:list_tool_journals, "previous_interrupted"})

    assert [%{status: :started}] = attempts
    assert [%{status: :intent_recorded, safety_level: :write}] = tools

    assert {:commit, reconciled} =
             Recovery.reconcile(interrupted,
               journals: %{attempts: attempts, tools: tools},
               now: ~U[2026-08-11 12:00:00Z]
             )

    assert reconciled.status == :awaiting_reconciliation
    assert [shot] = reconciled.shots
    assert shot.status == :awaiting_reconciliation

    assert :ok =
             GenServer.call(
               @store_name,
               {:commit_transition, interrupted.id, interrupted.version,
                "migrate-v0.0.3-interrupted", reconciled,
                [%{event_type: :round_awaiting_reconciliation}], []}
             )

    stop_supervised!(SQLiteStore)
    start_supervised!({SQLiteStore, name: @store_name, path: store_path})

    assert {:ok, persisted} =
             GenServer.call(@store_name, {:get_round, "previous_interrupted"})

    assert persisted.status == :awaiting_reconciliation
    assert persisted.version == 2
    assert persisted.schema_version == 1
  end

  test "the result-manifest v1 digest keeps its original interpretation" do
    fixture =
      @fixture_root
      |> Path.join("result-manifest-v1.json")
      |> File.read!()
      |> Jason.decode!()

    payload = ResultManifest.payload(fixture["payload"])
    assert payload == fixture["payload"]

    assert {:ok, digest} =
             Canonical.digest("result-manifest", fixture["encoding_version"], payload)

    assert digest == fixture["digest"]
    refute Map.has_key?(payload, "bundle_digest")
    refute Map.has_key?(payload, "bundle_bytes")
  end

  test "the retained migration qualification reports every contract", %{root: root} do
    report = MigrationQualification.evaluate(File.cwd!(), temporary_root: root)

    assert report.status == "pass"
    assert report.scope.previous_release == "0.0.3"
    assert report.scope.persisted_stores == ["sqlite", "file"]
    assert report.scope.canonical_contract == "result-manifest-v1"
    assert Enum.all?(report.checks, fn {_check, status} -> status == "pass" end)
  end

  defp materialize_previous_store!(root) do
    fixture_dir = Path.join(@fixture_root, "v0.0.3")
    manifest = fixture_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    artifact = manifest["artifact"]

    compressed =
      fixture_dir
      |> Path.join(artifact["path"])
      |> File.read!()
      |> Base.decode64!(ignore: :whitespace)

    assert byte_size(compressed) == artifact["compressed_bytes"]
    assert sha256(compressed) == artifact["compressed_sha256"]

    database = :zlib.gunzip(compressed)
    assert byte_size(database) == artifact["uncompressed_bytes"]
    assert sha256(database) == artifact["uncompressed_sha256"]

    path = Path.join(root, "store.sqlite3")
    File.write!(path, database, [:binary, :exclusive])
    File.chmod!(path, 0o600)
    path
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
