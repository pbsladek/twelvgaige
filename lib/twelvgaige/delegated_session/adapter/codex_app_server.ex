defmodule Twelvgaige.DelegatedSession.Adapter.CodexAppServer do
  @moduledoc "Governed delegated-session adapter for Codex App Server protocol v2."

  @behaviour Twelvgaige.DelegatedSession.Adapter

  alias Twelvgaige.DelegatedSession.Codex.{AppServerClient, AuthProfile, Schema}

  @impl true
  def capabilities(config) do
    with :ok <- Schema.verify_bundle(value(config, :schema_path, Schema.bundle_path())),
         :ok <- verify_version(config) do
      {:ok,
       %{
         structured_protocol: true,
         protocol_version: Schema.protocol_version(),
         schema_digest: Schema.digest(),
         exact_resume: true,
         fork: true,
         steer: true,
         native_approvals: true,
         native_subagents: true,
         experimental_api: false,
         transport: :stdio
       }}
    end
  end

  @impl true
  def prepare(spec) do
    config = adapter_config(spec)
    client_module = value(config, :client_module, AppServerClient)

    with {:ok, _capabilities} <- capabilities(config),
         {:ok, client, owned?} <- client(config, spec, client_module),
         {:ok, initialize_result} <- client_module.initialize(client, initialize_opts(config)) do
      {:ok,
       %{
         client: client,
         client_module: client_module,
         client_owned?: owned?,
         config: config,
         spec: spec,
         initialize_result: initialize_result
       }}
    end
  end

  @impl true
  def authenticate(prepared, lease) do
    profile = auth_profile(prepared.config)
    context = %{mode: value(prepared.config, :mode, :unattended), lease: lease}

    with :ok <- AuthProfile.validate(profile, context),
         :ok <- auth_identity_matches?(profile, lease) do
      {:ok, Map.put(prepared, :auth_profile, profile)}
    end
  end

  @impl true
  def start(prepared, spec) do
    config = prepared.config
    client_module = prepared.client_module

    with {:ok, thread_result} <-
           request_with_backoff(
             prepared,
             "thread/start",
             thread_params(config),
             deadline(spec, config)
           ),
         {:ok, thread_id} <- exact_id(thread_result, ["thread", "id"], :thread),
         {:ok, turn_id} <- maybe_start_initial_turn(prepared, thread_id, spec, config) do
      handle = %{
        client: prepared.client,
        client_module: client_module,
        client_owned?: prepared.client_owned?,
        thread_id: thread_id,
        turn_id: turn_id,
        config: config,
        session_id: value(spec, :id)
      }

      {:ok, handle, %{external_session_id: thread_id, external_turn_id: turn_id}}
    end
  end

  @impl true
  def resume(external_id, prepared, spec) do
    params =
      prepared.config
      |> thread_params()
      |> Map.put("threadId", external_id)

    with {:ok, result} <-
           request_with_backoff(
             prepared,
             "thread/resume",
             params,
             deadline(spec, prepared.config)
           ),
         {:ok, ^external_id} <- exact_id(result, ["thread", "id"], :thread) do
      handle = %{
        client: prepared.client,
        client_module: prepared.client_module,
        client_owned?: prepared.client_owned?,
        thread_id: external_id,
        turn_id: value(spec, :external_turn_id),
        config: prepared.config,
        session_id: value(spec, :id)
      }

      {:ok, handle,
       %{external_session_id: external_id, external_turn_id: value(spec, :external_turn_id)}}
    else
      {:ok, other_id} -> {:error, {:codex_resume_identity_mismatch, external_id, other_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def send_input(handle, input) do
    params = turn_params(handle.thread_id, input, handle.config)

    case request_with_backoff(handle, "turn/start", params, deadline(%{}, handle.config)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def decide(handle, approval_id, receipt) when is_map(receipt),
    do: handle.client_module.decide(handle.client, approval_id, receipt)

  def decide(_handle, _approval_id, _decision),
    do: {:error, :digest_bound_approval_receipt_required}

  @impl true
  def cancel(handle, _reason) do
    with {:ok, status} <- handle.client_module.status(handle.client),
         thread_id when is_binary(thread_id) <- status.thread_id || handle.thread_id,
         turn_id when is_binary(turn_id) <- status.turn_id || handle.turn_id,
         {:ok, _result} <-
           handle.client_module.request(
             handle.client,
             "turn/interrupt",
             %{"threadId" => thread_id, "turnId" => turn_id}
           ) do
      :ok
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def snapshot(handle) do
    with {:ok, status} <- handle.client_module.status(handle.client) do
      {:ok,
       %{
         external_session_id: status.thread_id || handle.thread_id,
         external_turn_id: status.turn_id || handle.turn_id,
         schema_digest: status.schema_digest,
         protocol_buffer: status.buffer,
         overloaded?: status.overloaded?
       }}
    end
  end

  @impl true
  def reconcile(durable, observed) do
    expected_thread = value(durable, :external_session_id)
    expected_turn = value(durable, :external_turn_id)

    cond do
      expected_thread != observed.external_session_id ->
        {:ok, :awaiting_reconciliation,
         %{reason: :thread_identity_mismatch, expected: expected_thread, observed: observed}}

      present?(expected_turn) and expected_turn != observed.external_turn_id ->
        {:ok, :awaiting_reconciliation,
         %{reason: :turn_identity_mismatch, expected: expected_turn, observed: observed}}

      observed.schema_digest != Schema.digest() ->
        {:ok, :awaiting_reconciliation, %{reason: :schema_identity_mismatch, observed: observed}}

      true ->
        {:ok, :resume, observed}
    end
  end

  @impl true
  def finalize(handle) do
    with {:ok, snapshot} <- snapshot(handle),
         {:ok, events} <- handle.client_module.drain(handle.client, 10_000) do
      result = Map.put(snapshot, :events, events)
      if handle.client_owned?, do: handle.client_module.close(handle.client)
      {:ok, result}
    end
  end

  def fork(handle, opts \\ []) do
    params =
      handle.config
      |> thread_params()
      |> Map.put("threadId", handle.thread_id)
      |> maybe_put("lastTurnId", Keyword.get(opts, :last_turn_id))

    with {:ok, result} <-
           request_with_backoff(handle, "thread/fork", params, deadline(%{}, handle.config)),
         {:ok, forked_id} <- exact_id(result, ["thread", "id"], :thread),
         true <- forked_id != handle.thread_id do
      {:ok, forked_id}
    else
      false -> {:error, :codex_fork_reused_parent_identity}
      {:error, reason} -> {:error, reason}
    end
  end

  def steer(handle, expected_turn_id, input) do
    params = %{
      "threadId" => handle.thread_id,
      "expectedTurnId" => expected_turn_id,
      "input" => normalize_input(input)
    }

    case request_with_backoff(handle, "turn/steer", params, deadline(%{}, handle.config)) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp client(config, spec, client_module) do
    case value(config, :client) do
      pid when is_pid(pid) ->
        {:ok, pid, false}

      nil ->
        opts =
          config
          |> value(:client_opts, [])
          |> Keyword.put(:session_id, value(spec, :id))
          |> Keyword.put_new(:policy_profile, value(config, :policy_profile, :restricted))
          |> Keyword.put_new(:schema_path, value(config, :schema_path, Schema.bundle_path()))

        case client_module.start_link(opts) do
          {:ok, pid} -> {:ok, pid, true}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp maybe_start_initial_turn(prepared, thread_id, spec, config) do
    case value(config, :objective, value(spec, :objective)) do
      nil ->
        {:ok, nil}

      objective ->
        with {:ok, result} <-
               request_with_backoff(
                 prepared,
                 "turn/start",
                 turn_params(thread_id, objective, config),
                 deadline(spec, config)
               ),
             {:ok, turn_id} <- exact_id(result, ["turn", "id"], :turn) do
          {:ok, turn_id}
        end
    end
  end

  defp thread_params(config) do
    %{
      "cwd" => value(config, :cwd, "/workspace"),
      "sandbox" => value(config, :sandbox, "workspace-write"),
      "approvalPolicy" => value(config, :approval_policy, "on-request"),
      "approvalsReviewer" => value(config, :approvals_reviewer, "user"),
      "ephemeral" => value(config, :ephemeral, false)
    }
    |> maybe_put("model", value(config, :model))
    |> maybe_put("modelProvider", value(config, :model_provider))
  end

  defp turn_params(thread_id, input, config) do
    cwd = value(config, :cwd, "/workspace")

    %{
      "threadId" => thread_id,
      "input" => normalize_input(input),
      "cwd" => cwd,
      "approvalPolicy" => value(config, :approval_policy, "on-request"),
      "approvalsReviewer" => value(config, :approvals_reviewer, "user"),
      "sandboxPolicy" => sandbox_policy(config, cwd)
    }
    |> maybe_put("model", value(config, :model))
  end

  defp sandbox_policy(config, _cwd) when is_map(config) do
    case value(config, :sandbox_authority) do
      :outer ->
        %{
          "type" => "externalSandbox",
          "networkAccess" => value(config, :external_network_access, "restricted")
        }

      "outer" ->
        %{
          "type" => "externalSandbox",
          "networkAccess" => value(config, :external_network_access, "restricted")
        }

      _other ->
        cwd = value(config, :cwd, "/workspace")

        value(config, :sandbox_policy, %{
          "type" => "workspaceWrite",
          "networkAccess" => false,
          "writableRoots" => [cwd]
        })
    end
  end

  defp normalize_input(input) when is_binary(input), do: [%{"type" => "text", "text" => input}]
  defp normalize_input(input) when is_list(input), do: input

  defp request_with_backoff(holder, method, params, deadline) do
    client_module = holder.client_module
    do_request(client_module, holder.client, method, params, deadline, 0)
  end

  defp do_request(client_module, client, method, params, deadline, attempt) do
    case client_module.request(client, method, params) do
      {:error, :codex_protocol_overloaded} when attempt < 5 ->
        now = Twelvgaige.Clock.utc_now()
        delay = min(trunc(:math.pow(2, attempt) * 25) + :rand.uniform(20), 1_000)

        if DateTime.compare(DateTime.add(now, delay, :millisecond), deadline) == :lt do
          Process.sleep(delay)
          do_request(client_module, client, method, params, deadline, attempt + 1)
        else
          {:error, :codex_overload_deadline_exceeded}
        end

      result ->
        result
    end
  end

  defp exact_id(result, path, kind) do
    case get_in(result, path) do
      id when is_binary(id) and id != "" -> {:ok, id}
      _other -> {:error, {:codex_missing_exact_identity, kind}}
    end
  end

  defp auth_profile(config) do
    case value(config, :auth_profile) do
      %AuthProfile{} = profile -> profile
      attrs when is_map(attrs) -> AuthProfile.new(attrs)
      nil -> AuthProfile.new(%{id: "missing", type: :brokered_service, revision: 0})
    end
  end

  defp auth_identity_matches?(profile, lease) do
    if value(lease, :profile) in [nil, profile.id],
      do: :ok,
      else: {:error, :codex_auth_profile_mismatch}
  end

  defp adapter_config(spec) do
    capabilities = value(spec, :capabilities, %{})
    value(capabilities, :codex, value(spec, :adapter_config, %{}))
  end

  defp verify_version(config) do
    version = value(config, :runtime_version, Schema.cli_version())

    if version == Schema.cli_version(),
      do: :ok,
      else: {:error, {:codex_cli_version_unsupported, version}}
  end

  defp initialize_opts(config) do
    [
      client_name: "twelvgaige",
      client_title: "Twelvgaige",
      client_version: value(config, :client_version, "0.0.3")
    ]
  end

  defp deadline(spec, config) do
    value(
      spec,
      :deadline,
      value(config, :deadline, DateTime.add(Twelvgaige.Clock.utc_now(), 300, :second))
    )
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
  defp present?(value), do: not is_nil(value) and value != ""

  defp value(attrs, key, default \\ nil)
  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default) when is_map(attrs) do
    case Map.fetch(attrs, key) do
      {:ok, value} -> value
      :error -> Map.get(attrs, Atom.to_string(key), default)
    end
  end

  defp value(_attrs, _key, default), do: default
end
