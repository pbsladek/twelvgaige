defmodule Twelvgaige.Credential.BrokerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Credential.Broker
  alias Twelvgaige.Operations.Store

  test "binds short-lived leases to session, model, destination, and budget" do
    broker = start_supervised!({Broker, name: nil})
    now = ~U[2026-08-02 12:00:00Z]

    assert {:ok, lease} =
             Broker.issue(
               %{
                 session_id: "sess_1",
                 round_id: "round_1",
                 shot_id: "delegate",
                 attempt: 1,
                 runtime: :codex,
                 principal: "local-user",
                 provider_account: "account-1",
                 models: ["gpt-5"],
                 destinations: ["api.openai.com"],
                 budget: 100,
                 expires_at: DateTime.add(now, 300),
                 upstream_secret: "upstream-secret"
               },
               server: broker,
               now: now
             )

    refute inspect(lease) =~ lease.access_token

    request = %{session_id: "sess_1", model: "gpt-5", destination: "api.openai.com", amount: 60}

    assert {:ok, %{upstream_secret: "upstream-secret"}} =
             Broker.authorize(lease.access_token, request, server: broker, now: now)

    assert {:error, :credential_budget_exhausted} =
             Broker.authorize(lease.access_token, request, server: broker, now: now)

    assert :ok = Broker.revoke(lease.id, server: broker, now: now)

    assert {:error, :credential_lease_revoked} =
             Broker.authorize(lease.access_token, %{request | amount: 1},
               server: broker,
               now: now
             )

    refute inspect(Broker.audit(server: broker)) =~ "upstream-secret"
  end

  test "restart preserves lease identity without restoring tokens or upstream credentials" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-credential-recovery-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "operations.sqlite3")
    store = start_supervised!({Store, name: nil, path: path})
    broker = start_supervised!({Broker, name: nil, store: store})
    now = ~U[2026-08-02 12:00:00Z]

    assert {:ok, lease} =
             Broker.issue(
               %{
                 session_id: "sess_recovery",
                 round_id: "round_1",
                 shot_id: "delegate",
                 attempt: 1,
                 runtime: :codex,
                 principal: "local-user",
                 provider_account: "account-1",
                 models: ["gpt-5"],
                 destinations: ["api.openai.com"],
                 budget: 100,
                 expires_at: DateTime.add(now, 300),
                 upstream_secret: "never-persist-this-upstream-secret"
               },
               server: broker,
               now: now
             )

    GenServer.stop(broker)

    restarted =
      start_supervised!({Broker, name: nil, store: store}, id: :restarted_credential_broker)

    assert {:ok, [inventory]} = Broker.inventory(server: restarted)
    assert inventory.id == lease.id
    assert inventory.status == :orphaned
    refute inventory.has_live_token
    refute inventory.has_upstream_secret

    assert {:error, :invalid_credential_lease} =
             Broker.authorize(
               lease.access_token,
               %{
                 session_id: "sess_recovery",
                 model: "gpt-5",
                 destination: "api.openai.com",
                 amount: 1
               },
               server: restarted,
               now: now
             )

    assert {:ok, %{orphaned: [lease_id], mode: :dry_run}} =
             Broker.reconcile(server: restarted)

    assert lease_id == lease.id

    assert {:ok, %{revoked: [^lease_id], mode: :apply}} =
             Broker.reconcile(server: restarted, apply?: true, now: now)

    refute File.read!(path) =~ "never-persist-this-upstream-secret"
  end
end
