defmodule Twelvgaige.Operations.AuditAnchorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Operations.{AuditAnchor, LocalIdentity, Store}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-audit-anchor-#{System.unique_integer([:positive])}"
      )

    store = start_supervised!({Store, name: nil, path: Path.join(root, "operations.sqlite3")})
    {:ok, identity} = LocalIdentity.current()

    %{
      root: root,
      store: store,
      owner_uid: identity.uid,
      key: :crypto.strong_rand_bytes(32),
      path: Path.join(root, "audit/checkpoints.ndjson")
    }
  end

  test "writes a private, restart-safe signed checkpoint chain", context do
    assert {:ok, _event} = append_event(context.store, :first, ~U[2026-08-07 10:00:00Z])

    anchor = start_anchor(context, now: ~U[2026-08-07 10:01:00Z])
    assert %{status: :missing} = AuditAnchor.status(server: anchor)

    assert {:ok, %{sequence: 1, audit_position: 1}} = AuditAnchor.run(server: anchor)
    assert {:ok, %{sequence: 2, audit_position: 1}} = AuditAnchor.run(server: anchor)

    assert %{status: :healthy, checkpoint_count: 2, latest_sequence: 2} =
             AuditAnchor.status(server: anchor)

    assert {:ok, %{mode: mode}} = File.stat(context.path)
    assert Bitwise.band(mode, 0o777) == 0o600

    assert {:ok, records} =
             AuditAnchor.verify(context.path, context.key, owner_uid: context.owner_uid)

    assert length(records) == 2

    GenServer.stop(anchor)
    restarted = start_anchor(context, now: ~U[2026-08-07 10:02:00Z], id: :restarted_anchor)
    assert {:ok, %{sequence: 3}} = AuditAnchor.run(server: restarted)
    assert %{status: :healthy, checkpoint_count: 3} = AuditAnchor.status(server: restarted)
  end

  test "reports stale and tampered checkpoint evidence", context do
    clock = start_supervised!({Agent, fn -> ~U[2026-08-07 10:00:00Z] end})

    anchor =
      start_anchor(context,
        now_fun: fn -> Agent.get(clock, & &1) end,
        max_age_seconds: 60
      )

    assert {:ok, %{sequence: 1}} = AuditAnchor.run(server: anchor)
    Agent.update(clock, fn _ -> ~U[2026-08-07 10:02:00Z] end)
    assert %{status: :stale, age_seconds: 120} = AuditAnchor.status(server: anchor)

    [line] = context.path |> File.read!() |> String.split("\n", trim: true)
    tampered = Jason.decode!(line) |> Map.put("audit_position", 9) |> Jason.encode!()
    File.write!(context.path, tampered <> "\n")

    assert {:error, :audit_checkpoint_hash_invalid} =
             AuditAnchor.verify(context.path, context.key, owner_uid: context.owner_uid)

    assert %{status: :invalid, reason: :audit_checkpoint_hash_invalid} =
             AuditAnchor.status(server: anchor)
  end

  test "remains consistent when audit retention advances the retained base", context do
    assert {:ok, _event} = append_event(context.store, :old, ~U[2026-01-01 00:00:00Z])
    anchor = start_anchor(context, now: ~U[2026-01-01 00:01:00Z])
    assert {:ok, %{sequence: 1, audit_position: 1}} = AuditAnchor.run(server: anchor)

    assert {:ok, 1} = Store.prune(server: context.store, now: ~U[2026-08-07 00:00:00Z])
    assert {:ok, _event} = append_event(context.store, :new, ~U[2026-08-07 00:01:00Z])
    assert {:ok, %{sequence: 2, audit_position: 2}} = AuditAnchor.run(server: anchor)

    assert %{status: :healthy, checkpoint_count: 2, audit_position: 2} =
             AuditAnchor.status(server: anchor)
  end

  test "repairs a valid one-sided append seam for the optional external destination", context do
    external = Path.join(context.root, "external/checkpoints.ndjson")

    anchor =
      start_anchor(context,
        now: ~U[2026-08-07 10:00:00Z],
        external_path: external
      )

    assert {:ok, %{sequence: 1}} = AuditAnchor.run(server: anchor)
    assert {:ok, %{sequence: 2}} = AuditAnchor.run(server: anchor)
    [first, _second] = lines(context.path)

    File.write!(context.path, first <> "\n")

    assert %{status: :invalid, reason: :audit_checkpoint_external_diverged} =
             AuditAnchor.status(server: anchor)

    assert {:ok, %{sequence: 3}} = AuditAnchor.run(server: anchor)
    assert lines(context.path) == lines(external)

    [first, second, _third] = lines(external)
    File.write!(external, Enum.join([first, second], "\n") <> "\n")

    assert %{status: :invalid, reason: :audit_checkpoint_external_diverged} =
             AuditAnchor.status(server: anchor)

    assert {:ok, %{sequence: 4}} = AuditAnchor.run(server: anchor)
    assert lines(context.path) == lines(external)
    assert %{status: :healthy, checkpoint_count: 4} = AuditAnchor.status(server: anchor)
  end

  defp start_anchor(context, opts) do
    now_fun = Keyword.get(opts, :now_fun, fn -> Keyword.fetch!(opts, :now) end)

    start_supervised!(
      {AuditAnchor,
       name: nil,
       store: context.store,
       path: context.path,
       external_path: Keyword.get(opts, :external_path),
       signing_key: context.key,
       owner_uid: context.owner_uid,
       checkpoint_on_start?: false,
       interval_ms: 86_400_000,
       max_age_seconds: Keyword.get(opts, :max_age_seconds, 7_200),
       now_fun: now_fun},
      id: Keyword.get(opts, :id, :audit_anchor)
    )
  end

  defp append_event(store, type, occurred_at) do
    Store.append_audit(%{event_type: type, occurred_at: occurred_at}, server: store)
  end

  defp lines(path), do: path |> File.read!() |> String.split("\n", trim: true)
end
