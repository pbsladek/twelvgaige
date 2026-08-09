defmodule Twelvgaige.Egress.BrokerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Egress.Broker
  alias Twelvgaige.Operations.Store

  @now ~U[2026-08-03 00:00:00Z]

  test "pins approved public destinations and enforces capability scope and connection limits" do
    resolver = fn
      "api.example.com" -> {:ok, [{93, 184, 216, 34}]}
      "rebound.example.com" -> {:ok, [{127, 0, 0, 1}]}
    end

    broker = start_supervised!({Broker, name: nil, resolver: resolver})
    lease = issue!(broker, max_connections: 1)
    refute inspect(lease) =~ lease.access_token

    assert {:ok, materialized} =
             Broker.materialize(lease.id, lease.access_token, server: broker, now: @now)

    assert materialized.id == lease.id
    assert materialized.access_token == lease.access_token

    assert {:error, :invalid_egress_lease} =
             Broker.materialize(lease.id, String.duplicate("x", 43),
               server: broker,
               now: @now
             )

    assert {:ok, authorization} =
             Broker.checkout(lease.access_token, "https://api.example.com/v1",
               server: broker,
               now: @now
             )

    assert authorization.host == "api.example.com"
    assert authorization.pinned_address == {93, 184, 216, 34}

    assert {:error, :egress_connection_limit} =
             Broker.checkout(lease.access_token, "https://api.example.com/v2",
               server: broker,
               now: @now
             )

    assert :ok = Broker.release(lease.id, server: broker)

    assert {:error, :egress_host_denied} =
             Broker.checkout(lease.access_token, "https://telemetry.example.net/",
               server: broker,
               now: @now
             )

    assert {:error, :egress_port_denied} =
             Broker.checkout(lease.access_token, "https://api.example.com:8443/",
               server: broker,
               now: @now
             )

    assert {:error, :egress_private_address_denied} =
             Broker.checkout(lease.access_token, "https://rebound.example.com/",
               server: broker,
               now: @now
             )

    assert :ok = Broker.revoke(lease.id, server: broker, now: @now)

    assert {:error, :invalid_egress_lease} =
             Broker.checkout(lease.access_token, "https://api.example.com/",
               server: broker,
               now: @now
             )
  end

  test "restart preserves metadata but drops live capabilities and reconciles orphaned leases" do
    root = Path.join(System.tmp_dir!(), "twelvgaige-egress-#{System.unique_integer([:positive])}")
    store = start_supervised!({Store, name: nil, path: Path.join(root, "operations.sqlite3")})

    broker =
      start_supervised!(
        {Broker, name: nil, store: store, resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end}
      )

    lease = issue!(broker)
    GenServer.stop(broker)

    restarted =
      start_supervised!(
        {Broker, name: nil, store: store, resolver: fn _host -> {:ok, [{93, 184, 216, 34}]} end},
        id: :restarted_egress_broker
      )

    assert {:ok, [inventory]} = Broker.inventory(server: restarted)
    assert inventory.id == lease.id
    assert inventory.status == :orphaned
    refute inventory.has_live_token

    assert {:error, :invalid_egress_lease} =
             Broker.checkout(lease.access_token, "https://api.example.com/",
               server: restarted,
               now: @now
             )

    assert {:ok, %{orphaned: [lease_id], mode: :dry_run}} =
             Broker.reconcile(server: restarted)

    assert lease_id == lease.id

    assert {:ok, %{revoked: [^lease_id], mode: :apply}} =
             Broker.reconcile(server: restarted, apply?: true, now: @now)
  end

  defp issue!(broker, opts \\ []) do
    {:ok, lease} =
      Broker.issue(
        %{
          session_id: "session-egress",
          allowed_hosts: ["api.example.com", "rebound.example.com"],
          allowed_ports: [443],
          max_connections: Keyword.get(opts, :max_connections, 4),
          expires_at: DateTime.add(@now, 300)
        },
        server: broker,
        now: @now
      )

    lease
  end
end
