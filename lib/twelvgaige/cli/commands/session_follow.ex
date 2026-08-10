defmodule Twelvgaige.CLI.Commands.SessionFollow do
  @moduledoc false

  alias Twelvgaige.Breech.IPC.{Client, Endpoint}
  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}

  @terminal ~w(complete completed failed cancelled revoked awaiting_review finalized)

  def run(session_id, args, deps \\ []) do
    with {:ok, opts} <- parse(args, format: :human, poll_ms: 1_000, follow_timeout_ms: 3_600_000),
         {:ok, endpoint} <- discover(opts),
         {:ok, result} <- follow(endpoint, session_id, opts, deps) do
      {:ok, format(result, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, args)
      {:error, reason} -> error(reason, args)
    end
  end

  def follow(endpoint, session_id, opts, deps \\ []) do
    started = System.monotonic_time(:millisecond)
    poll(endpoint, session_id, opts, deps, started, -1, [])
  end

  defp poll(endpoint, session_id, opts, deps, started, after_seq, accumulated) do
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
        terminal?(value(session, "status")) ->
          {:ok,
           %{
             session_id: session_id,
             status: value(session, "status"),
             events: accumulated,
             session: session
           }}

        System.monotonic_time(:millisecond) - started >= opts[:follow_timeout_ms] ->
          {:error, :session_follow_timeout}

        true ->
          Keyword.get(deps, :sleep_fun, &Process.sleep/1).(opts[:poll_ms])
          poll(endpoint, session_id, opts, deps, started, next_seq, accumulated)
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

  defp format(result, :human),
    do:
      "Session #{result.session_id}: #{result.status}\nEvents observed: #{length(result.events)}\n"

  defp error(reason, args) do
    format = if("json" in args, do: :json, else: :human)
    {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
end
