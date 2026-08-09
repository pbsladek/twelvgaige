defmodule Twelvgaige.Operations.SupervisorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Artifact.Store, as: ArtifactStore
  alias Twelvgaige.Operations.{AuditAnchor, Keyring, LocalIdentity, SessionControl, Store}
  alias Twelvgaige.Operations.Supervisor, as: OperationsSupervisor

  test "single-user operations tree restarts with stable host-derived keys and durable state" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-operations-tree-#{System.unique_integer([:positive])}"
      )

    {:ok, identity} = LocalIdentity.current()
    master = :crypto.strong_rand_bytes(32)

    opts = [
      name: nil,
      data_root: root,
      operations_master_key: master,
      store_name: __MODULE__.StoreServer,
      session_name: __MODULE__.SessionServer,
      provider_limiter_name: __MODULE__.LimiterServer,
      retention_name: __MODULE__.RetentionServer,
      audit_anchor_name: __MODULE__.AuditAnchorServer,
      credential_broker_name: __MODULE__.CredentialServer,
      egress_broker_name: __MODULE__.EgressServer,
      egress_gateway_name: __MODULE__.EgressGatewayServer,
      keyring_name: __MODULE__.KeyringServer,
      artifact_store_name: __MODULE__.ArtifactServer,
      owner_uid: identity.uid,
      username: identity.username,
      retention_interval_ms: 86_400_000
    ]

    tree =
      start_supervised!(%{
        id: :operations_tree,
        start: {OperationsSupervisor, :start_link, [opts]},
        restart: :temporary
      })

    children = child_map(tree)
    store = Map.fetch!(children, Store)
    sessions = Map.fetch!(children, SessionControl)
    artifacts = Map.fetch!(children, ArtifactStore)
    keyring = Map.fetch!(children, Keyring)
    audit_anchor = Map.fetch!(children, AuditAnchor)

    assert {:ok, ref} = ArtifactStore.put(%{value: "durable"}, server: artifacts)

    assert {:ok, _session} =
             SessionControl.register(
               %{
                 id: "session_tree",
                 status: :running,
                 runtime: :codex,
                 artifact_refs: [ref],
                 created_at: DateTime.utc_now()
               },
               server: sessions
             )

    assert %{master_backend: :injected} = Keyring.status(server: keyring)
    assert {:ok, %{schema_version: 3}} = Store.stats(server: store)
    assert {:ok, %{sequence: sequence}} = AuditAnchor.run(server: audit_anchor)
    assert sequence >= 1
    assert %{status: :healthy} = AuditAnchor.status(server: audit_anchor)

    Elixir.Supervisor.stop(tree)

    restarted =
      start_supervised!(%{
        id: :restarted_operations_tree,
        start: {OperationsSupervisor, :start_link, [opts]},
        restart: :temporary
      })

    children = child_map(restarted)
    restarted_sessions = Map.fetch!(children, SessionControl)
    restarted_artifacts = Map.fetch!(children, ArtifactStore)

    assert {:ok, %{status: :running}} =
             SessionControl.get("session_tree", server: restarted_sessions)

    assert {:ok, %{value: "durable"}} = ArtifactStore.get(ref, server: restarted_artifacts)
  end

  defp child_map(supervisor) do
    supervisor
    |> Elixir.Supervisor.which_children()
    |> Map.new(fn {id, pid, _type, _modules} -> {id, pid} end)
  end
end
