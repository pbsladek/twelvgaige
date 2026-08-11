defmodule Twelvgaige.CLI.Commands.SessionResult do
  @moduledoc false

  alias Twelvgaige.Breech.IPC.{Client, Endpoint}
  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}

  def export(requested_id, args, deps \\ []) do
    with {:ok, opts} <- parse(args, defaults()),
         output when is_binary(output) <- opts[:output],
         {:ok, endpoint} <- discover(opts),
         {:ok, session_id} <- resolve_session(requested_id, endpoint, opts, deps),
         {:ok, session} <-
           get_fun(deps).(endpoint.address, session_id, client_opts(endpoint, opts)),
         workspace_id when is_binary(workspace_id) <- value(session, "workspace_id"),
         {:ok, report} <-
           export_fun(deps).(
             endpoint.address,
             workspace_id,
             Path.expand(output),
             client_opts(endpoint, opts)
           ) do
      {:ok, format_export(session_id, report, opts[:format]), 0}
    else
      nil -> error(:session_export_output_required, args)
      :none -> error(:daemon_unavailable, args)
      {:error, reason} -> error(reason, args)
      _missing -> error(:session_workspace_unavailable, args)
    end
  end

  def apply(requested_id, args, deps \\ []) do
    with {:ok, opts} <- parse(args, defaults()),
         :ok <- apply_authority(opts),
         {:ok, endpoint} <- discover(opts),
         {:ok, session_id} <- resolve_session(requested_id, endpoint, opts, deps),
         {:ok, session} <-
           get_fun(deps).(endpoint.address, session_id, client_opts(endpoint, opts)),
         workspace_id when is_binary(workspace_id) <- value(session, "workspace_id"),
         {:ok, report} <-
           apply_fun(deps).(
             endpoint.address,
             workspace_id,
             client_opts(endpoint, opts) ++
               [
                 write?: opts[:write?],
                 yes?: opts[:yes?],
                 expected_epoch: opts[:expected_epoch],
                 target: opts[:target]
               ]
           ) do
      {:ok, format_apply(session_id, report, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, args)
      {:error, reason} -> error(reason, args)
      _missing -> error(:session_workspace_unavailable, args)
    end
  end

  defp defaults do
    [
      format: :human,
      output: nil,
      repository: nil,
      write?: false,
      yes?: false,
      expected_epoch: nil,
      request_id: Twelvgaige.ID.new(:event),
      target: "review-worktree",
      ipc_timeout_ms: 30_000
    ]
  end

  defp parse([], opts), do: {:ok, opts}

  defp parse(["--format", value | rest], opts) when value in ["human", "json"],
    do: parse(rest, Keyword.put(opts, :format, String.to_existing_atom(value)))

  defp parse(["--output", value | rest], opts) when value != "",
    do: parse(rest, Keyword.put(opts, :output, value))

  defp parse(["--repo", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :repository, Path.expand(value)))

  defp parse(["--write" | rest], opts), do: parse(rest, Keyword.put(opts, :write?, true))
  defp parse(["--check" | rest], opts), do: parse(rest, Keyword.put(opts, :write?, false))
  defp parse(["--yes" | rest], opts), do: parse(rest, Keyword.put(opts, :yes?, true))

  defp parse(["--expected-epoch", value | rest], opts) do
    case Integer.parse(value) do
      {epoch, ""} when epoch >= 0 -> parse(rest, Keyword.put(opts, :expected_epoch, epoch))
      _invalid -> {:error, :workspace_expected_epoch_invalid}
    end
  end

  defp parse(["--request-id", value | rest], opts) when value != "",
    do: parse(rest, Keyword.put(opts, :request_id, value))

  defp parse(["--target", value | rest], opts)
       when value in ["review-worktree", "current-worktree"],
       do: parse(rest, Keyword.put(opts, :target, value))

  defp parse(["--runtime-dir", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :runtime_dir, value))

  defp parse(["--endpoint", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :endpoint_path, value))

  defp parse([unknown | _rest], _opts), do: {:error, {:unknown_option, unknown}}

  defp apply_authority(opts) do
    cond do
      opts[:write?] and not opts[:yes?] ->
        {:error, :workspace_apply_confirmation_required}

      opts[:write?] and is_nil(opts[:expected_epoch]) ->
        {:error, :workspace_expected_epoch_required}

      true ->
        :ok
    end
  end

  defp resolve_session(requested, endpoint, opts, deps) do
    with {:ok, sessions} <- list_fun(deps).(endpoint.address, client_opts(endpoint, opts)) do
      sessions = repository_filter(sessions, opts[:repository])

      cond do
        requested == "--last" and sessions == [] -> {:error, :session_not_found}
        requested == "--last" -> {:ok, sessions |> List.last() |> value("id")}
        exact = Enum.find(sessions, &(value(&1, "id") == requested)) -> {:ok, value(exact, "id")}
        true -> resolve_prefix(requested, sessions)
      end
    end
  end

  defp resolve_prefix(requested, sessions) do
    case Enum.filter(sessions, &String.starts_with?(value(&1, "id", ""), requested)) do
      [session] -> {:ok, value(session, "id")}
      [] -> {:error, :session_not_found}
      matches -> {:error, {:session_id_ambiguous, Enum.map(matches, &value(&1, "id"))}}
    end
  end

  defp repository_filter(sessions, nil), do: sessions

  defp repository_filter(sessions, repository),
    do: Enum.filter(sessions, &(Path.expand(value(&1, "repository", "")) == repository))

  defp discover(opts) do
    path = opts[:endpoint_path] || Endpoint.default_path(runtime_dir: opts[:runtime_dir])
    Endpoint.discover(path: path)
  end

  defp client_opts(endpoint, opts),
    do: [token: endpoint.token, timeout_ms: opts[:ipc_timeout_ms], request_id: opts[:request_id]]

  defp list_fun(deps), do: Keyword.get(deps, :list_fun, &Client.list_sessions/2)
  defp get_fun(deps), do: Keyword.get(deps, :get_fun, &Client.get_session/3)
  defp export_fun(deps), do: Keyword.get(deps, :export_fun, &Client.export_workspace/4)
  defp apply_fun(deps), do: Keyword.get(deps, :apply_fun, &Client.apply_workspace/3)

  defp format_export(session_id, report, :json),
    do: CommandHelpers.encode_line(Map.put(report, "session_id", session_id))

  defp format_export(session_id, report, :human),
    do:
      "Exported session #{session_id} to #{value(report, "destination")} (#{value(report, "patch_bytes")} patch bytes).\n"

  defp format_apply(session_id, report, :json),
    do: CommandHelpers.encode_line(Map.put(report, "session_id", session_id))

  defp format_apply(session_id, report, :human) do
    if value(report, "dry_run", true) do
      target_flag =
        if value(report, "target") == "current-worktree",
          do: " --target current-worktree",
          else: ""

      "Apply check passed for session #{session_id} (#{value(report, "target")}). Re-run with --write --yes --expected-epoch #{value(report, "expected_epoch")}#{target_flag}.\n"
    else
      if value(report, "target") == "current-worktree" do
        "Applied session #{session_id} to current worktree: #{value(report, "path")}\nRecovery backup: #{value(report, "backup_path")}\n"
      else
        "Verified review worktree for session #{session_id}: #{value(report, "path")}\nSource worktree unchanged; Git common metadata is shared.\n"
      end
    end
  end

  defp error(reason, args) do
    format = if("json" in args, do: :json, else: :human)
    {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end
end
