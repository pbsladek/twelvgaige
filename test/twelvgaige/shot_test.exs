defmodule Twelvgaige.ShotTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Error
  alias Twelvgaige.Shot.Attempt
  alias Twelvgaige.Shot.State

  test "shot state defaults to pending recovery-safe fields" do
    state = State.new(id: "gather", kind: :slug, depends_on: ["root"])

    assert state.id == "gather"
    assert state.kind == :slug
    assert state.status == :pending
    assert state.attempt == 0
    assert state.depends_on == ["root"]
    assert state.condition == true
    assert state.history == []
  end

  test "shot status helpers distinguish terminal success from terminal failure" do
    assert State.terminal?(:complete)
    assert State.terminal?(:failed)
    assert State.terminal_success?(:complete)
    assert State.terminal_success?(:skipped)
    refute State.terminal_success?(:failed)
    refute State.terminal?(:running)
  end

  test "startable checks pending and due retrying shots" do
    now = ~U[2026-05-01 12:00:00Z]
    past = ~U[2026-05-01 11:59:59Z]
    future = ~U[2026-05-01 12:00:01Z]

    assert State.startable?(State.new(id: "pending", kind: :slug))

    assert State.startable?(
             State.new(id: "retry", kind: :slug, status: :retrying, next_retry_at: past),
             now
           )

    refute State.startable?(
             State.new(id: "retry", kind: :slug, status: :retrying, next_retry_at: future),
             now
           )

    refute State.startable?(State.new(id: "running", kind: :slug, status: :running), now)
  end

  test "shot state converts to JSON-safe snapshot shape" do
    error = Error.new(:output_error, :output_parse_error, "invalid JSON", retryable: true)

    map =
      State.new(
        id: "parse",
        kind: :slug,
        status: :failed,
        attempt: 2,
        started_at: ~U[2026-05-01 12:00:00Z],
        completed_at: ~U[2026-05-01 12:00:03Z],
        output: %{"raw" => "not-json"},
        error: error
      )
      |> State.to_map()

    assert map.status == "failed"
    assert map.kind == "slug"
    assert map.started_at == "2026-05-01T12:00:00Z"
    assert map.completed_at == "2026-05-01T12:00:03Z"
    assert map.error.reason == "output_parse_error"
    assert map.output == %{"raw" => "not-json"}
  end

  test "shot state output redacts canary secrets" do
    map =
      State.new(
        id: "secret",
        kind: :slug,
        status: :complete,
        output: %{
          "token" => "canary-secret",
          "stdout" => "Authorization: Bearer canary-secret"
        }
      )
      |> State.to_map()

    assert map.output["token"] == "[REDACTED]"
    assert map.output["stdout"] == "Authorization: Bearer [REDACTED]"
    refute inspect(map) =~ "canary-secret"
  end

  test "attempt validates immutable executor input" do
    attempt =
      Attempt.new(
        round_id: "round_123",
        shot_id: "gather",
        attempt: 1,
        definition: %{id: "gather", kind: "slug"},
        loadout: %{model: "mock"},
        input: %{"cluster" => "dev"},
        dependency_outputs: %{"root" => %{"ok" => true}}
      )

    assert Attempt.identity(attempt) == {"round_123", "gather", 1}
    assert attempt.input == %{"cluster" => "dev"}
    assert attempt.dependency_outputs == %{"root" => %{"ok" => true}}
  end

  test "attempt rejects invalid attempt numbers and payloads" do
    base = [
      round_id: "round_123",
      shot_id: "gather",
      definition: %{},
      loadout: %{},
      input: %{},
      dependency_outputs: %{}
    ]

    assert_raise ArgumentError, ~r/positive integer/, fn ->
      Attempt.new(Keyword.put(base, :attempt, 0))
    end

    assert_raise ArgumentError, ~r/input must be a map/, fn ->
      base
      |> Keyword.put(:attempt, 1)
      |> Keyword.put(:input, [])
      |> Attempt.new()
    end
  end
end
