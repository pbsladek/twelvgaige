defmodule Twelvgaige.Operations.RetentionIntegrationTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Artifact.Store, as: ArtifactStore
  alias Twelvgaige.Operations.{RetentionEnforcer, SessionControl, Store}

  test "active and resumable sessions hold transcripts and artifacts until terminal retention starts" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige-retention-#{System.unique_integer([:positive])}")

    started_at = ~U[2026-08-02 12:00:00Z]
    terminal_at = DateTime.add(started_at, 86_400, :second)
    expired_at = DateTime.add(terminal_at, 31 * 86_400, :second)
    store = start_supervised!({Store, name: nil, path: Path.join(root, "operations.sqlite3")})

    artifacts =
      start_supervised!(
        {ArtifactStore,
         name: nil, root: Path.join(root, "artifacts"), key: :crypto.strong_rand_bytes(32)}
      )

    assert {:ok, artifact} =
             ArtifactStore.put(%{output: "kept"},
               server: artifacts,
               session_id: "session_retention",
               now: started_at
             )

    control =
      start_supervised!(
        {SessionControl,
         name: nil,
         store: store,
         owner_uid: 42,
         username: "operator",
         artifact_store: artifacts,
         now_fun: fn -> started_at end}
      )

    assert {:ok, _session} =
             SessionControl.register(
               %{
                 id: "session_retention",
                 status: :running,
                 runtime: :codex,
                 artifact_refs: [artifact],
                 created_at: started_at
               },
               server: control,
               uid: 42,
               now: started_at
             )

    assert {:ok, _event} =
             SessionControl.append_event(
               "session_retention",
               %{id: "event_retention", type: :message, payload: %{text: "raw"}},
               server: control,
               uid: 42,
               now: started_at
             )

    enforcer =
      start_supervised!(
        {RetentionEnforcer,
         name: nil,
         store: store,
         artifact_store: artifacts,
         now_fun: fn -> DateTime.add(started_at, 31 * 86_400, :second) end,
         interval_ms: 86_400_000}
      )

    assert {:ok, %{records_removed: 0, artifacts_removed: 0}} =
             RetentionEnforcer.run(server: enforcer)

    assert {:ok, [_event]} =
             SessionControl.list_events("session_retention", server: control, uid: 42)

    assert {:ok, %{output: "kept"}} = ArtifactStore.get(artifact, server: artifacts)

    assert {:ok, %{status: :finalized}} =
             SessionControl.update("session_retention", %{status: :finalized},
               server: control,
               uid: 42,
               now: terminal_at
             )

    assert {:ok, records_removed} = Store.prune(server: store, now: expired_at)
    assert records_removed >= 2
    assert {:ok, 1} = ArtifactStore.prune(server: artifacts, now: expired_at)
    assert {:error, :not_found} = Store.get(:session, "session_retention", server: store)

    assert {:ok, []} =
             Store.list("session_event:session_retention", server: store)

    assert {:error, :enoent} = ArtifactStore.get(artifact, server: artifacts)
  end
end
