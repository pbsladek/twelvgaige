defmodule Twelvgaige.Credential.Broker do
  @moduledoc "Issues, authorizes, accounts, and revokes narrow session credential leases."

  use GenServer

  alias Twelvgaige.Credential.Lease
  alias Twelvgaige.Operations.Store

  @far_future ~U[9999-12-31 23:59:59Z]

  defstruct [:store, leases: %{}, audit: []]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  def issue(attrs, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:issue, attrs, opts})

  def authorize(access_token, request, opts \\ []),
    do:
      GenServer.call(
        Keyword.get(opts, :server, __MODULE__),
        {:authorize, access_token, request, opts}
      )

  def revoke(lease_id, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:revoke, lease_id, opts})

  def audit(opts \\ []), do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :audit)

  def inventory(opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :inventory)

  def reconcile(opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:reconcile, opts})

  @impl true
  def init(opts) do
    state = %__MODULE__{store: Keyword.get(opts, :store)}
    {:ok, load_durable_leases(state)}
  end

  @impl true
  def handle_call({:issue, attrs, opts}, _from, state) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
    token = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    id = "lease_" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    lease =
      struct!(Lease, %{
        id: id,
        session_id: fetch!(attrs, :session_id),
        round_id: fetch!(attrs, :round_id),
        shot_id: fetch!(attrs, :shot_id),
        attempt: fetch!(attrs, :attempt),
        runtime: fetch!(attrs, :runtime),
        principal: fetch!(attrs, :principal),
        provider_account: fetch!(attrs, :provider_account),
        models: fetch!(attrs, :models),
        destinations: fetch!(attrs, :destinations),
        budget: fetch!(attrs, :budget),
        expires_at: fetch!(attrs, :expires_at),
        access_token: token
      })

    stored = %{
      lease: %{lease | access_token: nil},
      token_hash: hash(token),
      upstream_secret: fetch!(attrs, :upstream_secret),
      used: 0,
      revoked_at: nil,
      status: :active
    }

    state =
      state
      |> put_in([Access.key!(:leases), id], stored)
      |> persist_lease(id)
      |> audit_event(:credential_issued, id, now, %{session_id: lease.session_id})

    {:reply, {:ok, lease}, state}
  end

  def handle_call({:authorize, token, request, opts}, _from, state) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

    case find_by_token(state.leases, token) do
      {lease_id, stored} ->
        case authorize_request(stored, request, now) do
          {:ok, amount} ->
            stored = %{stored | used: stored.used + amount}

            state =
              state
              |> put_in([Access.key!(:leases), lease_id], stored)
              |> audit_event(:credential_used, lease_id, now, %{amount: amount})

            {:reply, {:ok, %{lease_id: lease_id, upstream_secret: stored.upstream_secret}}, state}

          {:error, reason} ->
            {:reply, {:error, reason},
             audit_event(state, :credential_denied, lease_id, now, %{reason: reason})}
        end

      nil ->
        {:reply, {:error, :invalid_credential_lease}, state}
    end
  end

  def handle_call({:revoke, lease_id, opts}, _from, state) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

    case Map.fetch(state.leases, lease_id) do
      {:ok, stored} ->
        state =
          state
          |> put_in([Access.key!(:leases), lease_id], %{
            stored
            | revoked_at: now,
              upstream_secret: nil,
              status: :revoked
          })
          |> persist_lease(lease_id)
          |> audit_event(:credential_revoked, lease_id, now, %{})

        {:reply, :ok, state}

      :error ->
        {:reply, :already_revoked, state}
    end
  end

  def handle_call(:audit, _from, state), do: {:reply, Enum.reverse(state.audit), state}

  def handle_call(:inventory, _from, state) do
    leases =
      state.leases
      |> Enum.map(fn {id, stored} -> public_lease(id, stored) end)
      |> Enum.sort_by(& &1.id)

    {:reply, {:ok, leases}, state}
  end

  def handle_call({:reconcile, opts}, _from, state) do
    orphaned =
      state.leases
      |> Enum.filter(fn {_id, stored} -> stored.status == :orphaned end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()

    if Keyword.get(opts, :apply?, false) do
      now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

      state =
        Enum.reduce(orphaned, state, fn id, acc ->
          stored = Map.fetch!(acc.leases, id)

          acc
          |> put_in([Access.key!(:leases), id], %{
            stored
            | status: :revoked,
              revoked_at: now,
              token_hash: nil,
              upstream_secret: nil
          })
          |> persist_lease(id)
          |> audit_event(:credential_revoked, id, now, %{reason: :restart_reconciliation})
        end)

      {:reply, {:ok, %{orphaned: orphaned, revoked: orphaned, mode: :apply}}, state}
    else
      {:reply, {:ok, %{orphaned: orphaned, revoked: [], mode: :dry_run}}, state}
    end
  end

  defp authorize_request(stored, request, now) do
    amount = value(request, :amount, 0)
    lease = stored.lease

    cond do
      stored.status == :orphaned ->
        {:error, :credential_lease_orphaned}

      stored.status == :revoked or not is_nil(stored.revoked_at) ->
        {:error, :credential_lease_revoked}

      DateTime.compare(now, lease.expires_at) != :lt ->
        {:error, :credential_lease_expired}

      value(request, :session_id) != lease.session_id ->
        {:error, :credential_session_mismatch}

      value(request, :model) not in lease.models ->
        {:error, :credential_model_denied}

      value(request, :destination) not in lease.destinations ->
        {:error, :credential_destination_denied}

      not is_integer(amount) or amount < 0 ->
        {:error, :credential_amount_invalid}

      stored.used + amount > lease.budget ->
        {:error, :credential_budget_exhausted}

      true ->
        {:ok, amount}
    end
  end

  defp find_by_token(leases, token) do
    token_hash = hash(token)

    Enum.find(leases, fn {_id, stored} ->
      is_binary(stored.token_hash) and
        Twelvgaige.Security.secure_equal?(stored.token_hash, token_hash)
    end)
  end

  defp audit_event(state, event_type, lease_id, now, payload) do
    event = %{event_type: event_type, lease_id: lease_id, occurred_at: now, payload: payload}

    if state.store do
      _ =
        Store.append_audit(
          %{
            event_type: event_type,
            credential_lease_id: lease_id,
            occurred_at: now,
            details: payload
          },
          server: state.store
        )
    end

    %{state | audit: [event | state.audit]}
  end

  defp persist_lease(%{store: nil} = state, _lease_id), do: state

  defp persist_lease(state, lease_id) do
    stored = Map.fetch!(state.leases, lease_id)

    :ok =
      Store.put(:credential_lease, lease_id, public_lease(lease_id, stored),
        server: state.store,
        retention_class: :security,
        hold_until: lease_hold(stored.status)
      )

    state
  end

  defp load_durable_leases(%{store: nil} = state), do: state

  defp load_durable_leases(state) do
    case Store.list(:credential_lease, server: state.store) do
      {:ok, records} ->
        leases =
          Map.new(records, fn record ->
            lease = record.value.lease
            status = if record.value.status == :active, do: :orphaned, else: record.value.status

            stored = %{
              lease: lease,
              token_hash: nil,
              upstream_secret: nil,
              used: record.value.used,
              revoked_at: record.value.revoked_at,
              status: status
            }

            {record.key, stored}
          end)

        state = %{state | leases: leases}

        Enum.reduce(leases, state, fn {id, _stored}, acc -> persist_lease(acc, id) end)

      {:error, _reason} ->
        state
    end
  end

  defp public_lease(id, stored) do
    %{
      id: id,
      lease: %{stored.lease | access_token: nil},
      status: stored.status,
      used: stored.used,
      revoked_at: stored.revoked_at,
      has_live_token: is_binary(stored.token_hash),
      has_upstream_secret: not is_nil(stored.upstream_secret)
    }
  end

  defp lease_hold(status) when status in [:active, :orphaned], do: @far_future
  defp lease_hold(_status), do: nil

  defp hash(token), do: :crypto.hash(:sha256, token)

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(map, Atom.to_string(key))
    end
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
