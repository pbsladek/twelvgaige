defmodule Twelvgaige.Breech.IPC.Client do
  @moduledoc """
  Client for the local Breech IPC protocol.
  """

  alias Twelvgaige.Breech.IPC.Protocol
  alias Twelvgaige.Error
  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot

  @timeout_ms 30_000
  @classes_by_string Map.new(Error.classes(), &{Atom.to_string(&1), &1})
  @reasons_by_string Map.new(Error.reasons(), &{Atom.to_string(&1), &1})

  @type address ::
          {:tcp, :inet.ip_address(), :inet.port_number()}
          | {:unix, Path.t()}

  @spec status(address(), keyword()) :: {:ok, map()} | {:error, term()}
  def status(address, opts \\ []) do
    call(address, "status", %{}, opts)
  end

  @spec stop_daemon(address(), keyword()) :: :ok | {:error, term()}
  def stop_daemon(address, opts \\ []) do
    case call(address, "daemon.stop", %{}, opts) do
      {:ok, %{"status" => "stopping"}} -> :ok
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec rotate_token(address(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def rotate_token(address, opts \\ []) do
    case call(address, "daemon.token.rotate", %{}, opts) do
      {:ok, %{"status" => "rotated", "token" => token}} when is_binary(token) -> {:ok, token}
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  def list_workspaces(address, opts \\ []), do: call(address, "workspace.list", %{}, opts)

  def get_workspace(address, workspace_id, opts \\ []),
    do: call(address, "workspace.show", %{"workspace_id" => workspace_id}, opts)

  def workspace_diff(address, workspace_id, opts \\ []),
    do: call(address, "workspace.diff", %{"workspace_id" => workspace_id}, opts)

  def cleanup_workspace(address, workspace_id, opts \\ []) do
    call(
      address,
      "workspace.cleanup",
      %{
        "workspace_id" => workspace_id,
        "write" => Keyword.get(opts, :write?, false),
        "yes" => Keyword.get(opts, :yes?, false),
        "expected_epoch" => Keyword.get(opts, :expected_epoch)
      },
      opts
    )
  end

  def export_workspace(address, workspace_id, destination, opts \\ []) do
    call(
      address,
      "workspace.export",
      %{"workspace_id" => workspace_id, "destination" => destination},
      opts
    )
  end

  def apply_workspace(address, workspace_id, opts \\ []) do
    call(
      address,
      "workspace.apply",
      %{
        "workspace_id" => workspace_id,
        "target" => Keyword.get(opts, :target, "review-worktree"),
        "write" => Keyword.get(opts, :write?, false),
        "yes" => Keyword.get(opts, :yes?, false),
        "expected_epoch" => Keyword.get(opts, :expected_epoch)
      },
      opts
    )
  end

  def reconcile_workspace(address, workspace_id, opts \\ []) do
    call(
      address,
      "workspace.reconcile",
      %{
        "workspace_id" => workspace_id,
        "write" => Keyword.get(opts, :write?, false),
        "yes" => Keyword.get(opts, :yes?, false),
        "action" => reconcile_action(Keyword.get(opts, :action, "quarantine")),
        "expected_epoch" => Keyword.get(opts, :expected_epoch)
      },
      opts
    )
  end

  defp reconcile_action(:restore_backup), do: "restore-backup"
  defp reconcile_action(:resume_export), do: "resume-export"
  defp reconcile_action(:resume_cleanup), do: "resume-cleanup"
  defp reconcile_action(:discard_review), do: "discard-review"
  defp reconcile_action(action), do: action

  def cleanup_review_worktree(address, workspace_id, opts \\ []) do
    call(
      address,
      "workspace.review.cleanup",
      %{
        "workspace_id" => workspace_id,
        "write" => Keyword.get(opts, :write?, false),
        "yes" => Keyword.get(opts, :yes?, false),
        "expected_epoch" => Keyword.get(opts, :expected_epoch)
      },
      opts
    )
  end

  def workspace_retention_status(address, opts \\ []),
    do: call(address, "workspace.retention.status", %{}, opts)

  def run_workspace_retention(address, opts \\ []),
    do: call(address, "workspace.retention.run", %{}, opts)

  def list_workspace_sets(address, opts \\ []),
    do: call(address, "workspace.set.list", %{}, opts)

  def get_workspace_set(address, set_id, opts \\ []),
    do: call(address, "workspace.set.show", %{"set_id" => set_id}, opts)

  def list_sessions(address, opts \\ []) do
    body = maybe_put(%{}, "status", Keyword.get(opts, :status))
    call(address, "session.list", body, opts)
  end

  def start_session(address, attrs, opts \\ []) when is_map(attrs),
    do: call(address, "session.start", attrs, opts)

  def get_session(address, session_id, opts \\ []),
    do: call(address, "session.show", %{"session_id" => session_id}, opts)

  def get_operation(address, request_id, opts \\ []),
    do: call(address, "operation.show", %{"request_id" => request_id}, opts)

  def list_session_events(address, session_id, opts \\ []) do
    body =
      %{"session_id" => session_id}
      |> maybe_put("after_seq", Keyword.get(opts, :after_seq))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    call(address, "session.events", body, opts)
  end

  def review_session(address, session_id, opts \\ []),
    do: call(address, "session.review", %{"session_id" => session_id}, opts)

  def retry_session(address, session_id, opts \\ []) do
    call(
      address,
      "session.retry",
      %{"session_id" => session_id, "repair" => Keyword.get(opts, :repair?, false)},
      opts
    )
  end

  def attach_session(address, session_id, opts \\ []),
    do: call(address, "session.attach", %{"session_id" => session_id}, opts)

  def takeover_session(address, session_id, expected_epoch, opts \\ []) do
    call(
      address,
      "session.takeover",
      %{"session_id" => session_id, "expected_epoch" => expected_epoch},
      opts
    )
  end

  def revoke_session(address, session_id, opts \\ []),
    do: call(address, "session.revoke", %{"session_id" => session_id}, opts)

  def cancel_session(address, session_id, opts \\ []),
    do: call(address, "session.cancel", %{"session_id" => session_id}, opts)

  def sandbox_health(address, opts \\ []), do: call(address, "sandbox.health", %{}, opts)

  def reconcile_sandboxes(address, opts \\ []) do
    call(
      address,
      "sandbox.reconcile",
      %{
        "apply" => Keyword.get(opts, :apply?, false),
        "destroy_orphans" => Keyword.get(opts, :destroy_orphans?, false)
      },
      opts
    )
  end

  def operations_dashboard(address, opts \\ []),
    do: call(address, "operations.dashboard", %{}, opts)

  def operations_audit_status(address, opts \\ []),
    do: call(address, "operations.audit.status", %{}, opts)

  def checkpoint_operations_audit(address, opts \\ []),
    do: call(address, "operations.audit.checkpoint", %{}, opts)

  def export_operations_audit(address, destination, opts \\ []),
    do: call(address, "operations.audit.export", %{"destination" => destination}, opts)

  def operations_store_stats(address, opts \\ []),
    do: call(address, "operations.store.stats", %{}, opts)

  def backup_operations_store(address, destination, opts \\ []),
    do: call(address, "operations.store.backup", %{"destination" => destination}, opts)

  def restore_operations_store(address, source, destination, opts \\ []),
    do:
      call(
        address,
        "operations.store.restore",
        %{"source" => source, "destination" => destination},
        opts
      )

  def retention_status(address, opts \\ []),
    do: call(address, "operations.retention.status", %{}, opts)

  def run_retention(address, opts \\ []),
    do: call(address, "operations.retention.run", %{}, opts)

  def artifact_inventory(address, opts \\ []),
    do: call(address, "operations.artifact.inventory", %{}, opts)

  def rotate_artifact_key(address, opts \\ []),
    do: call(address, "operations.artifact.rotate", %{}, opts)

  def operations_release_check(address, opts \\ []),
    do: call(address, "operations.release.check", %{}, opts)

  @spec start_round(address(), Path.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start_round(address, workflow_path, input, opts \\ []) do
    body = %{
      "workflow_path" => workflow_path,
      "input" => input,
      "opts" => run_opts(opts)
    }

    case call(address, "round.run", body, opts) do
      {:ok, %{"id" => round_id}} when is_binary(round_id) -> {:ok, round_id}
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec get_round(address(), String.t(), keyword()) :: {:ok, Snapshot.t()} | {:error, term()}
  def get_round(address, round_id, opts \\ []) do
    case call(address, "round.show", %{"round_id" => round_id}, opts) do
      {:ok, snapshot} when is_map(snapshot) -> {:ok, Snapshot.new(snapshot)}
      {:error, _reason} = error -> error
    end
  end

  @spec list_rounds(address(), keyword()) :: {:ok, [Snapshot.t()]} | {:error, term()}
  def list_rounds(address, opts \\ []) do
    body =
      case Keyword.get(opts, :status) do
        nil -> %{}
        status -> %{"status" => to_string(status)}
      end

    case call(address, "round.list", body, opts) do
      {:ok, snapshots} when is_list(snapshots) -> {:ok, Enum.map(snapshots, &Snapshot.new/1)}
      {:error, _reason} = error -> error
    end
  end

  @spec list_round_events(address(), String.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def list_round_events(address, round_id, opts \\ []) do
    body =
      %{"round_id" => round_id}
      |> maybe_put("after_seq", Keyword.get(opts, :after_seq))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    case call(address, "round.events", body, opts) do
      {:ok, events} when is_list(events) -> {:ok, Enum.map(events, &Event.new/1)}
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec list_audit_events(address(), String.t(), keyword()) ::
          {:ok, [AuditEvent.t()]} | {:error, term()}
  def list_audit_events(address, round_id, opts \\ []) do
    body =
      %{"round_id" => round_id}
      |> maybe_put("after_seq", Keyword.get(opts, :after_seq))
      |> maybe_put("limit", Keyword.get(opts, :limit))

    case call(address, "round.audit", body, opts) do
      {:ok, events} when is_list(events) -> {:ok, events}
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec await_round_events(address(), String.t(), keyword()) ::
          {:ok, [Event.t()]} | {:error, term()}
  def await_round_events(address, round_id, opts \\ []) do
    wait_timeout_ms = normalize_timeout_ms(Keyword.get(opts, :timeout_ms, @timeout_ms))

    body =
      %{"round_id" => round_id}
      |> maybe_put("after_seq", Keyword.get(opts, :after_seq))
      |> maybe_put("limit", Keyword.get(opts, :limit))
      |> maybe_put("timeout_ms", wait_timeout_ms)

    call_opts = Keyword.put(opts, :timeout_ms, wait_timeout_ms + 1_000)

    case call(address, "round.events.await", body, call_opts) do
      {:ok, events} when is_list(events) -> {:ok, Enum.map(events, &Event.new/1)}
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec approve_safety(address(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def approve_safety(address, round_id, shot_id, opts \\ []) do
    safety_decision(address, "round.approve", round_id, shot_id, opts)
  end

  @spec reject_safety(address(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def reject_safety(address, round_id, shot_id, opts \\ []) do
    safety_decision(address, "round.reject", round_id, shot_id, opts)
  end

  @spec cancel_round(address(), String.t(), keyword()) :: :ok | {:error, term()}
  def cancel_round(address, round_id, opts \\ []) do
    body = %{
      "round_id" => round_id,
      "reason" => Keyword.get(opts, :reason),
      "actor" => Keyword.get(opts, :actor)
    }

    case call(address, "round.cancel", body, opts) do
      {:ok, %{"status" => "accepted"}} -> :ok
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec call(address(), String.t(), map(), keyword()) :: {:ok, term()} | {:error, term()}
  def call({:tcp, ip, port}, command, body, opts)
      when is_tuple(ip) and is_integer(port) and is_binary(command) and is_map(body) do
    request =
      Protocol.request(command, body,
        token: Keyword.get(opts, :token),
        request_id: Keyword.get(opts, :request_id)
      )

    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    case connect_tcp(ip, port, timeout) do
      {:ok, socket} -> exchange(socket, request, command, timeout)
      {:error, reason} -> {:error, transport_error(reason)}
    end
  end

  def call({:unix, path}, command, body, opts)
      when is_binary(path) and is_binary(command) and is_map(body) do
    request =
      Protocol.request(command, body,
        token: Keyword.get(opts, :token),
        request_id: Keyword.get(opts, :request_id)
      )

    timeout = Keyword.get(opts, :timeout_ms, @timeout_ms)

    case connect_unix(path, timeout) do
      {:ok, socket} -> exchange(socket, request, command, timeout)
      {:error, reason} -> {:error, transport_error(reason)}
    end
  end

  def call(_address, _command, _body, _opts), do: {:error, :invalid_ipc_address}

  defp exchange(socket, request, command, timeout) do
    try do
      with :ok <- :gen_tcp.send(socket, Protocol.encode(request)),
           {:ok, payload} <- receive_response(socket, command, request, timeout),
           {:ok, response} <- Protocol.decode(payload) do
        decode_response(response)
      else
        {:error, %Error{} = error} -> {:error, error}
        {:error, :timeout} -> {:error, client_timeout(command, request, timeout)}
        {:error, reason} -> {:error, transport_error(reason)}
      end
    after
      _ = :gen_tcp.close(socket)
    end
  end

  defp receive_response(socket, command, request, timeout) do
    case :gen_tcp.recv(socket, 0, timeout) do
      {:error, :timeout} -> {:error, client_timeout(command, request, timeout)}
      result -> result
    end
  end

  defp client_timeout(command, request, timeout) do
    request_id = Map.fetch!(request, "request_id")

    Error.new(
      :timeout_error,
      :client_timeout,
      "client stopped waiting after #{timeout} ms; operation status is unknown",
      retryable: true,
      details: %{
        request_id: request_id,
        command: command,
        disposition: "unknown",
        operation_may_continue: true,
        lookup_command: "twelvgaige operation show #{request_id}"
      }
    )
  end

  defp safety_decision(address, command, round_id, shot_id, opts) do
    body = %{
      "round_id" => round_id,
      "shot_id" => shot_id,
      "reason" => Keyword.get(opts, :reason),
      "actor" => Keyword.get(opts, :actor)
    }

    case call(address, command, body, opts) do
      {:ok, %{"status" => "accepted"}} -> :ok
      {:ok, _body} -> {:error, :invalid_response}
      {:error, _reason} = error -> error
    end
  end

  @spec parse_address(String.t()) :: {:ok, address()} | {:error, :invalid_ipc_address}
  def parse_address("tcp://" <> _rest = address) do
    case URI.parse(address) do
      %URI{scheme: "tcp", host: host, port: port}
      when is_binary(host) and is_integer(port) ->
        with {:ok, ip} <- parse_ip(host) do
          {:ok, {:tcp, ip, port}}
        else
          _error -> {:error, :invalid_ipc_address}
        end

      _other ->
        {:error, :invalid_ipc_address}
    end
  end

  def parse_address("unix://" <> path) when byte_size(path) > 0 do
    {:ok, {:unix, path}}
  end

  def parse_address(address) when is_binary(address), do: {:error, :invalid_ipc_address}

  def parse_address(_address), do: {:error, :invalid_ipc_address}

  defp connect_tcp(ip, port, timeout) do
    :gen_tcp.connect(ip, port, [:binary, packet: 4, active: false], timeout)
  end

  defp connect_unix(path, timeout) do
    :gen_tcp.connect({:local, path}, 0, [:binary, packet: 4, active: false], timeout)
  end

  defp decode_response(%{"ok" => true, "body" => body}), do: {:ok, body}
  defp decode_response(%{"ok" => false, "error" => error}), do: {:error, decode_error(error)}
  defp decode_response(_response), do: {:error, :invalid_response}

  defp decode_error(%{"class" => class, "reason" => reason, "message" => message} = error) do
    with {:ok, class} <- known_class(class),
         {:ok, reason} <- known_reason(reason) do
      Error.new(class, reason, message,
        retryable: Map.get(error, "retryable", false),
        safety_required: Map.get(error, "safety_required", false),
        details: Map.get(error, "details", %{})
      )
    else
      :error -> Map.get(error, "reason", :unknown)
    end
  end

  defp decode_error(%{"reason" => "not_found"}), do: :not_found
  defp decode_error(%{"reason" => "workspace_set_not_found"}), do: :workspace_set_not_found

  defp decode_error(%{"reason" => reason}) when is_binary(reason) do
    case known_reason(reason) do
      {:ok, reason} -> reason
      :error -> :unknown
    end
  end

  defp decode_error(_error), do: :unknown

  defp known_class(class) when is_binary(class) do
    case Map.fetch(@classes_by_string, class) do
      {:ok, class} -> {:ok, class}
      :error -> :error
    end
  end

  defp known_reason(reason) when is_binary(reason) do
    case Map.fetch(@reasons_by_string, reason) do
      {:ok, reason} -> {:ok, reason}
      :error -> :error
    end
  end

  defp run_opts(opts) do
    %{}
    |> maybe_put("approve_all_safety?", Keyword.get(opts, :approve_all_safety?))
    |> maybe_put("agent_shells", Keyword.get(opts, :agent_shells))
    |> maybe_put("discover_agents?", Keyword.get(opts, :discover_agents?))
    |> maybe_put("trusted_root?", Keyword.get(opts, :trusted_root?))
    |> maybe_put("untrusted_root?", Keyword.get(opts, :untrusted_root?))
    |> maybe_put(
      "allow_untrusted_agent_discovery?",
      Keyword.get(opts, :allow_untrusted_agent_discovery?)
    )
    |> maybe_put("profile", Keyword.get(opts, :profile) || Keyword.get(opts, :resource_profile))
    |> maybe_put("round_id", Keyword.get(opts, :round_id))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_timeout_ms(timeout_ms) when is_integer(timeout_ms) and timeout_ms >= 0,
    do: timeout_ms

  defp normalize_timeout_ms(timeout_ms) when is_binary(timeout_ms) do
    case Integer.parse(timeout_ms) do
      {integer, ""} when integer >= 0 -> integer
      _other -> @timeout_ms
    end
  end

  defp normalize_timeout_ms(_timeout_ms), do: @timeout_ms

  defp parse_ip(host) do
    host
    |> String.to_charlist()
    |> :inet.parse_address()
  end

  defp transport_error(:econnrefused), do: :daemon_unavailable
  defp transport_error(:closed), do: :daemon_unavailable
  defp transport_error(:timeout), do: :daemon_unavailable
  defp transport_error(reason), do: reason
end
