defmodule Twelvgaige.RoundTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Error
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Round.State
  alias Twelvgaige.Shot

  test "round state builds all provided shots as pending by default" do
    state =
      State.new(
        id: "round_123",
        shell_id: "workflow",
        shell_version: "1.0.0",
        input: %{"cluster" => "dev"},
        shots: [
          %{id: "root", kind: :slug},
          %{id: "child", kind: :slug, depends_on: ["root"]}
        ]
      )

    assert state.status == :queued
    assert state.version == 0
    assert map_size(state.shot_states) == 2
    assert state.shot_states["root"].status == :pending
    assert state.shot_states["child"].depends_on == ["root"]
  end

  test "round status and transition helpers follow the normative transition table" do
    assert State.terminal?(:complete)
    assert State.terminal?(:failed)
    refute State.terminal?(:blocked_on_store)

    assert State.transition_allowed?(:queued, :chambered)
    assert State.transition_allowed?(:chambered, :firing)
    assert State.transition_allowed?(:firing, :awaiting_safety)
    assert State.transition_allowed?(:awaiting_safety, :halted)
    assert State.transition_allowed?(:firing, :complete)
    assert State.transition_allowed?(:firing, :cancelled)
    assert State.transition_allowed?(:awaiting_safety, :blocked_on_store)
    assert State.transition_allowed?(:blocked_on_store, :firing)

    refute State.transition_allowed?(:complete, :cancelled)
    refute State.transition_allowed?(:queued, :complete)
  end

  test "all_shots_successful accepts complete and skipped shots only" do
    successful =
      State.new(
        id: "round_123",
        shell_id: "workflow",
        shell_version: "1.0.0",
        shots: [
          Shot.State.new(id: "a", kind: :slug, status: :complete),
          Shot.State.new(id: "b", kind: :slug, status: :skipped)
        ]
      )

    failed = State.put_shot(successful, Shot.State.new(id: "b", kind: :slug, status: :failed))

    assert State.all_shots_successful?(successful)
    refute State.all_shots_successful?(failed)
  end

  test "snapshot projection excludes live runtime fields and sorts shots" do
    state =
      State.new(
        id: "round_123",
        shell_id: "workflow",
        shell_version: "1.0.0",
        status: :firing,
        version: 3,
        input: %{"cluster" => "dev"},
        policy: %{resource_profile: :laptop},
        started_at: ~U[2026-05-01 12:00:00Z],
        inflight: %{make_ref() => %{pid: self()}},
        round_timeout_ref: make_ref(),
        pending_transition: %{transition_id: "transition_1"},
        shots: [
          Shot.State.new(id: "b", kind: :slug, status: :pending),
          Shot.State.new(id: "a", kind: :slug, status: :complete, output: %{"ok" => true})
        ]
      )

    snapshot = Snapshot.from_state(state)

    assert snapshot.id == "round_123"
    assert snapshot.status == :firing
    assert snapshot.version == 3
    assert Enum.map(snapshot.shots, & &1.id) == ["a", "b"]
    refute Map.has_key?(snapshot, :inflight)
    refute Map.has_key?(snapshot, :round_timeout_ref)
    refute Map.has_key?(snapshot, :pending_transition)
  end

  test "snapshot converts to JSON-safe map shape" do
    error = Error.new(:store_error, :store_unavailable, "store is unavailable", retryable: true)

    map =
      Snapshot.new(
        id: "round_123",
        shell_id: "workflow",
        shell_version: "1.0.0",
        status: :failed,
        version: 5,
        started_at: ~U[2026-05-01 12:00:00Z],
        completed_at: ~U[2026-05-01 12:00:05Z],
        error: error,
        shots: [Shot.State.new(id: "a", kind: :slug, status: :complete)],
        resource_profile: :laptop,
        store_status: :ok
      )
      |> Snapshot.to_map()

    assert map.status == "failed"
    assert map.started_at == "2026-05-01T12:00:00Z"
    assert map.completed_at == "2026-05-01T12:00:05Z"
    assert map.error.reason == "store_unavailable"
    assert [%{id: "a", status: "complete"}] = map.shots
    assert map.resource_profile == "laptop"
    assert map.store_status == "ok"
  end

  test "snapshot output redacts canary secrets" do
    map =
      Snapshot.new(
        id: "round_secret",
        shell_id: "workflow",
        shell_version: "1.0.0",
        input: %{"token" => "canary-secret"},
        shots: [
          Shot.State.new(
            id: "a",
            kind: :slug,
            status: :complete,
            output: %{"authorization" => "Bearer canary-secret"}
          )
        ]
      )
      |> Snapshot.to_map()

    assert map.input["token"] == "[REDACTED]"
    assert [%{output: %{"authorization" => "[REDACTED]"}}] = map.shots
    refute inspect(map) =~ "canary-secret"
  end

  test "round state rebuilds from snapshot without runtime fields" do
    snapshot =
      Snapshot.new(
        id: "round_123",
        shell_id: "workflow",
        shell_version: "1.0.0",
        status: :firing,
        version: 7,
        shots: [Shot.State.new(id: "a", kind: :slug, status: :complete)]
      )

    state = State.from_snapshot(snapshot, pattern: %{graph: []}, manifest: %{id: "manifest"})

    assert state.id == "round_123"
    assert state.version == 7
    assert state.pattern == %{graph: []}
    assert state.manifest == %{id: "manifest"}
    assert state.inflight == %{}
    assert state.round_timeout_ref == nil
    assert state.pending_transition == nil
    assert state.shot_states["a"].status == :complete
  end

  test "round event preserves injected identity and timestamp" do
    event =
      Event.new(
        id: "event_1",
        round_id: "round_123",
        seq: 1,
        transition_id: "transition_1",
        round_version: 2,
        event_type: :shot_completed,
        shot_id: "gather",
        payload: %{attempt: 1},
        occurred_at: ~U[2026-05-01 12:00:00Z]
      )

    assert Event.to_map(event) == %{
             id: "event_1",
             round_id: "round_123",
             seq: 1,
             transition_id: "transition_1",
             round_version: 2,
             event_type: "shot_completed",
             event_class: "operational",
             shot_id: "gather",
             payload: %{attempt: 1},
             occurred_at: "2026-05-01T12:00:00Z"
           }
  end
end
