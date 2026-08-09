defmodule Twelvgaige.Egress.Broker do
  @moduledoc "Durable metadata and fail-closed authorization for broker-only egress leases."

  use GenServer

  alias Twelvgaige.Egress.{Lease, Policy}
  alias Twelvgaige.Operations.Store

  @far_future ~U[9999-12-31 23:59:59Z]

  defstruct [:store, :resolver, leases: %{}, audit: []]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    options = Keyword.delete(opts, :name)

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, options),
      else: GenServer.start_link(__MODULE__, options, name: name)
  end

  def issue(attrs, opts \\ []), do: call(opts, {:issue, attrs, opts})
  def checkout(token, uri, opts \\ []), do: call(opts, {:checkout, token, uri, opts})

  def materialize(lease_id, token, opts \\ []),
    do: call(opts, {:materialize, lease_id, token, opts})

  def release(lease_id, opts \\ []), do: call(opts, {:release, lease_id})
  def revoke(lease_id, opts \\ []), do: call(opts, {:revoke, lease_id, opts})
  def inventory(opts \\ []), do: call(opts, :inventory)
  def audit(opts \\ []), do: call(opts, :audit)
  def reconcile(opts \\ []), do: call(opts, {:reconcile, opts})

  @impl true
  def init(opts) do
    state = %__MODULE__{store: Keyword.get(opts, :store), resolver: Keyword.get(opts, :resolver)}

    case load_durable_leases(state) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, {:egress_lease_store_unavailable, reason}}
    end
  end

  @impl true
  def handle_call({:issue, attrs, opts}, _from, state) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    id = "proxy_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    lease = %Lease{
      id: id,
      session_id: fetch!(attrs, :session_id),
      allowed_hosts: normalize_hosts(fetch!(attrs, :allowed_hosts)),
      allowed_ports: fetch(attrs, :allowed_ports, [443]),
      expires_at: fetch!(attrs, :expires_at),
      access_token: token,
      max_connections: fetch(attrs, :max_connections, 8)
    }

    with :ok <- validate_lease(lease) do
      stored = %{
        lease: %{lease | access_token: nil},
        token_hash: hash(token),
        active_connections: 0,
        total_connections: 0,
        status: :active,
        revoked_at: nil
      }

      next =
        state
        |> put_in([Access.key!(:leases), id], stored)
        |> persist_lease!(id)
        |> audit_event(:egress_lease_issued, id, now, %{session_id: lease.session_id})

      {:reply, {:ok, lease}, next}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:checkout, token, uri, opts}, _from, state) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

    case find_by_token(state.leases, token) do
      {lease_id, stored} ->
        with :ok <- active(stored, now),
             {:ok, port} <- requested_port(uri),
             :ok <- allowed_port(stored.lease, port),
             :ok <- connection_available(stored),
             {:ok, authorization} <- authorize_uri(uri, stored.lease.allowed_hosts, state) do
          updated = %{
            stored
            | active_connections: stored.active_connections + 1,
              total_connections: stored.total_connections + 1
          }

          next =
            state
            |> put_in([Access.key!(:leases), lease_id], updated)
            |> audit_event(:egress_connection_authorized, lease_id, now, %{
              host: authorization.host,
              port: port,
              pinned_address: address_text(authorization.pinned_address)
            })

          {:reply, {:ok, Map.merge(authorization, %{lease_id: lease_id, port: port})}, next}
        else
          {:error, reason} ->
            next = audit_event(state, :egress_connection_denied, lease_id, now, %{reason: reason})
            {:reply, {:error, reason}, next}
        end

      nil ->
        {:reply, {:error, :invalid_egress_lease}, state}
    end
  end

  def handle_call({:materialize, lease_id, token, opts}, _from, state) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

    case Map.fetch(state.leases, lease_id) do
      {:ok, stored} ->
        with :ok <- matching_token(stored, token),
             :ok <- active(stored, now) do
          lease = %{stored.lease | access_token: token}

          next =
            audit_event(state, :egress_boundary_materialized, lease_id, now, %{
              session_id: lease.session_id
            })

          {:reply, {:ok, lease}, next}
        else
          {:error, reason} ->
            next = audit_event(state, :egress_boundary_denied, lease_id, now, %{reason: reason})
            {:reply, {:error, reason}, next}
        end

      :error ->
        {:reply, {:error, :invalid_egress_lease}, state}
    end
  end

  def handle_call({:release, lease_id}, _from, state) do
    case Map.fetch(state.leases, lease_id) do
      {:ok, stored} ->
        updated = %{stored | active_connections: max(0, stored.active_connections - 1)}
        {:reply, :ok, put_in(state.leases[lease_id], updated)}

      :error ->
        {:reply, :already_released, state}
    end
  end

  def handle_call({:revoke, lease_id, opts}, _from, state) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

    case Map.fetch(state.leases, lease_id) do
      {:ok, stored} ->
        updated = %{stored | status: :revoked, revoked_at: now, token_hash: nil}

        next =
          state
          |> put_in([Access.key!(:leases), lease_id], updated)
          |> persist_lease!(lease_id)
          |> audit_event(:egress_lease_revoked, lease_id, now, %{})

        {:reply, :ok, next}

      :error ->
        {:reply, :already_revoked, state}
    end
  end

  def handle_call(:inventory, _from, state) do
    leases =
      state.leases
      |> Enum.map(fn {id, stored} -> public_lease(id, stored) end)
      |> Enum.sort_by(& &1.id)

    {:reply, {:ok, leases}, state}
  end

  def handle_call(:audit, _from, state), do: {:reply, Enum.reverse(state.audit), state}

  def handle_call({:reconcile, opts}, _from, state) do
    orphaned =
      state.leases
      |> Enum.filter(fn {_id, stored} -> stored.status == :orphaned end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if Keyword.get(opts, :apply?, false) do
      now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

      next =
        Enum.reduce(orphaned, state, fn id, acc ->
          stored = Map.fetch!(acc.leases, id)

          acc
          |> put_in([Access.key!(:leases), id], %{stored | status: :revoked, revoked_at: now})
          |> persist_lease!(id)
          |> audit_event(:egress_lease_revoked, id, now, %{reason: :restart_reconciliation})
        end)

      {:reply, {:ok, %{mode: :apply, orphaned: orphaned, revoked: orphaned}}, next}
    else
      {:reply, {:ok, %{mode: :dry_run, orphaned: orphaned, revoked: []}}, state}
    end
  end

  defp call(opts, message), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), message)

  defp active(stored, now) do
    cond do
      stored.status == :orphaned -> {:error, :egress_lease_orphaned}
      stored.status == :revoked -> {:error, :egress_lease_revoked}
      DateTime.compare(now, stored.lease.expires_at) != :lt -> {:error, :egress_lease_expired}
      true -> :ok
    end
  end

  defp requested_port(uri) do
    uri = if is_binary(uri), do: URI.parse(uri), else: uri

    case uri.port || default_port(uri.scheme) do
      port when is_integer(port) and port in 1..65_535 -> {:ok, port}
      _other -> {:error, :egress_port_invalid}
    end
  end

  defp default_port("https"), do: 443
  defp default_port("http"), do: 80
  defp default_port(_scheme), do: nil

  defp allowed_port(lease, port),
    do: if(port in lease.allowed_ports, do: :ok, else: {:error, :egress_port_denied})

  defp connection_available(stored) do
    if stored.active_connections < stored.lease.max_connections,
      do: :ok,
      else: {:error, :egress_connection_limit}
  end

  defp authorize_uri(uri, allowed_hosts, %{resolver: nil}),
    do: Policy.authorize_uri(uri, allowed_hosts)

  defp authorize_uri(uri, allowed_hosts, %{resolver: resolver}),
    do: Policy.authorize_uri(uri, allowed_hosts, resolver: resolver)

  defp validate_lease(lease) do
    cond do
      not is_binary(lease.session_id) or lease.session_id == "" ->
        {:error, :egress_session_required}

      lease.allowed_hosts == [] ->
        {:error, :egress_hosts_required}

      not Enum.all?(lease.allowed_hosts, &valid_host_pattern?/1) ->
        {:error, :egress_host_pattern_invalid}

      not is_list(lease.allowed_ports) or lease.allowed_ports == [] ->
        {:error, :egress_ports_required}

      not Enum.all?(lease.allowed_ports, &(&1 in 1..65_535)) ->
        {:error, :egress_port_invalid}

      not is_integer(lease.max_connections) or lease.max_connections < 1 ->
        {:error, :egress_connection_limit_invalid}

      not match?(%DateTime{}, lease.expires_at) ->
        {:error, :egress_expiry_required}

      true ->
        :ok
    end
  end

  defp valid_host_pattern?("*." <> suffix), do: valid_hostname?(suffix)
  defp valid_host_pattern?(host), do: valid_hostname?(host)

  defp valid_hostname?(host) do
    is_binary(host) and byte_size(host) in 1..253 and
      Regex.match?(
        ~r/^(?=.{1,253}\z)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i,
        host
      )
  end

  defp normalize_hosts(hosts),
    do:
      hosts
      |> Enum.map(&(&1 |> String.downcase() |> String.trim_trailing(".")))
      |> Enum.uniq()
      |> Enum.sort()

  defp find_by_token(leases, token) when is_binary(token) do
    token_hash = hash(token)

    Enum.find(leases, fn {_id, stored} ->
      is_binary(stored.token_hash) and
        Twelvgaige.Security.secure_equal?(stored.token_hash, token_hash)
    end)
  end

  defp find_by_token(_leases, _token), do: nil

  defp matching_token(stored, token) when is_binary(token) do
    if is_binary(stored.token_hash) and
         Twelvgaige.Security.secure_equal?(stored.token_hash, hash(token)),
       do: :ok,
       else: {:error, :invalid_egress_lease}
  end

  defp matching_token(_stored, _token), do: {:error, :invalid_egress_lease}
  defp hash(token), do: :crypto.hash(:sha256, token)

  defp persist_lease!(%{store: nil} = state, _id), do: state

  defp persist_lease!(state, id) do
    :ok =
      Store.put(:egress_lease, id, public_lease(id, Map.fetch!(state.leases, id)),
        server: state.store,
        retention_class: :security,
        hold_until: lease_hold(Map.fetch!(state.leases, id).status)
      )

    state
  end

  defp load_durable_leases(%{store: nil} = state), do: {:ok, state}

  defp load_durable_leases(state) do
    case Store.list(:egress_lease, server: state.store) do
      {:ok, records} ->
        leases =
          Map.new(records, fn record ->
            value = record.value
            status = if value.status == :active, do: :orphaned, else: value.status

            stored = %{
              lease: value.lease,
              token_hash: nil,
              active_connections: 0,
              total_connections: value.total_connections,
              status: status,
              revoked_at: value.revoked_at
            }

            {record.key, stored}
          end)

        loaded = %{state | leases: leases}
        {:ok, Enum.reduce(Map.keys(leases), loaded, &persist_lease!(&2, &1))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp public_lease(id, stored) do
    %{
      id: id,
      lease: stored.lease,
      status: stored.status,
      active_connections: stored.active_connections,
      total_connections: stored.total_connections,
      revoked_at: stored.revoked_at,
      has_live_token: is_binary(stored.token_hash)
    }
  end

  defp lease_hold(status) when status in [:active, :orphaned], do: @far_future
  defp lease_hold(_status), do: nil

  defp audit_event(state, event_type, lease_id, now, details) do
    event = %{event_type: event_type, lease_id: lease_id, occurred_at: now, details: details}

    if state.store do
      {:ok, _audit} =
        Store.append_audit(
          %{
            event_type: event_type,
            egress_lease_id: lease_id,
            occurred_at: now,
            details: details
          },
          server: state.store
        )
    end

    %{state | audit: [event | state.audit]}
  end

  defp address_text(address), do: address |> :inet.ntoa() |> List.to_string()

  defp fetch!(map, key),
    do:
      case(Map.fetch(map, key),
        do: (
          {:ok, value} -> value
          :error -> Map.fetch!(map, Atom.to_string(key))
        )
      )

  defp fetch(map, key, default), do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
