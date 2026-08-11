defmodule Twelvgaige.Developer.MigrationQualification do
  @moduledoc "Retained qualification for the previous release and digest schema."

  alias Twelvgaige.Audit.Chain
  alias Twelvgaige.Round.{Recovery, Snapshot}
  alias Twelvgaige.Store.File, as: FileStore
  alias Twelvgaige.Store.SQLite, as: SQLiteStore
  alias Twelvgaige.Workspace.{Canonical, ResultManifest}

  @previous_version "0.0.3"
  @previous_commit "c30eed906ddec54872434375690c8581e9ad471e"
  @sqlite_store_name :twelvgaige_sqlite_migration_qualification_store
  @file_store_name :twelvgaige_file_migration_qualification_store

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    root = Keyword.get(opts, :root, File.cwd!())

    destination =
      Keyword.get(
        opts,
        :evidence_path,
        Path.expand("qualification/evidence/migrations/previous-release.json", root)
      )

    report = evaluate(root)

    with :ok <- write_evidence(destination, report) do
      if report.status == "pass",
        do: {:ok, report},
        else: {:error, {:migration_qualification_failed, report.reason}}
    end
  end

  @spec evaluate(Path.t(), keyword()) :: map()
  def evaluate(root \\ File.cwd!(), opts \\ []) do
    generated_at = Keyword.get(opts, :now, DateTime.utc_now())
    temporary_root = Keyword.get(opts, :temporary_root, qualification_tmp())
    cleanup? = not Keyword.has_key?(opts, :temporary_root)

    report =
      try do
        File.mkdir_p!(temporary_root)
        qualify(root, temporary_root, generated_at)
      rescue
        error -> failure_report(generated_at, error)
      catch
        kind, reason -> failure_report(generated_at, {kind, reason})
      after
        if cleanup?, do: File.rm_rf(temporary_root)
      end

    report
  end

  defp qualify(root, temporary_root, generated_at) do
    fixture_root = Path.join(root, "qualification/fixtures/migrations")
    stores = materialize_previous_stores!(fixture_root, temporary_root)

    Enum.each(stores, fn store ->
      with_store(store.module, store.name, store.path, fn ->
        qualify_previous_store!(store.name)
      end)

      with_store(store.module, store.name, store.path, fn ->
        qualify_reopened_store!(store.name)
      end)
    end)

    qualify_result_manifest_v1!(fixture_root)

    %{
      schema_version: 1,
      generated_at: DateTime.to_iso8601(generated_at),
      status: "pass",
      scope: %{
        previous_release: @previous_version,
        previous_commit: @previous_commit,
        consumer_version: to_string(Application.spec(:twelvgaige, :vsn)),
        persisted_stores: Enum.map(stores, & &1.kind),
        canonical_contract: "result-manifest-v1"
      },
      artifacts: Map.new(stores, &{&1.kind, &1.artifact}),
      checks: passing_checks(),
      host: host()
    }
  end

  defp materialize_previous_stores!(fixture_root, temporary_root) do
    fixture_dir = Path.join(fixture_root, "v0.0.3")
    manifest = fixture_dir |> Path.join("manifest.json") |> File.read!() |> Jason.decode!()
    producer = manifest["producer"]

    require!(producer["version"] == @previous_version, :previous_version_mismatch)
    require!(producer["git_commit"] == @previous_commit, :previous_commit_mismatch)

    [
      materialize_store!(
        fixture_dir,
        manifest["artifact"],
        temporary_root,
        "sqlite",
        SQLiteStore,
        @sqlite_store_name,
        "store.sqlite3"
      ),
      materialize_store!(
        fixture_dir,
        manifest["file_artifact"],
        temporary_root,
        "file",
        FileStore,
        @file_store_name,
        "store.term"
      )
    ]
  end

  defp materialize_store!(
         fixture_dir,
         artifact,
         temporary_root,
         kind,
         module,
         name,
         filename
       ) do
    compressed =
      fixture_dir
      |> Path.join(artifact["path"])
      |> File.read!()
      |> Base.decode64!(ignore: :whitespace)

    require!(byte_size(compressed) == artifact["compressed_bytes"], :compressed_size_mismatch)
    require!(sha256(compressed) == artifact["compressed_sha256"], :compressed_digest_mismatch)

    store = :zlib.gunzip(compressed)

    require!(
      byte_size(store) == artifact["uncompressed_bytes"],
      :uncompressed_size_mismatch
    )

    require!(
      sha256(store) == artifact["uncompressed_sha256"],
      :uncompressed_digest_mismatch
    )

    path = Path.join(temporary_root, filename)
    File.write!(path, store, [:binary, :exclusive])
    File.chmod!(path, 0o600)

    %{
      kind: kind,
      module: module,
      name: name,
      path: path,
      artifact: %{
        path: "qualification/fixtures/migrations/v0.0.3/#{artifact["path"]}",
        encoding: artifact["encoding"],
        compressed_bytes: artifact["compressed_bytes"],
        compressed_sha256: artifact["compressed_sha256"],
        uncompressed_bytes: artifact["uncompressed_bytes"],
        uncompressed_sha256: artifact["uncompressed_sha256"]
      }
    }
  end

  defp qualify_previous_store!(store_name) do
    {:ok, complete} = GenServer.call(store_name, {:get_round, "previous_complete"})
    require!(match?(%Snapshot{}, complete), :completed_snapshot_shape_invalid)
    require!(complete.schema_version == 1, :completed_snapshot_schema_invalid)
    require!(complete.encoding_version == 1, :completed_snapshot_encoding_invalid)
    require!(complete.status == :complete, :completed_snapshot_status_invalid)
    require!(Snapshot.to_map(complete).id == "previous_complete", :completed_snapshot_unreadable)

    {:ok, manifest} = GenServer.call(store_name, {:get_manifest, "previous_complete"})
    require!(manifest.round_id == "previous_complete", :completed_manifest_unreadable)

    {:ok, audit} = GenServer.call(store_name, {:list_audit_events, "previous_complete", []})
    require!(length(audit) == 2, :legacy_audit_count_invalid)
    require!(Chain.verify(audit) == :ok, :legacy_audit_chain_invalid)

    {:ok, [interrupted]} = GenServer.call(store_name, :list_incomplete_rounds)
    require!(interrupted.schema_version == 1, :interrupted_snapshot_schema_invalid)
    require!(interrupted.encoding_version == 1, :interrupted_snapshot_encoding_invalid)

    {:ok, attempts} =
      GenServer.call(store_name, {:list_attempt_journals, "previous_interrupted"})

    {:ok, tools} = GenServer.call(store_name, {:list_tool_journals, "previous_interrupted"})
    require!(match?([%{status: :started}], attempts), :legacy_attempt_journal_invalid)

    require!(
      match?([%{status: :intent_recorded, safety_level: :write}], tools),
      :legacy_tool_journal_invalid
    )

    {:commit, reconciled} =
      Recovery.reconcile(interrupted,
        journals: %{attempts: attempts, tools: tools},
        now: ~U[2026-08-11 12:00:00Z]
      )

    require!(reconciled.status == :awaiting_reconciliation, :interrupted_round_retried)

    require!(
      Enum.all?(reconciled.shots, &(&1.status == :awaiting_reconciliation)),
      :interrupted_shot_retried
    )

    :ok =
      GenServer.call(
        store_name,
        {:commit_transition, interrupted.id, interrupted.version, "migrate-v0.0.3-interrupted",
         reconciled, [%{event_type: :round_awaiting_reconciliation}], []}
      )
  end

  defp qualify_reopened_store!(store_name) do
    {:ok, persisted} = GenServer.call(store_name, {:get_round, "previous_interrupted"})
    require!(persisted.status == :awaiting_reconciliation, :reconciliation_not_persisted)
    require!(persisted.version == 2, :reconciliation_version_invalid)
    require!(persisted.schema_version == 1, :reopened_snapshot_schema_invalid)
  end

  defp qualify_result_manifest_v1!(fixture_root) do
    fixture =
      fixture_root
      |> Path.join("result-manifest-v1.json")
      |> File.read!()
      |> Jason.decode!()

    payload = ResultManifest.payload(fixture["payload"])
    require!(payload == fixture["payload"], :result_manifest_v1_reinterpreted)

    {:ok, digest} =
      Canonical.digest("result-manifest", fixture["encoding_version"], payload)

    require!(digest == fixture["digest"], :result_manifest_v1_digest_changed)
    require!(not Map.has_key?(payload, "bundle_digest"), :result_manifest_v1_bundle_added)
    require!(not Map.has_key?(payload, "bundle_bytes"), :result_manifest_v1_bundle_added)
  end

  defp with_store(module, name, path, fun) do
    require!(Process.whereis(name) == nil, :qualification_store_already_running)
    {:ok, pid} = module.start_link(name: name, path: path)

    try do
      fun.()
    after
      if Process.alive?(pid), do: GenServer.stop(pid)
    end
  end

  defp passing_checks do
    %{
      previous_release_provenance: "pass",
      fixture_integrity: "pass",
      completed_record_readable: "pass",
      manifest_and_events_readable: "pass",
      legacy_audit_chain_migrated: "pass",
      snapshot_schema_upgraded: "pass",
      interrupted_write_not_retried: "pass",
      reconciliation_persisted_after_restart: "pass",
      result_manifest_v1_digest_preserved: "pass"
    }
  end

  defp failure_report(generated_at, reason) do
    %{
      schema_version: 1,
      generated_at: DateTime.to_iso8601(generated_at),
      status: "fail",
      reason: sanitized_reason(reason),
      checks: %{},
      host: host()
    }
  end

  defp host do
    %{
      os: inspect(:os.type()),
      architecture: to_string(:erlang.system_info(:system_architecture)),
      otp: to_string(:erlang.system_info(:otp_release)),
      elixir: System.version()
    }
  end

  defp qualification_tmp do
    Path.join(
      System.tmp_dir!(),
      "twelvgaige-migration-qualification-#{System.unique_integer([:positive])}"
    )
  end

  defp require!(true, _reason), do: :ok
  defp require!(false, reason), do: raise("migration qualification failed: #{reason}")

  defp write_evidence(destination, evidence) do
    destination = Path.expand(destination)
    staging = destination <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <-
           File.write(staging, [Jason.encode_to_iodata!(evidence, pretty: true), "\n"], [
             :exclusive
           ]),
         :ok <- File.chmod(staging, 0o600),
         :ok <- File.rename(staging, destination) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(staging)
        {:error, {:migration_evidence_write_failed, reason}}
    end
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp sanitized_reason(%{__exception__: true} = error), do: Exception.message(error)
  defp sanitized_reason({kind, reason}), do: "#{kind}: #{inspect(reason, limit: 10)}"
  defp sanitized_reason(reason), do: inspect(reason, limit: 10)
end
