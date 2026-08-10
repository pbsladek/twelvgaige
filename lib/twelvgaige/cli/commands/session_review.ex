defmodule Twelvgaige.CLI.Commands.SessionReview do
  @moduledoc false

  alias Twelvgaige.Breech.IPC.{Client, Endpoint}
  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}

  def run(session_id, args, deps \\ []) do
    with {:ok, opts} <- parse(args, format: :human, timeout_ms: 30_000),
         {:ok, endpoint} <- discover(opts),
         {:ok, result} <-
           client(deps).(endpoint.address, session_id,
             token: endpoint.token,
             timeout_ms: opts[:timeout_ms]
           ) do
      {:ok, format(result, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, args)
      {:error, reason} -> error(reason, args)
    end
  end

  defp client(deps), do: Keyword.get(deps, :client, &Client.review_session/3)
  defp parse([], opts), do: {:ok, opts}

  defp parse(["--format", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :format, CommandHelpers.parse_format(value)))

  defp parse(["--runtime-dir", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :runtime_dir, value))

  defp parse(["--endpoint", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :endpoint_path, value))

  defp parse([unknown | _rest], _opts), do: {:error, {:unknown_option, unknown}}

  defp discover(opts) do
    path = opts[:endpoint_path] || Endpoint.default_path(runtime_dir: opts[:runtime_dir])
    Endpoint.discover(path: path)
  end

  defp format(result, :json), do: CommandHelpers.encode_line(result)

  defp format(result, :human),
    do: Jason.encode_to_iodata!(result, pretty: true) |> IO.iodata_to_binary() |> Kernel.<>("\n")

  defp error(reason, args) do
    format = if("json" in args, do: :json, else: :human)
    {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
  end
end
