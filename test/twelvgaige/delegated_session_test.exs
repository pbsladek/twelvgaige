defmodule Twelvgaige.DelegatedSessionTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession
  alias Twelvgaige.DelegatedSession.Controller
  alias Twelvgaige.DelegatedSession.Event

  test "exact resume rejects workspace, auth, sandbox, and policy drift" do
    durable = session()

    assert :ok = DelegatedSession.resume_compatible?(durable, durable)

    candidate = %{
      durable
      | workspace_id: "ws_other",
        auth_revision: "auth-2",
        sandbox_manifest_digest: String.duplicate("c", 64),
        policy_revision: "policy-2"
    }

    assert {:error,
            {:identity_drift,
             [:workspace_id, :auth_revision, :sandbox_manifest_digest, :policy_revision]}} =
             DelegatedSession.resume_compatible?(durable, candidate)
  end

  test "controller deduplicates events and reserves cancellation under a delta flood" do
    {:ok, controller} =
      Controller.start_link(
        session: session(),
        event_capacity: 8,
        critical_event_reserve: 2
      )

    on_exit(fn -> if Process.alive?(controller), do: GenServer.stop(controller) end)
    assert {:ok, started} = Controller.start(controller)
    assert started.status == :running

    for index <- 1..1_000 do
      event =
        Event.new(
          session_id: started.id,
          event_type: :message_delta,
          native_session_id: started.external_session_id,
          native_event_id: "delta-#{index}",
          payload: %{index: index},
          occurred_at: DateTime.utc_now()
        )

      assert :ok = Controller.ingest(controller, event)
    end

    assert {:ok, cancelled} = Controller.cancel(controller, :user_requested)
    assert cancelled.status == :cancelled
    assert {:ok, finalized} = Controller.finalize(controller)
    assert finalized.status == :finalized
  end

  defp session do
    now = ~U[2026-08-02 12:00:00Z]

    DelegatedSession.new(%{
      id: "sess_1",
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
