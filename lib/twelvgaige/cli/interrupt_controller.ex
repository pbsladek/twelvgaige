defmodule Twelvgaige.CLI.InterruptController do
  @moduledoc """
  Implements the CLI's two-stage interrupt contract for an attached session.

  The signal callback does no blocking work. The first interrupt starts the
  normal daemon cancellation request in a separate process. The second marks
  the client detached without claiming that the remote operation stopped.
  """

  @type t :: %{
          counter: :atomics.atomics_ref(),
          parent: pid(),
          cancel_fun: (-> term()),
          output_fun: (String.t() -> term()),
          session_id: String.t(),
          request_id: String.t(),
          source: term(),
          source_stop_fun: (term() -> term())
        }

  @spec install(String.t(), String.t(), (-> term()), keyword()) :: {:ok, t()}
  def install(session_id, request_id, cancel_fun, opts \\ [])
      when is_binary(session_id) and is_binary(request_id) and is_function(cancel_fun, 0) do
    # Index 1 records received interrupts. Index 2 is an output barrier: the
    # detach notifier must not overtake the first cancellation notice when the
    # two signals arrive faster than their asynchronous tasks are scheduled.
    counter = :atomics.new(2, signed: false)

    handle = %{
      counter: counter,
      parent: self(),
      cancel_fun: cancel_fun,
      output_fun: Keyword.get(opts, :output_fun, &IO.write(:stderr, &1)),
      session_id: session_id,
      request_id: request_id,
      source: nil,
      source_stop_fun: Keyword.get(opts, :source_stop_fun, &Twelvgaige.CLI.InterruptSource.stop/1)
    }

    source_start_fun =
      Keyword.get(opts, :source_start_fun, &Twelvgaige.CLI.InterruptSource.start/1)

    case source_start_fun.(fn -> signal(handle) end) do
      {:ok, source} -> {:ok, %{handle | source: source}}
      {:error, :not_supported} -> {:ok, handle}
      {:error, reason} -> {:error, {:interrupt_trap_failed, reason}}
    end
  end

  @spec signal(t()) :: :ok
  def signal(handle) do
    case :atomics.add_get(handle.counter, 1, 1) do
      1 -> request_cancellation(handle)
      _later -> detach(handle)
    end

    :ok
  end

  @spec cancellation_requested?(t()) :: boolean()
  def cancellation_requested?(handle), do: :atomics.get(handle.counter, 1) >= 1

  @spec detached?(t()) :: boolean()
  def detached?(handle), do: :atomics.get(handle.counter, 1) >= 2

  @spec take_cancellation_result(t()) :: :pending | {:completed, term()}
  def take_cancellation_result(handle) do
    receive do
      {:twelvgaige_cancellation_result, request_id, result}
      when request_id == handle.request_id ->
        {:completed, result}
    after
      0 -> :pending
    end
  end

  @spec uninstall(t()) :: :ok
  def uninstall(%{source: nil}), do: :ok

  def uninstall(handle) do
    _ = handle.source_stop_fun.(handle.source)
    :ok
  end

  defp request_cancellation(handle) do
    {:ok, _pid} =
      Task.start(fn ->
        try do
          handle.output_fun.(
            "Cancellation requested for #{handle.session_id}; waiting for bounded shutdown.\n" <>
              "Status: twelvgaige session show #{handle.session_id}\n"
          )
        after
          :atomics.put(handle.counter, 2, 1)
        end

        result = handle.cancel_fun.()
        send(handle.parent, {:twelvgaige_cancellation_result, handle.request_id, result})
      end)

    :ok
  end

  defp detach(handle) do
    {:ok, _pid} =
      Task.start(fn ->
        await_cancellation_notice(handle.counter)

        handle.output_fun.(
          "Client detached from #{handle.session_id}; the operation may still be running.\n" <>
            "Status: twelvgaige session show #{handle.session_id}\n"
        )

        send(handle.parent, {:twelvgaige_detached, handle.request_id})
      end)

    :ok
  end

  defp await_cancellation_notice(counter) do
    if :atomics.get(counter, 2) == 1 do
      :ok
    else
      receive do
      after
        1 -> await_cancellation_notice(counter)
      end
    end
  end
end
