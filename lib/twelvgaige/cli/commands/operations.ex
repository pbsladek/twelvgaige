defmodule Twelvgaige.CLI.Commands.Operations do
  @moduledoc false

  alias Twelvgaige.Breech.IPC.{Client, Endpoint}
  alias Twelvgaige.CLI.CommandHelpers
  alias Twelvgaige.CLI.ExitCode

  def session_list(args), do: run(:session_list, nil, args)
  def session_show(id, args), do: run(:session_show, id, args)
  def session_attach(id, args), do: run(:session_attach, id, args)
  def session_takeover(id, args), do: run(:session_takeover, id, args)
  def session_revoke(id, args), do: run(:session_revoke, id, args)
  def sandbox_health(args), do: run(:sandbox_health, nil, args)
  def sandbox_reconcile(args), do: run(:sandbox_reconcile, nil, args)
  def dashboard(args), do: run(:dashboard, nil, args)
  def rotate_token(args), do: run(:rotate_token, nil, args)
  def audit_status(args), do: run(:audit_status, nil, args)
  def audit_checkpoint(args), do: run(:audit_checkpoint, nil, args)
  def audit_export(destination, args), do: run(:audit_export, destination, args)
  def store_stats(args), do: run(:store_stats, nil, args)
  def store_backup(destination, args), do: run(:store_backup, destination, args)

  def store_restore(source, destination, args),
    do: run(:store_restore, {source, destination}, args)

  def retention_status(args), do: run(:retention_status, nil, args)
  def retention_run(args), do: run(:retention_run, nil, args)
  def artifact_inventory(args), do: run(:artifact_inventory, nil, args)
  def artifact_rotate(args), do: run(:artifact_rotate, nil, args)
  def release_check(args), do: run(:release_check, nil, args)

  defp run(action, value, args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, endpoint} <- discover(opts),
         {:ok, result} <- execute(action, value, endpoint, opts) do
      {:ok, format(result, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, :human)
      {:error, reason} -> error(reason, :human)
    end
  end

  defp execute(:session_list, _value, endpoint, opts),
    do: Client.list_sessions(endpoint.address, client_opts(endpoint, opts))

  defp execute(:session_show, id, endpoint, opts),
    do: Client.get_session(endpoint.address, id, client_opts(endpoint, opts))

  defp execute(:session_attach, id, endpoint, opts),
    do: Client.attach_session(endpoint.address, id, client_opts(endpoint, opts))

  defp execute(:session_takeover, id, endpoint, opts) do
    case Keyword.fetch(opts, :expected_epoch) do
      {:ok, epoch} ->
        Client.takeover_session(endpoint.address, id, epoch, client_opts(endpoint, opts))

      :error ->
        {:error, :session_control_epoch_required}
    end
  end

  defp execute(:session_revoke, id, endpoint, opts),
    do: Client.revoke_session(endpoint.address, id, client_opts(endpoint, opts))

  defp execute(:sandbox_health, _value, endpoint, opts),
    do: Client.sandbox_health(endpoint.address, client_opts(endpoint, opts))

  defp execute(:sandbox_reconcile, _value, endpoint, opts),
    do:
      Client.reconcile_sandboxes(
        endpoint.address,
        Keyword.merge(client_opts(endpoint, opts),
          apply?: opts[:apply?],
          destroy_orphans?: opts[:destroy_orphans?]
        )
      )

  defp execute(:dashboard, _value, endpoint, opts),
    do: Client.operations_dashboard(endpoint.address, client_opts(endpoint, opts))

  defp execute(:rotate_token, _value, endpoint, opts),
    do: Client.rotate_token(endpoint.address, client_opts(endpoint, opts))

  defp execute(:audit_status, _value, endpoint, opts),
    do: Client.operations_audit_status(endpoint.address, client_opts(endpoint, opts))

  defp execute(:audit_checkpoint, _value, endpoint, opts),
    do: Client.checkpoint_operations_audit(endpoint.address, client_opts(endpoint, opts))

  defp execute(:audit_export, destination, endpoint, opts),
    do: Client.export_operations_audit(endpoint.address, destination, client_opts(endpoint, opts))

  defp execute(:store_stats, _value, endpoint, opts),
    do: Client.operations_store_stats(endpoint.address, client_opts(endpoint, opts))

  defp execute(:store_backup, destination, endpoint, opts),
    do: Client.backup_operations_store(endpoint.address, destination, client_opts(endpoint, opts))

  defp execute(:store_restore, {source, destination}, endpoint, opts),
    do:
      Client.restore_operations_store(
        endpoint.address,
        source,
        destination,
        client_opts(endpoint, opts)
      )

  defp execute(:retention_status, _value, endpoint, opts),
    do: Client.retention_status(endpoint.address, client_opts(endpoint, opts))

  defp execute(:retention_run, _value, endpoint, opts),
    do: Client.run_retention(endpoint.address, client_opts(endpoint, opts))

  defp execute(:artifact_inventory, _value, endpoint, opts),
    do: Client.artifact_inventory(endpoint.address, client_opts(endpoint, opts))

  defp execute(:artifact_rotate, _value, endpoint, opts) do
    Client.rotate_artifact_key(endpoint.address, client_opts(endpoint, opts))
  end

  defp execute(:release_check, _value, endpoint, opts),
    do: Client.operations_release_check(endpoint.address, client_opts(endpoint, opts))

  defp discover(opts) do
    path = opts[:endpoint_path] || Endpoint.default_path(runtime_dir: opts[:runtime_dir])
    Endpoint.discover(path: path)
  end

  defp client_opts(endpoint, opts),
    do: [token: endpoint.token, timeout_ms: opts[:timeout_ms]]

  defp parse_opts(args),
    do:
      parse_opts(args, format: :human, timeout_ms: 30_000, apply?: false, destroy_orphans?: false)

  defp parse_opts([], opts), do: validate_opts(opts)

  defp parse_opts(["--format", format | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :format, CommandHelpers.parse_format(format)))

  defp parse_opts(["--runtime-dir", path | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :runtime_dir, path))

  defp parse_opts(["--endpoint", path | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :endpoint_path, path))

  defp parse_opts(["--expected-epoch", value | rest], opts) do
    case Integer.parse(value) do
      {epoch, ""} when epoch > 0 -> parse_opts(rest, Keyword.put(opts, :expected_epoch, epoch))
      _other -> {:error, :session_control_epoch_invalid}
    end
  end

  defp parse_opts(["--apply" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :apply?, true))

  defp parse_opts(["--destroy-orphans" | rest], opts),
    do:
      parse_opts(
        rest,
        opts |> Keyword.put(:apply?, true) |> Keyword.put(:destroy_orphans?, true)
      )

  defp parse_opts([unknown | _rest], _opts), do: {:error, {:unknown_option, unknown}}

  defp validate_opts(opts), do: {:ok, opts}

  defp format(result, :json), do: CommandHelpers.encode_line(result)

  defp format(result, :human) do
    case result do
      sessions when is_list(sessions) ->
        sessions
        |> Enum.map_join("\n", fn session ->
          "#{value(session, "id")}\t#{value(session, "status")}\t#{value(session, "runtime")}"
        end)
        |> Kernel.<>("\n")

      %{"token" => token, "status" => "rotated"} ->
        "Control token rotated. Store this replacement securely:\n#{token}\n"

      map when is_map(map) ->
        Jason.encode_to_iodata!(map, pretty: true) |> IO.iodata_to_binary() |> Kernel.<>("\n")
    end
  end

  defp error(reason, format) do
    {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, String.to_existing_atom(key)))
end
