defmodule Twelvgaige.CLI.Commands.SessionFollow do
  @moduledoc false

  alias Twelvgaige.Breech.IPC.{Client, Endpoint}
  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}
  alias Twelvgaige.CLI.InterruptController
  alias Twelvgaige.Error

  @terminal ~w(complete completed failed cancelled revoked awaiting_review finalized)

  def run(session_id, args, deps \\ []) do
    with {:ok, opts} <-
           parse(args,
             format: :human,
             poll_ms: 1_000,
             follow_timeout_ms: 3_600_000,
             cancel_request_id: Twelvgaige.ID.new(:event)
           ),
         {:ok, endpoint} <- discover(opts),
         {:ok, result} <- follow(endpoint, session_id, opts, deps) do
      {:ok, format(result, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, args)
      {:error, reason} -> error(reason, args)
    end
  end

  def follow(endpoint, session_id, opts, deps \\ []) do
    request_id = opts[:cancel_request_id] || Twelvgaige.ID.new(:event)
    cancel_client = Keyword.get(deps, :cancel_client, &Client.cancel_session/3)

    cancel_fun = fn ->
      cancel_client.(endpoint.address, session_id,
        token: endpoint.token,
        request_id: request_id,
        timeout_ms: opts[:ipc_timeout_ms] || 30_000
      )
    end

    interrupt_opts = Keyword.get(deps, :interrupt_options, [])

    with {:ok, interrupts} <-
           InterruptController.install(session_id, request_id, cancel_fun, interrupt_opts) do
      try do
        started = System.monotonic_time(:millisecond)
        poll(endpoint, session_id, opts, deps, interrupts, started, -1, [])
      after
        InterruptController.uninstall(interrupts)
      end
    end
  end

  defp poll(endpoint, session_id, opts, deps, interrupts, started, after_seq, accumulated) do
    cond do
      InterruptController.detached?(interrupts) ->
        {:ok, detached_result(session_id, interrupts, accumulated)}

      true ->
        case InterruptController.take_cancellation_result(interrupts) do
          {:completed, {:error, reason}} ->
            {:error, cancellation_error(session_id, interrupts.request_id, reason)}

          _pending_or_success ->
            poll_attached(
              endpoint,
              session_id,
              opts,
              deps,
              interrupts,
              started,
              after_seq,
              accumulated
            )
        end
    end
  end

  defp poll_attached(
         endpoint,
         session_id,
         opts,
         deps,
         interrupts,
         started,
         after_seq,
         accumulated
       ) do
    client_opts = [token: endpoint.token, timeout_ms: opts[:ipc_timeout_ms] || 30_000]
    events_fun = Keyword.get(deps, :events_client, &Client.list_session_events/3)
    session_fun = Keyword.get(deps, :session_client, &Client.get_session/3)

    with {:ok, events} <-
           events_fun.(
             endpoint.address,
             session_id,
             Keyword.merge(client_opts, after_seq: after_seq)
           ),
         {:ok, session} <- session_fun.(endpoint.address, session_id, client_opts) do
      accumulated = accumulated ++ events
      next_seq = Enum.reduce(events, after_seq, &max(value(&1, "seq", 0), &2))

      cond do
        InterruptController.detached?(interrupts) ->
          {:ok, detached_result(session_id, interrupts, accumulated)}

        terminal?(value(session, "status")) ->
          {:ok,
           %{
             session_id: session_id,
             status: value(session, "status"),
             events: accumulated,
             session: session,
             cancellation_requested: InterruptController.cancellation_requested?(interrupts),
             cancellation_request_id:
               if(InterruptController.cancellation_requested?(interrupts),
                 do: interrupts.request_id,
                 else: nil
               )
           }}

        System.monotonic_time(:millisecond) - started >= opts[:follow_timeout_ms] ->
          {:error, :session_follow_timeout}

        true ->
          Keyword.get(deps, :sleep_fun, &Process.sleep/1).(opts[:poll_ms])
          poll(endpoint, session_id, opts, deps, interrupts, started, next_seq, accumulated)
      end
    end
  end

  defp parse([], opts), do: {:ok, opts}

  defp parse(["--format", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :format, CommandHelpers.parse_format(value)))

  defp parse(["--runtime-dir", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :runtime_dir, value))

  defp parse(["--endpoint", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :endpoint_path, value))

  defp parse(["--poll-ms", value | rest], opts), do: positive(rest, opts, :poll_ms, value)

  defp parse(["--timeout-ms", value | rest], opts),
    do: positive(rest, opts, :follow_timeout_ms, value)

  defp parse(["--cancel-request-id", value | rest], opts) when value != "",
    do: parse(rest, Keyword.put(opts, :cancel_request_id, value))

  defp parse([unknown | _rest], _opts), do: {:error, {:unknown_option, unknown}}

  defp positive(rest, opts, key, value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> parse(rest, Keyword.put(opts, key, number))
      _other -> {:error, {:invalid_positive_integer, key}}
    end
  end

  defp discover(opts) do
    path = opts[:endpoint_path] || Endpoint.default_path(runtime_dir: opts[:runtime_dir])
    Endpoint.discover(path: path)
  end

  defp terminal?(status), do: to_string(status) in @terminal
  defp format(result, :json), do: CommandHelpers.encode_line(result)

  defp format(%{status: "detached"} = result, :human) do
    "Session #{result.session_id}: detached\n" <>
      "The operation may still be running.\n" <>
      "Cancellation request: #{result.cancellation_request_id}\n" <>
      "Status: #{result.next_command}\n"
  end

  defp format(result, :human),
    do:
      "Session #{result.session_id}: #{result.status}\nEvents observed: #{length(result.events)}\n"

  defp detached_result(session_id, interrupts, events) do
    %{
      session_id: session_id,
      status: "detached",
      disposition: "unknown",
      operation_may_continue: true,
      cancellation_requested: InterruptController.cancellation_requested?(interrupts),
      cancellation_request_id: interrupts.request_id,
      events: events,
      next_command: "twelvgaige session show #{session_id}"
    }
  end

  defp cancellation_error(session_id, request_id, reason) do
    Error.new(
      :tool_error,
      :session_cancel_request_failed,
      "cancellation request failed; session status is unknown and it may still be running",
      retryable: true,
      details: %{
        session_id: session_id,
        request_id: request_id,
        disposition: "unknown",
        operation_may_continue: true,
        cause: cancellation_cause(reason),
        lookup_command: "twelvgaige session show #{session_id}"
      }
    )
  end

  defp cancellation_cause(%Error{reason: reason}), do: Atom.to_string(reason)
  defp cancellation_cause(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp cancellation_cause(_reason), do: "unknown"

  defp error(reason, args) do
    format = if("json" in args, do: :json, else: :human)
    {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
end
