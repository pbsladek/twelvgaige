defmodule Twelvgaige.Operations.DelegatedSessionInventoryTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession
  alias Twelvgaige.DelegatedSession.{Controller, Event}
  alias Twelvgaige.Operations.{LocalIdentity, SessionControl, Store}

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-session-inventory-#{System.unique_integer([:positive])}"
      )

    store = start_supervised!({Store, name: nil, path: Path.join(root, "operations.sqlite3")})
    {:ok, identity} = LocalIdentity.current()

    control =
      start_supervised!(
        {SessionControl,
         name: nil,
         store: store,
         owner_uid: identity.uid,
         username: identity.username,
         workspace_root: Path.join(root, "workspaces")}
      )

    %{control: control}
  end

  test "controller lifecycle and native events are durable in the operator inventory", %{
    control: control
  } do
    session = session("session_inventory")
    controller = start_supervised!({Controller, session: session, session_control: control})

    assert {:ok, %{status: :running} = running} = Controller.start(controller)

    event =
      Event.new(
        session_id: running.id,
        event_type: :usage_updated,
        native_session_id: running.external_session_id,
        native_event_id: "usage-1",
        payload: %{input_tokens: 3, output_tokens: 2},
        occurred_at: ~U[2026-08-02 12:00:01Z]
      )

    assert :ok = Controller.ingest(controller, event)
    assert {:ok, stored} = SessionControl.get(running.id, server: control)
    assert stored.status == :running
    assert stored.sandbox_resource_id == running.sandbox_resource_id
    assert stored.last_event_sequence == 1

    assert {:ok, [stored_event]} = SessionControl.list_events(running.id, server: control)
    assert stored_event.native_event_id == "usage-1"
    assert stored_event.payload == %{input_tokens: 3, output_tokens: 2}

    # Durable native identity makes re-ingress idempotent across controller restarts.
    assert :duplicate = SessionControl.append_event(running.id, event, server: control)

    assert {:ok, %{status: :cancelled}} = Controller.cancel(controller, :operator_requested)
    assert {:ok, %{status: :cancelled}} = SessionControl.get(running.id, server: control)
    assert {:ok, %{status: :finalized}} = Controller.finalize(controller)
    assert {:ok, %{status: :finalized}} = SessionControl.get(running.id, server: control)
  end

  defp session(id) do
    now = ~U[2026-08-02 12:00:00Z]

    DelegatedSession.new(%{
      id: id,
      round_id: "round_1",
      shot_id: "delegate",
      attempt: 1,
      runtime: :mock,
      driver: :mock,
      runtime_version: "1",
      integration_descriptor_id: "mock-1",
      workspace_id: "ws_1",
      base_commit: String.duplicate("a", 40),
      auth_profile_id: "auth",
      auth_revision: "auth-1",
      sandbox_profile: :coding_restricted,
      sandbox_manifest_digest: String.duplicate("b", 64),
      policy_revision: "policy-1",
      budgets: %{tokens: 100},
      deadline: DateTime.add(now, 3_600),
      created_at: now
    })
  end
end
