defmodule Twelvgaige.Operations.SessionControl do
  @moduledoc """
  Durable local-user session inventory, attach, takeover, revocation, and reconciliation.

  Attach leases are signed, read-only views. A takeover increments the durable
  control epoch, invalidating every earlier lease. No bearer secret is persisted.
  """

  use GenServer

  alias Twelvgaige.Operations.{LocalIdentity, Store}

  @active_statuses [
    :preparing,
    :authenticating,
    :creating_sandbox,
    :starting,
    :running,
    :cancelling,
    :awaiting_reconciliation,
    :finalizing
  ]
  @far_future ~U[9999-12-31 23:59:59Z]

  defstruct [
    :store,
    :owner_uid,
    :signing_key,
    :cancel_fun,
    :credential_revoke_fun,
    :egress_revoke_fun,
    :backends,
    :backend_opts,
    :workspace_root,
    :artifact_store,
    :credential_broker,
    :egress_broker,
    :now_fun,
    attach_ttl_seconds: 900
  ]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, opts),
      else: GenServer.start_link(__MODULE__, opts, name: name)
  end

  def register(session, opts \\ []), do: call(opts, {:register, session, opts})
  def update(session_id, attrs, opts \\ []), do: call(opts, {:update, session_id, attrs, opts})
  def list(opts \\ []), do: call(opts, {:list, opts})
  def get(session_id, opts \\ []), do: call(opts, {:get, session_id, opts})
  def attach(session_id, opts \\ []), do: call(opts, {:attach, session_id, opts})

  def takeover(session_id, expected_epoch, opts \\ []),
    do: call(opts, {:takeover, session_id, expected_epoch, opts})

  def authorize(lease, session_id, capability, opts \\ []),
    do: call(opts, {:authorize, lease, session_id, capability, opts})

  def revoke(session_id, opts \\ []), do: call(opts, {:revoke, session_id, opts})
  def reserve_retry(session_id, opts \\ []), do: call(opts, {:reserve_retry, session_id, opts})
  def release_retry(session_id, opts \\ []), do: call(opts, {:release_retry, session_id, opts})
  def backend_health(opts \\ []), do: call(opts, {:backend_health, opts}, 60_000)
  def reconcile(opts \\ []), do: call(opts, {:reconcile, opts}, 120_000)
  def store(server \\ __MODULE__), do: GenServer.call(server, :store)
  def artifact_store(server \\ __MODULE__), do: GenServer.call(server, :artifact_store)
  def workspace_root(server \\ __MODULE__), do: GenServer.call(server, :workspace_root)

  def append_event(session_id, event, opts \\ []),
    do: call(opts, {:append_event, session_id, event, opts})

  def list_events(session_id, opts \\ []),
    do: call(opts, {:list_events, session_id, opts})

  @impl true
  def init(opts) do
    with {:ok, identity} <-
           LocalIdentity.current(
             uid: Keyword.get(opts, :owner_uid),
             username: Keyword.get(opts, :username)
           ) do
      credential_broker = Keyword.get(opts, :credential_broker)
      egress_broker = Keyword.get(opts, :egress_broker)

      {:ok,
       %__MODULE__{
         store: Keyword.get(opts, :store, Store),
         owner_uid: identity.uid,
         signing_key: Keyword.get(opts, :signing_key) || :crypto.strong_rand_bytes(32),
         cancel_fun: Keyword.get(opts, :cancel_fun, fn _session -> :ok end),
         credential_revoke_fun:
           Keyword.get_lazy(opts, :credential_revoke_fun, fn ->
             fn
               nil ->
                 :already_revoked

               lease_id when is_nil(credential_broker) ->
                 Twelvgaige.Credential.Broker.revoke(lease_id)

               lease_id ->
                 Twelvgaige.Credential.Broker.revoke(lease_id, server: credential_broker)
             end
           end),
         egress_revoke_fun:
           Keyword.get_lazy(opts, :egress_revoke_fun, fn ->
             fn
               nil ->
                 :already_revoked

               lease_id when is_nil(egress_broker) ->
                 Twelvgaige.Egress.Broker.revoke(lease_id)

               lease_id ->
                 Twelvgaige.Egress.Broker.revoke(lease_id, server: egress_broker)
             end
           end),
         backends: Keyword.get(opts, :backends, %{}),
         backend_opts: Keyword.get(opts, :backend_opts, %{}),
         workspace_root: opts |> Keyword.get(:workspace_root) |> expand_optional(),
         artifact_store: Keyword.get(opts, :artifact_store),
         credential_broker: credential_broker,
         egress_broker: egress_broker,
         now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
         attach_ttl_seconds: Keyword.get(opts, :attach_ttl_seconds, 900)
       }}
    end
  end

  @impl true
  def handle_call({:register, session, opts}, _from, state) do
    now = Keyword.get(opts, :now, state.now_fun.())
    record = normalize_session(session, state.owner_uid, now)

    reply =
      with :ok <- authorize_local_user(state, opts) do
        store_opts =
          [
            server: state.store,
            retention_class: :raw,
            hold_until: retention_hold(record),
            now: now
          ]
          |> maybe_put(:retention_days, Keyword.get(opts, :retention_days))

        Store.put_new(:session, record.id, record, store_opts)
      end

    reply =
      if reply == :ok do
        case apply_artifact_retention(record, state) do
          :ok ->
            audit(state, :session_registered, record.id, %{status: record.status})
            {:ok, record}

          {:error, reason} ->
            _ = Store.delete(:session, record.id, server: state.store)
            {:error, {:session_artifact_retention_failed, reason}}
        end
      else
        normalize_conflict(reply)
      end

    {:reply, reply, state}
  end

  def handle_call(:store, _from, state), do: {:reply, state.store, state}
  def handle_call(:artifact_store, _from, state), do: {:reply, state.artifact_store, state}
  def handle_call(:workspace_root, _from, state), do: {:reply, state.workspace_root, state}

  def handle_call({:update, session_id, attrs, opts}, _from, state) do
    reply =
      with :ok <- authorize_local_user(state, opts),
           {:ok, stored} <- Store.get(:session, session_id, server: state.store),
           record <-
             stored.value
             |> Map.merge(if(is_struct(attrs), do: Map.from_struct(attrs), else: Map.new(attrs)))
             |> Map.put(:updated_at, Keyword.get(opts, :now, state.now_fun.())),
           store_opts <-
             [
               server: state.store,
               retention_class: :raw,
               hold_until: retention_hold(record),
               now: record.updated_at
             ]
             |> maybe_put(:retention_days, Keyword.get(opts, :retention_days)),
           :ok <- Store.put(:session, session_id, record, store_opts),
           :ok <- apply_session_retention(record, state) do
        {:ok, record}
      end

    {:reply, reply, state}
  end

  def handle_call({:list, opts}, _from, state) do
    reply =
      with :ok <- authorize_local_user(state, opts),
           {:ok, records} <- Store.list(:session, server: state.store) do
        sessions =
          records
          |> Enum.map(& &1.value)
          |> filter_status(Keyword.get(opts, :status))
          |> Enum.sort_by(&{&1.created_at, &1.id}, {:desc, DateTime})
          |> Enum.map(&public_session/1)

        {:ok, sessions}
      end

    {:reply, reply, state}
  end

  def handle_call({:get, session_id, opts}, _from, state) do
    reply = with :ok <- authorize_local_user(state, opts), do: fetch_session(state, session_id)
    {:reply, reply, state}
  end

  def handle_call({:append_event, session_id, event, opts}, _from, state) do
    now = Keyword.get(opts, :now, state.now_fun.())

    reply =
      with :ok <- authorize_local_user(state, opts),
           {:ok, session} <- fetch_session(state, session_id),
           event <- normalize_event(event, session_id, now),
           result <-
             Store.put_new(event_namespace(session_id), event.id, event,
               server: state.store,
               retention_class: :raw,
               hold_until: retention_hold(session),
               now: now
             ) do
        case result do
          :ok -> {:ok, event}
          :already_present -> :duplicate
          {:error, reason} -> {:error, reason}
        end
      end

    {:reply, reply, state}
  end

  def handle_call({:list_events, session_id, opts}, _from, state) do
    reply =
      with :ok <- authorize_local_user(state, opts),
           {:ok, _session} <- fetch_session(state, session_id),
           {:ok, records} <- Store.list(event_namespace(session_id), server: state.store) do
        events =
          records
          |> Enum.map(& &1.value)
          |> Enum.sort_by(&{value(&1, :occurred_at), value(&1, :seq, 0)})
          |> Enum.filter(&(value(&1, :seq, 0) > Keyword.get(opts, :after_seq, -1)))
          |> Enum.take(Keyword.get(opts, :limit, 500))

        {:ok, events}
      end

    {:reply, reply, state}
  end

  def handle_call({:attach, session_id, opts}, _from, state) do
    reply =
      with :ok <- authorize_local_user(state, opts),
           {:ok, session} <- fetch_session(state, session_id),
           :ok <- ensure_not_revoked(session) do
        lease = issue_lease(session, :observe, state, opts)

        audit(state, :session_attached, session_id, %{
          mode: :observe,
          epoch: session.control_epoch
        })

        {:ok, lease, public_session(session)}
      end

    {:reply, reply, state}
  end

  def handle_call({:takeover, session_id, expected_epoch, opts}, _from, state) do
    reply =
      with :ok <- authorize_local_user(state, opts),
           {:ok, session} <- fetch_session(state, session_id),
           :ok <- ensure_not_revoked(session),
           :ok <- exact_epoch(session, expected_epoch),
           :ok <- normalize_cancel(state.cancel_fun.(session)),
           next <-
             session
             |> Map.put(:control_epoch, session.control_epoch + 1)
             |> Map.put(:controller_pid, nil)
             |> Map.put(:updated_at, state.now_fun.()),
           :ok <-
             Store.put(:session, session_id, next,
               server: state.store,
               retention_class: :raw,
               hold_until: retention_hold(next),
               now: next.updated_at
             ) do
        lease = issue_lease(next, :control, state, opts)
        audit(state, :session_taken_over, session_id, %{epoch: next.control_epoch})
        {:ok, lease, public_session(next)}
      end

    {:reply, reply, state}
  end

  def handle_call({:authorize, lease, session_id, capability, opts}, _from, state) do
    reply =
      with :ok <- authorize_local_user(state, opts),
           {:ok, payload} <- verify_lease(lease, state),
           true <- payload["session_id"] == session_id,
           true <- payload["uid"] == state.owner_uid,
           {:ok, session} <- fetch_session(state, session_id),
           true <- lease_capability?(payload, capability, session),
           true <- session.control_epoch == payload["epoch"],
           :ok <- ensure_not_revoked(session) do
        :ok
      else
        false -> {:error, :session_control_denied}
        {:error, _reason} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:revoke, session_id, opts}, _from, state) do
    reply =
      with :ok <- authorize_local_user(state, opts),
           {:ok, session} <- fetch_session(state, session_id),
           cancel_result <- normalize_cancel(state.cancel_fun.(session)),
           credential_result <- state.credential_revoke_fun.(session.credential_lease_id),
           :ok <- normalize_revoke(credential_result),
           egress_result <- state.egress_revoke_fun.(session.egress_lease_id),
           :ok <- normalize_revoke(egress_result),
           revoked <-
             session
             |> Map.put(:status, :revoked)
             |> Map.put(:control_epoch, session.control_epoch + 1)
             |> Map.put(:credential_lease_id, nil)
             |> Map.put(:egress_lease_id, nil)
             |> Map.put(:revoked_at, state.now_fun.())
             |> Map.put(:updated_at, state.now_fun.()),
           :ok <-
             Store.put(:session, session_id, revoked,
               server: state.store,
               retention_class: :raw,
               now: revoked.updated_at
             ),
           :ok <- apply_session_retention(revoked, state) do
        audit(state, :session_revoked, session_id, %{cancel_result: inspect(cancel_result)})
        {:ok, public_session(revoked)}
      end

    {:reply, reply, state}
  end

  def handle_call({:reserve_retry, session_id, opts}, _from, state) do
    repair? = Keyword.get(opts, :repair?, false)
    max_retries = Keyword.get(opts, :max_retries, 3)

    reply =
      with :ok <- authorize_local_user(state, opts),
           {:ok, session} <- fetch_session(state, session_id),
           :ok <- retryable(session, repair?, max_retries),
           updated <-
             session
             |> Map.update(:retry_count, 1, &(&1 + 1))
             |> Map.update(:repair_attempts, if(repair?, do: 1, else: 0), fn count ->
               if repair?, do: count + 1, else: count
             end)
             |> Map.put(:updated_at, Keyword.get(opts, :now, state.now_fun.())),
           :ok <-
             Store.put(:session, session_id, updated,
               server: state.store,
               retention_class: :raw,
               now: updated.updated_at
             ) do
        {:ok, updated}
      end

    {:reply, reply, state}
  end

  def handle_call({:release_retry, session_id, opts}, _from, state) do
    repair? = Keyword.get(opts, :repair?, false)

    reply =
      with :ok <- authorize_local_user(state, opts),
           {:ok, session} <- fetch_session(state, session_id),
           updated <-
             session
             |> Map.update(:retry_count, 0, &max(&1 - 1, 0))
             |> Map.update(:repair_attempts, 0, fn count ->
               if repair?, do: max(count - 1, 0), else: count
             end)
             |> Map.put(:updated_at, Keyword.get(opts, :now, state.now_fun.())),
           :ok <-
             Store.put(:session, session_id, updated,
               server: state.store,
               retention_class: :raw,
               now: updated.updated_at
             ) do
        {:ok, updated}
      end

    {:reply, reply, state}
  end

  def handle_call({:backend_health, opts}, _from, state) do
    reply =
      with :ok <- authorize_local_user(state, opts) do
        health =
          Map.new(state.backends, fn {name, backend} ->
            backend_opts = backend_options(state, name, opts)

            value =
              case backend.probe(backend_opts) do
                {:ok, details} -> %{status: :healthy, details: details}
                {:error, reason} -> %{status: :unhealthy, reason: inspect(reason)}
              end

            {name, value}
          end)

        {:ok, health}
      end

    {:reply, reply, state}
  end

  def handle_call({:reconcile, opts}, _from, state) do
    reply = reconcile_all(state, opts)
    {:reply, reply, state}
  end

  defp reconcile_all(state, opts) do
    with :ok <- authorize_local_user(state, opts),
         {:ok, stored} <- Store.list(:session, server: state.store) do
      sessions = Enum.map(stored, & &1.value)
      known_resources = MapSet.new(Enum.flat_map(sessions, &resource_identity/1))
      known_workspaces = MapSet.new(Enum.flat_map(sessions, &workspace_identity/1))

      {backend_reports, observed_resources} = backend_inventory(state, known_resources, opts)

      {workspace_orphans, workspace_inventory} =
        workspace_orphans(state.workspace_root, known_workspaces)

      workspace_actions =
        reconcile_workspace_orphans(
          state.workspace_root,
          workspace_orphans,
          Keyword.get(opts, :apply?, false)
        )

      missing = missing_resources(sessions, observed_resources)
      credential_leases = credential_inventory(state, sessions, opts)
      egress_leases = egress_inventory(state, sessions, opts)

      lease_affected =
        lease_affected_sessions(sessions, credential_leases, egress_leases)

      reconciliation_required = Enum.uniq_by(missing ++ lease_affected, & &1.id)

      Enum.each(reconciliation_required, fn session ->
        _ =
          Store.put(:session, session.id, %{session | status: :awaiting_reconciliation},
            server: state.store,
            retention_class: :raw,
            hold_until: @far_future
          )
      end)

      report = %{
        backends: backend_reports,
        orphan_resources:
          observed_resources
          |> MapSet.difference(known_resources)
          |> MapSet.to_list()
          |> Enum.sort(),
        orphan_workspaces: workspace_orphans,
        workspace_inventory: workspace_inventory,
        workspace_actions: workspace_actions,
        missing_session_resources: Enum.map(missing, & &1.id),
        orphaned_session_leases: Enum.map(lease_affected, & &1.id),
        sessions_awaiting_reconciliation: Enum.map(reconciliation_required, & &1.id),
        credential_leases: credential_leases,
        egress_leases: egress_leases,
        mode: if(Keyword.get(opts, :apply?, false), do: :apply, else: :dry_run)
      }

      audit(state, :reconciliation_completed, nil, Map.drop(report, [:backends]))
      {:ok, report}
    end
  end

  defp backend_inventory(state, known_resources, opts) do
    Enum.reduce(state.backends, {%{}, MapSet.new()}, fn {name, backend}, {reports, all} ->
      backend_opts = backend_options(state, name, opts)

      case managed_resources(backend, backend_opts) do
        {:ok, resources} ->
          ids = resources |> Enum.map(&resource_id/1) |> Enum.reject(&is_nil/1) |> MapSet.new()
          unknown = MapSet.difference(ids, known_resources)

          actions =
            if Keyword.get(opts, :apply?, false) and Keyword.get(opts, :destroy_orphans?, false) do
              Map.new(unknown, fn id ->
                {id, normalize_action_result(destroy_orphan(backend, id, backend_opts))}
              end)
            else
              Map.new(unknown, &{&1, :quarantine})
            end

          report = %{status: :healthy, resources: MapSet.size(ids), orphan_actions: actions}
          {Map.put(reports, name, report), MapSet.union(all, ids)}

        {:error, reason} ->
          {Map.put(reports, name, %{status: :unhealthy, reason: inspect(reason)}), all}
      end
    end)
  end

  defp managed_resources(backend, opts) do
    if function_exported?(backend, :managed_resources, 1),
      do: backend.managed_resources(opts),
      else: {:error, :backend_inventory_unsupported}
  end

  defp destroy_orphan(backend, id, opts) do
    _ = backend.stop(id, opts)
    backend.destroy(id, opts)
  end

  defp missing_resources(sessions, observed) do
    Enum.filter(sessions, fn session ->
      session.status in @active_statuses and is_binary(session.sandbox_resource_id) and
        not MapSet.member?(observed, session.sandbox_resource_id)
    end)
  end

  defp lease_affected_sessions(sessions, credential_report, egress_report) do
    credential_orphans = MapSet.new(Map.get(credential_report, :orphaned, []))
    egress_orphans = MapSet.new(Map.get(egress_report, :orphaned, []))

    Enum.filter(sessions, fn session ->
      session.status in @active_statuses and
        (MapSet.member?(credential_orphans, session.credential_lease_id) or
           MapSet.member?(egress_orphans, session.egress_lease_id))
    end)
  end

  defp credential_inventory(state, sessions, opts) do
    case Keyword.get(opts, :credential_broker, state.credential_broker) do
      nil ->
        %{status: :not_configured}

      broker ->
        with {:ok, leases} <- Twelvgaige.Credential.Broker.inventory(server: broker) do
          known =
            sessions
            |> Enum.map(& &1.credential_lease_id)
            |> Enum.reject(&is_nil/1)
            |> MapSet.new()

          live = Enum.filter(leases, &(&1.status == :active))
          orphaned = Enum.filter(leases, &(&1.status == :orphaned))

          unbound =
            live
            |> Enum.reject(&MapSet.member?(known, &1.id))
            |> Enum.map(& &1.id)
            |> Enum.sort()

          unbound_actions =
            if Keyword.get(opts, :apply?, false) do
              Map.new(unbound, fn id ->
                {id,
                 normalize_action_result(Twelvgaige.Credential.Broker.revoke(id, server: broker))}
              end)
            else
              Map.new(unbound, &{&1, :quarantine})
            end

          credential_reconciliation =
            Twelvgaige.Credential.Broker.reconcile(
              server: broker,
              apply?: Keyword.get(opts, :apply?, false)
            )

          %{
            status: :available,
            active: Enum.map(live, & &1.id),
            orphaned: Enum.map(orphaned, & &1.id),
            unbound: unbound,
            unbound_actions: unbound_actions,
            reconciliation: normalize_action_result(credential_reconciliation)
          }
        else
          {:error, reason} -> %{status: :unavailable, reason: inspect(reason)}
        end
    end
  end

  defp egress_inventory(state, sessions, opts) do
    case Keyword.get(opts, :egress_broker, state.egress_broker) do
      nil ->
        %{status: :not_configured}

      broker ->
        with {:ok, leases} <- Twelvgaige.Egress.Broker.inventory(server: broker) do
          known =
            sessions
            |> Enum.map(& &1.egress_lease_id)
            |> Enum.reject(&is_nil/1)
            |> MapSet.new()

          live = Enum.filter(leases, &(&1.status == :active))
          orphaned = Enum.filter(leases, &(&1.status == :orphaned))

          unbound =
            live
            |> Enum.reject(&MapSet.member?(known, &1.id))
            |> Enum.map(& &1.id)
            |> Enum.sort()

          unbound_actions =
            if Keyword.get(opts, :apply?, false) do
              Map.new(unbound, fn id ->
                {id, normalize_action_result(Twelvgaige.Egress.Broker.revoke(id, server: broker))}
              end)
            else
              Map.new(unbound, &{&1, :quarantine})
            end

          reconciliation =
            Twelvgaige.Egress.Broker.reconcile(
              server: broker,
              apply?: Keyword.get(opts, :apply?, false)
            )

          %{
            status: :available,
            active: Enum.map(live, & &1.id),
            orphaned: Enum.map(orphaned, & &1.id),
            unbound: unbound,
            unbound_actions: unbound_actions,
            reconciliation: normalize_action_result(reconciliation)
          }
        else
          {:error, reason} -> %{status: :unavailable, reason: inspect(reason)}
        end
    end
  end

  defp workspace_orphans(nil, _known), do: {[], %{status: :not_configured}}

  defp workspace_orphans(root, known) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.reject(&(&1 == ".quarantine"))
        |> Enum.reject(&MapSet.member?(known, &1))
        |> Enum.sort()
        |> then(&{&1, %{status: :healthy}})

      {:error, :enoent} ->
        {[], %{status: :healthy}}

      {:error, reason} ->
        {[], %{status: :unavailable, reason: inspect(reason)}}
    end
  end

  defp reconcile_workspace_orphans(_root, [], _apply?), do: %{}
  defp reconcile_workspace_orphans(nil, _orphans, _apply?), do: %{}

  defp reconcile_workspace_orphans(_root, orphans, false),
    do: Map.new(orphans, &{&1, :quarantine})

  defp reconcile_workspace_orphans(root, orphans, true) do
    Enum.reduce(orphans, %{}, fn
      name, actions when is_binary(name) ->
        Map.put(actions, name, quarantine_workspace(root, name))

      error, actions ->
        Map.put(actions, inspect(error), %{status: :error, reason: :workspace_inventory_failed})
    end)
  end

  defp quarantine_workspace(root, name) do
    quarantine_root = Path.join(root, ".quarantine")
    source = Path.join(root, name)

    suffix =
      [
        System.system_time(:millisecond),
        Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
      ]
      |> Enum.join("-")

    destination = Path.join(quarantine_root, name <> "-" <> suffix)

    with :ok <- File.mkdir_p(quarantine_root),
         :ok <- File.chmod(quarantine_root, 0o700),
         :ok <- File.rename(source, destination) do
      %{status: :ok, action: :quarantined, path: destination}
    else
      {:error, reason} -> %{status: :error, reason: inspect(reason)}
    end
  end

  defp normalize_action_result({:ok, result}) when is_map(result),
    do: Map.put(result, :status, :ok)

  defp normalize_action_result({:ok, result}), do: %{status: :ok, result: inspect(result)}
  defp normalize_action_result({:error, reason}), do: %{status: :error, reason: inspect(reason)}
  defp normalize_action_result(:ok), do: :ok
  defp normalize_action_result(:already_revoked), do: :already_revoked
  defp normalize_action_result(result), do: %{status: :unknown, result: inspect(result)}

  defp issue_lease(session, mode, state, opts) do
    now = Keyword.get(opts, :now, state.now_fun.())

    payload = %{
      "session_id" => session.id,
      "uid" => state.owner_uid,
      "epoch" => session.control_epoch,
      "mode" => Atom.to_string(mode),
      "capabilities" => Enum.map(session.capabilities || [], &to_string/1),
      "workspace_id" => session.workspace_id,
      "sandbox_resource_id" => session.sandbox_resource_id,
      "expires_at" => DateTime.to_unix(DateTime.add(now, state.attach_ttl_seconds, :second))
    }

    encoded = payload |> Jason.encode!() |> Base.url_encode64(padding: false)
    signature = mac(state.signing_key, encoded)
    encoded <> "." <> signature
  end

  defp verify_lease(lease, state) when is_binary(lease) do
    with [encoded, signature] <- String.split(lease, ".", parts: 2),
         true <- Twelvgaige.Security.secure_equal?(mac(state.signing_key, encoded), signature),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, payload} <- Jason.decode(json),
         true <- payload["expires_at"] > DateTime.to_unix(state.now_fun.()) do
      {:ok, payload}
    else
      _other -> {:error, :session_control_denied}
    end
  end

  defp verify_lease(_lease, _state), do: {:error, :session_control_denied}

  defp normalize_session(session, owner_uid, now) do
    session = if is_struct(session), do: Map.from_struct(session), else: Map.new(session)

    %{
      id: required(session, :id),
      plan_id: value(session, :plan_id),
      child_id: value(session, :child_id),
      owner_uid: owner_uid,
      status: value(session, :status, :preparing),
      runtime: value(session, :runtime),
      driver: value(session, :driver),
      workspace_id: value(session, :workspace_id),
      workspace_path: value(session, :workspace_path),
      repository: value(session, :repository),
      base_commit: value(session, :base_commit),
      head_commit: value(session, :head_commit),
      sandbox_backend: value(session, :sandbox_backend),
      sandbox_profile: value(session, :sandbox_profile),
      sandbox_resource_id: value(session, :sandbox_resource_id),
      sandbox_manifest: value(session, :sandbox_manifest),
      sandbox_manifest_digest: value(session, :sandbox_manifest_digest),
      credential_lease_id: value(session, :credential_lease_id),
      egress_lease_id: value(session, :egress_lease_id),
      auth_profile_id: value(session, :auth_profile_id),
      capabilities: value(session, :effective_capabilities, value(session, :capabilities, [])),
      budgets: value(session, :budgets, %{}),
      usage: value(session, :last_usage, value(session, :usage, %{})),
      nested_agents: value(session, :nested_agents, []),
      start_request: value(session, :start_request),
      retry_of_session_id: value(session, :retry_of_session_id),
      retry_mode: value(session, :retry_mode),
      retry_count: value(session, :retry_count, 0),
      repair_attempts: value(session, :repair_attempts, 0),
      error: value(session, :error),
      exit_reason: value(session, :exit_reason),
      result: value(session, :result),
      artifact_refs: value(session, :artifact_refs, []),
      deadline: value(session, :deadline),
      controller_pid: value(session, :controller_pid),
      control_epoch: value(session, :control_epoch, 1),
      created_at: value(session, :created_at, now),
      updated_at: now,
      revoked_at: nil
    }
  end

  defp public_session(session),
    do: Map.drop(session, [:controller_pid, :credential_lease_id, :egress_lease_id])

  defp apply_session_retention(session, state) do
    with :ok <- apply_artifact_retention(session, state),
         :ok <- apply_event_retention(session, state) do
      :ok
    end
  end

  defp apply_artifact_retention(_session, %{artifact_store: nil}), do: :ok

  defp apply_artifact_retention(session, state) do
    Enum.reduce_while(session.artifact_refs || [], :ok, fn ref, :ok ->
      id = artifact_id(ref)

      result =
        if session.status in @active_statuses,
          do: Twelvgaige.Artifact.Store.hold(id, :indefinite, server: state.artifact_store),
          else: Twelvgaige.Artifact.Store.release_hold(id, server: state.artifact_store)

      case result do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp apply_event_retention(session, state) do
    case Store.list(event_namespace(session.id), server: state.store) do
      {:ok, records} ->
        Enum.reduce_while(records, :ok, fn record, :ok ->
          case Store.put(event_namespace(session.id), record.key, record.value,
                 server: state.store,
                 retention_class: :raw,
                 hold_until: retention_hold(session),
                 now: session.updated_at || state.now_fun.()
               ) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp normalize_event(event, session_id, now) do
    event = if is_struct(event), do: Map.from_struct(event), else: Map.new(event)

    %{
      id: value(event, :id) || stable_event_id(session_id, event),
      session_id: session_id,
      type: value(event, :type, value(event, :event_type, :message)),
      payload: value(event, :payload, %{}),
      seq: value(event, :seq, 0),
      native_session_id: value(event, :native_session_id),
      native_turn_id: value(event, :native_turn_id),
      native_event_id: value(event, :native_event_id),
      payload_digest: value(event, :payload_digest),
      occurred_at: value(event, :occurred_at, now)
    }
  end

  defp stable_event_id(session_id, event) do
    identity = {
      session_id,
      value(event, :native_session_id),
      value(event, :native_turn_id),
      value(event, :native_event_id),
      value(event, :payload_digest),
      value(event, :type, value(event, :event_type)),
      value(event, :occurred_at)
    }

    digest =
      identity
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    "event_" <> digest
  end

  defp event_namespace(session_id), do: "session_event:" <> session_id

  defp artifact_id(%{id: id}) when is_binary(id), do: id
  defp artifact_id(%{"id" => id}) when is_binary(id), do: id
  defp artifact_id(id) when is_binary(id), do: id

  defp fetch_session(state, session_id) do
    case Store.get(:session, session_id, server: state.store) do
      {:ok, record} -> {:ok, record.value}
      {:error, :not_found} -> {:error, :session_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp retention_hold(%{status: status}) when status in @active_statuses, do: @far_future
  defp retention_hold(_session), do: nil

  defp resource_identity(%{sandbox_resource_id: id}) when is_binary(id), do: [id]
  defp resource_identity(_session), do: []
  defp workspace_identity(%{workspace_id: id}) when is_binary(id), do: [id]
  defp workspace_identity(_session), do: []

  defp resource_id(%{id: id}), do: id
  defp resource_id(%{"id" => id}), do: id
  defp resource_id(%{resource_id: id}), do: id
  defp resource_id(%{"resource_id" => id}), do: id
  defp resource_id(id) when is_binary(id), do: id
  defp resource_id(_resource), do: nil

  defp authorize_local_user(state, opts) do
    LocalIdentity.authorize_uid(state.owner_uid,
      uid: Keyword.get(opts, :uid),
      username: Keyword.get(opts, :username)
    )
  end

  defp backend_options(state, name, opts) do
    state.backend_opts
    |> Map.get(name, [])
    |> Keyword.merge(Keyword.get(opts, :backend_opts, []))
  end

  defp exact_epoch(%{control_epoch: epoch}, epoch), do: :ok
  defp exact_epoch(_session, _expected), do: {:error, :session_control_epoch_conflict}
  defp ensure_not_revoked(%{status: :revoked}), do: {:error, :session_revoked}
  defp ensure_not_revoked(_session), do: :ok

  defp retryable(session, repair?, max) do
    cond do
      session.status == :revoked ->
        {:error, :session_revoked}

      session.status in @active_statuses ->
        {:error, :session_retry_requires_terminal_session}

      repair? and Map.get(session, :repair_attempts, 0) >= 1 ->
        {:error, :session_repair_already_attempted}

      not repair? and Map.get(session, :retry_count, 0) >= max ->
        {:error, :session_retry_limit_reached}

      not is_map(Map.get(session, :start_request)) ->
        {:error, :session_retry_request_unavailable}

      true ->
        :ok
    end
  end

  defp normalize_cancel(value) when value in [:ok, :already_stopped], do: :ok
  defp normalize_cancel({:error, reason}), do: {:error, reason}
  defp normalize_cancel(other), do: {:error, {:session_cancel_invalid, other}}
  defp normalize_revoke(value) when value in [:ok, :already_revoked], do: :ok
  defp normalize_revoke({:error, reason}), do: {:error, reason}
  defp normalize_revoke(other), do: {:error, {:credential_revoke_invalid, other}}

  defp lease_capability?(%{"mode" => "observe"}, capability, _session),
    do: capability in [:read, :attach, "read", "attach"]

  defp lease_capability?(%{"mode" => "control"} = payload, capability, session) do
    capability = to_string(capability)

    capability in ~w(read attach cancel steer interrupt takeover) or
      (capability in (payload["capabilities"] || []) and
         capability in Enum.map(session.capabilities || [], &to_string/1))
  end

  defp lease_capability?(_payload, _capability, _session), do: false

  defp filter_status(sessions, nil), do: sessions
  defp filter_status(sessions, status), do: Enum.filter(sessions, &(&1.status == status))

  defp audit(state, event_type, session_id, details) do
    Store.append_audit(
      %{
        event_type: event_type,
        session_id: session_id,
        actor_uid: state.owner_uid,
        occurred_at: state.now_fun.(),
        details: details
      },
      server: state.store
    )
  end

  defp normalize_conflict(:already_present), do: {:error, :session_exists}
  defp normalize_conflict({:error, _reason} = error), do: error

  defp mac(key, encoded),
    do: :crypto.mac(:hmac, :sha256, key, encoded) |> Base.url_encode64(padding: false)

  defp expand_optional(nil), do: nil
  defp expand_optional(path), do: Path.expand(path)

  defp required(map, key) do
    case value(map, key) do
      nil -> raise ArgumentError, "missing session field #{key}"
      result -> result
    end
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp call(opts, request, timeout \\ 30_000),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), request, timeout)
end
