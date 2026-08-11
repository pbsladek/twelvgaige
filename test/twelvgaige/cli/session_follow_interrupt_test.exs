defmodule Twelvgaige.CLI.SessionFollowInterruptTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Commands.SessionFollow

  test "first interrupt requests normal cancellation and waits for terminal state" do
    parent = self()
    endpoint = %{address: {:tcp, {127, 0, 0, 1}, 1}, token: "token"}
    calls = :atomics.new(1, signed: false)

    source_start = fn callback ->
      Process.put(:session_follow_interrupt, callback)
      {:ok, :test_source}
    end

    session = fn _address, "sess_cancel", _opts ->
      status = if :atomics.add_get(calls, 1, 1) == 1, do: "running", else: "cancelled"
      {:ok, %{"status" => status}}
    end

    cancel = fn _address, "sess_cancel", opts ->
      send(parent, {:cancel_request, opts[:request_id]})
      {:ok, %{"status" => "cancelling"}}
    end

    sleep = fn _milliseconds ->
      Process.get(:session_follow_interrupt).()
      Process.sleep(5)
    end

    assert {:ok, result} =
             SessionFollow.follow(
               endpoint,
               "sess_cancel",
               [
                 poll_ms: 1,
                 follow_timeout_ms: 100,
                 ipc_timeout_ms: 10,
                 cancel_request_id: "req_cancel"
               ],
               events_client: fn _, _, _ -> {:ok, []} end,
               session_client: session,
               cancel_client: cancel,
               sleep_fun: sleep,
               interrupt_options: [
                 source_start_fun: source_start,
                 source_stop_fun: fn :test_source -> :ok end,
                 output_fun: fn output -> send(parent, {:interrupt_output, output}) end
               ]
             )

    assert result.status == "cancelled"
    assert result.cancellation_requested
    assert result.cancellation_request_id == "req_cancel"
    assert_receive {:cancel_request, "req_cancel"}
    assert_receive {:interrupt_output, output}
    assert output =~ "Cancellation requested"
    assert output =~ "twelvgaige session show sess_cancel"
  end

  test "second interrupt detaches without claiming the session stopped" do
    parent = self()
    endpoint = %{address: {:tcp, {127, 0, 0, 1}, 1}, token: "token"}

    source_start = fn callback ->
      Process.put(:session_follow_interrupt, callback)
      {:ok, :test_source}
    end

    sleep = fn _milliseconds ->
      callback = Process.get(:session_follow_interrupt)
      callback.()
      callback.()
      Process.sleep(5)
    end

    assert {:ok, result} =
             SessionFollow.follow(
               endpoint,
               "sess_detach",
               [
                 poll_ms: 1,
                 follow_timeout_ms: 100,
                 ipc_timeout_ms: 10,
                 cancel_request_id: "req_detach"
               ],
               events_client: fn _, _, _ -> {:ok, []} end,
               session_client: fn _, _, _ -> {:ok, %{"status" => "running"}} end,
               cancel_client: fn _, _, opts ->
                 send(parent, {:cancel_request, opts[:request_id]})
                 {:ok, %{"status" => "cancelling"}}
               end,
               sleep_fun: sleep,
               interrupt_options: [
                 source_start_fun: source_start,
                 source_stop_fun: fn :test_source -> :ok end,
                 output_fun: fn output ->
                   # Force the asynchronous second notifier to become runnable
                   # first. The controller must still preserve user-visible
                   # signal order.
                   if String.starts_with?(output, "Cancellation requested"),
                     do: Process.sleep(20)

                   send(parent, {:interrupt_output, output})
                 end
               ]
             )

    assert result.status == "detached"
    assert result.disposition == "unknown"
    assert result.operation_may_continue
    assert result.cancellation_requested
    assert result.cancellation_request_id == "req_detach"
    assert result.next_command == "twelvgaige session show sess_detach"
    assert_receive {:cancel_request, "req_detach"}
    assert_receive {:interrupt_output, first}
    assert first =~ "Cancellation requested"
    assert_receive {:interrupt_output, second}
    assert second =~ "may still be running"
    refute second =~ "stopped"
  end

  test "failed cancellation returns an unknown disposition with a status command" do
    endpoint = %{address: {:tcp, {127, 0, 0, 1}, 1}, token: "token"}

    source_start = fn callback ->
      Process.put(:session_follow_interrupt, callback)
      {:ok, :test_source}
    end

    sleep = fn _milliseconds ->
      Process.get(:session_follow_interrupt).()
      Process.sleep(10)
    end

    assert {:error, error} =
             SessionFollow.follow(
               endpoint,
               "sess_cancel_failure",
               [
                 poll_ms: 1,
                 follow_timeout_ms: 100,
                 ipc_timeout_ms: 10,
                 cancel_request_id: "req_cancel_failure"
               ],
               events_client: fn _, _, _ -> {:ok, []} end,
               session_client: fn _, _, _ -> {:ok, %{"status" => "running"}} end,
               cancel_client: fn _, _, _ -> {:error, :daemon_unavailable} end,
               sleep_fun: sleep,
               interrupt_options: [
                 source_start_fun: source_start,
                 source_stop_fun: fn :test_source -> :ok end,
                 output_fun: fn _output -> :ok end
               ]
             )

    assert error.reason == :session_cancel_request_failed
    assert error.details.disposition == "unknown"
    assert error.details.operation_may_continue
    assert error.details.request_id == "req_cancel_failure"

    assert error.details.lookup_command ==
             "twelvgaige session show sess_cancel_failure"
  end
end
