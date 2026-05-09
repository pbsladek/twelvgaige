defmodule Twelvgaige.ResourceLimiterTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.ResourceLimiter
  alias Twelvgaige.ResourceLimiter.Permit

  defp start_limiter(opts \\ []) do
    opts =
      opts
      |> Keyword.put_new(:name, nil)

    start_supervised!(%{
      id: {:resource_limiter, make_ref()},
      start: {ResourceLimiter, :start_link, [opts]}
    })
  end

  test "starts with laptop profile limits" do
    limiter = start_limiter()

    assert %{
             profile: :laptop,
             limits: %{
               active_round: 1,
               active_shot: 4,
               active_shot_per_round: 3,
               llm_call: 4,
               tool_exec: 4,
               retained_bytes: 536_870_912
             },
             used: %{
               active_round: 0,
               active_shot: 0,
               llm_call: 0,
               tool_exec: 0,
               retained_bytes: 0
             },
             permits: [],
             queue_depth: %{
               active_round: 0,
               active_shot: 0,
               llm_call: 0,
               tool_exec: 0,
               retained_bytes: 0
             },
             denials: []
           } = ResourceLimiter.snapshot(limiter)
  end

  test "starts with named profile limits" do
    limiter = start_limiter(profile: :minimal)

    assert %{
             profile: :minimal,
             limits: %{
               active_round: 1,
               active_shot: 1,
               active_shot_per_round: 1,
               llm_call: 1,
               tool_exec: 1,
               retained_bytes: 134_217_728
             }
           } = ResourceLimiter.snapshot(limiter)

    limiter = start_limiter(profile: "server")

    assert %{
             profile: :server,
             limits: %{active_round: 16, active_shot: 32, llm_call: 32, tool_exec: 32}
           } = ResourceLimiter.snapshot(limiter)
  end

  test "rejects invalid profile names at startup" do
    previous = Process.flag(:trap_exit, true)

    try do
      assert {:error, error} = ResourceLimiter.start_link(name: nil, profile: "desktop")
      assert error.class == :input_error
      assert error.reason == :invalid_shell
    after
      Process.flag(:trap_exit, previous)
    end
  end

  test "grants and releases active round permits" do
    limiter = start_limiter()

    assert {:ok, %Permit{} = permit} =
             ResourceLimiter.acquire(:active_round, %{round_id: "round-1"}, server: limiter)

    assert ResourceLimiter.acquire(:active_round, %{round_id: "round-2"}, server: limiter) ==
             {:error, {:limit_exceeded, :active_round}}

    assert ResourceLimiter.snapshot(limiter).used.active_round == 1
    assert :ok = ResourceLimiter.release(permit)
    assert ResourceLimiter.snapshot(limiter).used.active_round == 0
  end

  test "active shot permits enforce global and per-round limits" do
    limiter = start_limiter(limits: %{active_shot: 2, active_shot_per_round: 1})

    assert {:ok, r1_shot} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "round-1", shot_id: "a"},
               server: limiter
             )

    assert ResourceLimiter.acquire(:active_shot, %{round_id: "round-1", shot_id: "b"},
             server: limiter
           ) ==
             {:error, {:limit_exceeded, :active_shot_per_round}}

    assert {:ok, _r2_shot} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "round-2", shot_id: "a"},
               server: limiter
             )

    assert ResourceLimiter.acquire(:active_shot, %{round_id: "round-3", shot_id: "a"},
             server: limiter
           ) ==
             {:error, {:limit_exceeded, :active_shot}}

    assert ResourceLimiter.snapshot(limiter).used.active_shot == 2

    assert ResourceLimiter.snapshot(limiter).per_round.active_shot == %{
             "round-1" => 1,
             "round-2" => 1
           }

    assert :ok = ResourceLimiter.release(r1_shot)
    assert ResourceLimiter.snapshot(limiter).used.active_shot == 1
    assert ResourceLimiter.snapshot(limiter).per_round.active_shot == %{"round-2" => 1}
  end

  test "llm and tool permits deny immediately when saturated" do
    limiter = start_limiter(limits: %{llm_call: 1, tool_exec: 1})

    assert {:ok, llm_permit} = ResourceLimiter.acquire(:llm_call, %{}, server: limiter)

    assert ResourceLimiter.acquire(:llm_call, %{}, server: limiter) ==
             {:error, {:limit_exceeded, :llm_call}}

    assert {:ok, tool_permit} = ResourceLimiter.acquire(:tool_exec, %{}, server: limiter)

    assert ResourceLimiter.acquire(:tool_call, %{}, server: limiter) ==
             {:error, {:limit_exceeded, :tool_exec}}

    assert [
             %{resource_kind: :llm_call, reason: :limit_exceeded, count: 1},
             %{resource_kind: :tool_exec, reason: :limit_exceeded, count: 1}
           ] = ResourceLimiter.snapshot(limiter).denials

    assert :ok = ResourceLimiter.release(llm_permit)
    assert :ok = ResourceLimiter.release(tool_permit)
    assert ResourceLimiter.snapshot(limiter).used.llm_call == 0
    assert ResourceLimiter.snapshot(limiter).used.tool_exec == 0
  end

  test "queues waiters only when requested and notifies the owner after release" do
    limiter = start_limiter(limits: %{llm_call: 1})

    assert {:ok, permit} =
             ResourceLimiter.acquire(:llm_call, %{round_id: "round-1"}, server: limiter)

    assert ResourceLimiter.acquire(:llm_call, %{round_id: "round-2"}, server: limiter) ==
             {:error, {:limit_exceeded, :llm_call}}

    assert {:queued, waiter} =
             ResourceLimiter.acquire(:llm_call, %{round_id: "round-2"},
               server: limiter,
               queue?: true
             )

    assert ResourceLimiter.snapshot(limiter).queue_depth.llm_call == 1

    assert :ok = ResourceLimiter.release(permit)
    assert_receive {:resource_available, waiter_id, :llm_call}
    assert waiter_id == waiter.id
    assert ResourceLimiter.snapshot(limiter).queue_depth.llm_call == 0

    assert {:ok, queued_permit} =
             ResourceLimiter.acquire(:llm_call, %{round_id: "round-2"}, server: limiter)

    assert :ok = ResourceLimiter.release(queued_permit)
  end

  test "cancel_waiter removes queued requests idempotently" do
    limiter = start_limiter(limits: %{tool_exec: 1})
    assert {:ok, permit} = ResourceLimiter.acquire(:tool_exec, %{}, server: limiter)

    assert {:queued, waiter} =
             ResourceLimiter.acquire(:tool_call, %{round_id: "round-1"},
               server: limiter,
               queue?: true
             )

    assert ResourceLimiter.snapshot(limiter).queue_depth.tool_exec == 1
    assert :ok = ResourceLimiter.cancel_waiter(waiter)
    assert :ok = ResourceLimiter.cancel_waiter(waiter)
    assert ResourceLimiter.snapshot(limiter).queue_depth.tool_exec == 0
    assert :ok = ResourceLimiter.release(permit)
    refute_receive {:resource_available, _waiter_id, _resource_kind}, 20
  end

  test "queued waiters can expire independently from execution timeouts" do
    limiter = start_limiter(limits: %{llm_call: 1})
    assert {:ok, permit} = ResourceLimiter.acquire(:llm_call, %{}, server: limiter)

    assert {:queued, waiter} =
             ResourceLimiter.acquire(:llm_call, %{round_id: "round-timeout"},
               server: limiter,
               queue?: true,
               queue_timeout_ms: 5
             )

    assert waiter.queue_timeout_ms == 5
    assert ResourceLimiter.snapshot(limiter).queue_depth.llm_call == 1

    assert_receive {:resource_timeout, waiter_id, :llm_call}, 200
    assert waiter_id == waiter.id
    assert ResourceLimiter.snapshot(limiter).queue_depth.llm_call == 0

    assert [
             %{resource_kind: :llm_call, reason: :queue_timeout, count: 1}
           ] = ResourceLimiter.snapshot(limiter).denials

    assert :ok = ResourceLimiter.release(permit)
    refute_receive {:resource_available, ^waiter_id, :llm_call}, 20
  end

  test "cancelled waiter timeouts are ignored after cancellation" do
    limiter = start_limiter(limits: %{tool_exec: 1})
    assert {:ok, permit} = ResourceLimiter.acquire(:tool_exec, %{}, server: limiter)

    assert {:queued, waiter} =
             ResourceLimiter.acquire(:tool_call, %{round_id: "round-cancel-timeout"},
               server: limiter,
               queue?: true,
               queue_timeout_ms: 5
             )

    assert :ok = ResourceLimiter.cancel_waiter(waiter)
    refute_receive {:resource_timeout, _waiter_id, _resource_kind}, 30
    assert :ok = ResourceLimiter.release(permit)
  end

  test "invalid queue timeouts are rejected before queueing" do
    limiter = start_limiter(limits: %{llm_call: 1})

    assert ResourceLimiter.acquire(:llm_call, %{},
             server: limiter,
             queue?: true,
             queue_timeout_ms: -1
           ) == {:error, :invalid_queue_timeout}

    assert ResourceLimiter.acquire(:llm_call, %{"queue_timeout_ms" => false},
             server: limiter,
             queue?: true
           ) == {:error, :invalid_queue_timeout}
  end

  test "invalid explicit byte counts are rejected before permits are granted" do
    limiter = start_limiter(limits: %{llm_call: 1, retained_bytes: 10})

    assert ResourceLimiter.acquire(:retained_bytes, %{"bytes" => false}, server: limiter) ==
             {:error, :invalid_bytes}

    assert ResourceLimiter.acquire(:llm_call, %{"bytes" => false}, server: limiter) ==
             {:error, :invalid_bytes}
  end

  test "owner process down removes queued waiters" do
    limiter = start_limiter(limits: %{llm_call: 1})
    assert {:ok, permit} = ResourceLimiter.acquire(:llm_call, %{}, server: limiter)
    parent = self()

    owner =
      spawn(fn ->
        result =
          ResourceLimiter.acquire(:llm_call, %{round_id: "round-queued"},
            server: limiter,
            queue?: true
          )

        send(parent, {:queued, result})

        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(owner)

    assert_receive {:queued, {:queued, _waiter}}
    assert ResourceLimiter.snapshot(limiter).queue_depth.llm_call == 1

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}
    assert eventually(fn -> ResourceLimiter.snapshot(limiter).queue_depth.llm_call == 0 end)

    assert :ok = ResourceLimiter.release(permit)
    refute_receive {:resource_available, _waiter_id, _resource_kind}, 20
  end

  test "owner process down releases held permits, drops its waiters, and notifies next owner" do
    limiter = start_limiter(limits: %{active_shot: 1, active_shot_per_round: 1})
    parent = self()

    owner =
      spawn(fn ->
        held =
          ResourceLimiter.acquire(:active_shot, %{round_id: "owner-1", shot_id: "held"},
            server: limiter
          )

        queued =
          ResourceLimiter.acquire(:active_shot, %{round_id: "owner-1", shot_id: "queued"},
            server: limiter,
            queue?: true
          )

        send(parent, {:owner_state, held, queued})

        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(owner)

    assert_receive {:owner_state, {:ok, %Permit{}}, {:queued, owner_waiter}}

    assert {:queued, next_waiter} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "owner-2", shot_id: "next"},
               server: limiter,
               queue?: true
             )

    assert ResourceLimiter.snapshot(limiter).used.active_shot == 1
    assert ResourceLimiter.snapshot(limiter).queue_depth.active_shot == 2

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}

    assert eventually(fn ->
             snapshot = ResourceLimiter.snapshot(limiter)
             snapshot.used.active_shot == 0 and snapshot.queue_depth.active_shot == 0
           end)

    assert_receive {:resource_available, waiter_id, :active_shot}, 100
    assert waiter_id == next_waiter.id

    owner_waiter_id = owner_waiter.id
    refute_receive {:resource_available, ^owner_waiter_id, :active_shot}, 20
  end

  test "active shot queue notifications are round-robin across rounds and FIFO within a round" do
    limiter = start_limiter(limits: %{active_shot: 1, active_shot_per_round: 1})

    assert {:ok, held} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "round-0", shot_id: "held"},
               server: limiter
             )

    assert {:queued, round_1_a} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "round-1", shot_id: "a"},
               server: limiter,
               queue?: true
             )

    assert {:queued, _round_1_b} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "round-1", shot_id: "b"},
               server: limiter,
               queue?: true
             )

    assert {:queued, round_2_a} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "round-2", shot_id: "a"},
               server: limiter,
               queue?: true
             )

    assert :ok = ResourceLimiter.release(held)
    assert_receive {:resource_available, waiter_id, :active_shot}
    assert waiter_id == round_1_a.id

    assert {:ok, round_1_permit} =
             ResourceLimiter.acquire(:active_shot, %{round_id: "round-1", shot_id: "a"},
               server: limiter
             )

    assert :ok = ResourceLimiter.release(round_1_permit)
    assert_receive {:resource_available, waiter_id, :active_shot}
    assert waiter_id == round_2_a.id
  end

  test "unknown resources are counted as denials" do
    limiter = start_limiter()

    assert ResourceLimiter.acquire(:not_a_resource, %{}, server: limiter) ==
             {:error, {:unknown_resource_kind, :not_a_resource}}

    assert [
             %{resource_kind: :not_a_resource, reason: :unknown_resource_kind, count: 1}
           ] = ResourceLimiter.snapshot(limiter).denials
  end

  test "retained byte permits account by byte size" do
    limiter = start_limiter(limits: %{retained_bytes: 10})

    assert {:ok, six_bytes} =
             ResourceLimiter.acquire(:retained_bytes, %{bytes: 6}, server: limiter)

    assert ResourceLimiter.acquire(:retained_bytes, %{bytes: 5}, server: limiter) ==
             {:error, {:limit_exceeded, :retained_bytes}}

    assert ResourceLimiter.snapshot(limiter).used.retained_bytes == 6
    assert :ok = ResourceLimiter.release(six_bytes)
    assert ResourceLimiter.snapshot(limiter).used.retained_bytes == 0
  end

  test "owner process down releases held permits" do
    limiter = start_limiter(limits: %{llm_call: 1})
    parent = self()

    owner =
      spawn(fn ->
        result = ResourceLimiter.acquire(:llm_call, %{}, server: limiter)
        send(parent, {:acquired, result})

        receive do
          :stop -> :ok
        end
      end)

    ref = Process.monitor(owner)

    assert_receive {:acquired, {:ok, %Permit{} = permit}}
    assert permit.owner_pid == owner
    assert ResourceLimiter.snapshot(limiter).used.llm_call == 1

    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^owner, :normal}

    assert eventually(fn -> ResourceLimiter.snapshot(limiter).used.llm_call == 0 end)
    assert ResourceLimiter.release(permit) == {:error, :unknown_permit}
  end

  test "release requires the exact permit token" do
    limiter = start_limiter()

    assert {:ok, permit} = ResourceLimiter.acquire(:llm_call, %{}, server: limiter)
    changed_permit = %{permit | shot_id: "not-the-token"}

    assert ResourceLimiter.release(changed_permit) == {:error, :permit_mismatch}
    assert ResourceLimiter.snapshot(limiter).used.llm_call == 1
    assert :ok = ResourceLimiter.release(permit)
  end

  defp eventually(fun, attempts \\ 20)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: false
end
