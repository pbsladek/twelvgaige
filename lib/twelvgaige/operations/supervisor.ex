defmodule Twelvgaige.Operations.Supervisor do
  @moduledoc "Phase 7 single-user unattended operations supervision tree."

  use Supervisor

  alias Twelvgaige.Operations.{
    AuditAnchor,
    LocalIdentity,
    Keyring,
    Keys,
    Paths,
    ProviderLimiter,
    RetentionEnforcer,
    SessionControl,
    Store
  }

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    with {:ok, identity} <-
           LocalIdentity.current(
             uid: Keyword.get(opts, :owner_uid),
             username: Keyword.get(opts, :username)
           ),
         {:ok, _paths} <- Paths.prepare(Keyword.put(opts, :owner_uid, identity.uid)),
         {:ok, keys} <- Keys.resolve(opts) do
      init_children(opts, identity, keys)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp init_children(opts, identity, keys) do
    store_name = Keyword.get(opts, :store_name, Store)
    session_name = Keyword.get(opts, :session_name, SessionControl)
    limiter_name = Keyword.get(opts, :provider_limiter_name, ProviderLimiter)
    retention_name = Keyword.get(opts, :retention_name, RetentionEnforcer)
    audit_anchor_name = Keyword.get(opts, :audit_anchor_name, AuditAnchor)

    credential_broker_name =
      Keyword.get(opts, :credential_broker_name, Twelvgaige.Credential.Broker)

    egress_broker_name = Keyword.get(opts, :egress_broker_name, Twelvgaige.Egress.Broker)
    egress_gateway_name = Keyword.get(opts, :egress_gateway_name, Twelvgaige.Egress.Gateway)

    keyring_name = Keyword.get(opts, :keyring_name, Keyring)
    {artifact_children, artifact_store} = artifact_children(opts, keys)

    path = Keyword.get(opts, :path, Paths.operations_database(opts))

    session_opts =
      [
        name: session_name,
        store: store_name,
        owner_uid: identity.uid,
        username: identity.username,
        signing_key: Keyword.get(opts, :session_signing_key, keys.session_signing_key),
        backends: Keyword.get(opts, :backends, %{}),
        backend_opts: Keyword.get(opts, :backend_opts, %{}),
        workspace_root: Keyword.get(opts, :workspace_root, Paths.workspaces(opts)),
        artifact_store: artifact_store,
        credential_broker: credential_broker_name,
        egress_broker: egress_broker_name,
        cancel_fun: Keyword.get(opts, :cancel_fun, fn _session -> :ok end)
      ]
      |> maybe_put(:credential_revoke_fun, Keyword.get(opts, :credential_revoke_fun))

    children =
      artifact_children ++
        [
          {Keyring, name: keyring_name, keys: keys, artifact_store: artifact_store},
          {Store,
           name: store_name,
           path: path,
           raw_retention_days: Keyword.get(opts, :raw_retention_days, 30),
           security_retention_days: Keyword.get(opts, :security_retention_days, 90)},
          {AuditAnchor,
           name: audit_anchor_name,
           store: store_name,
           path: Keyword.get(opts, :audit_checkpoint_path, Paths.audit_checkpoints(opts)),
           external_path: Keyword.get(opts, :audit_checkpoint_external_path),
           signing_key: keys.audit_export_key,
           owner_uid: identity.uid,
           interval_ms: Keyword.get(opts, :audit_checkpoint_interval_ms, 3_600_000),
           max_age_seconds: Keyword.get(opts, :audit_checkpoint_max_age_seconds, 7_200)},
          {Twelvgaige.Credential.Broker, name: credential_broker_name, store: store_name},
          {Twelvgaige.Egress.Broker, name: egress_broker_name, store: store_name},
          {Twelvgaige.Egress.Gateway,
           name: egress_gateway_name,
           broker: egress_broker_name,
           bind_address: Keyword.get(opts, :egress_bind_address, {127, 0, 0, 1}),
           port: Keyword.get(opts, :egress_port, 0)},
          {SessionControl, session_opts},
          {ProviderLimiter,
           name: limiter_name, store: store_name, limits: Keyword.get(opts, :provider_limits, %{})},
          {RetentionEnforcer,
           name: retention_name,
           store: store_name,
           artifact_store: artifact_store,
           interval_ms: Keyword.get(opts, :retention_interval_ms, 3_600_000)}
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp artifact_children(opts, keys) do
    case Keyword.get(opts, :artifact_store, :default) do
      false ->
        {[], nil}

      :default ->
        name = Keyword.get(opts, :artifact_store_name, Twelvgaige.Artifact.Store)

        child =
          {Twelvgaige.Artifact.Store,
           name: name,
           root: Keyword.get(opts, :artifact_root, Paths.artifacts(opts)),
           key: keys.artifact_key,
           key_id: keys.artifact_key_id,
           previous_keys: keys.artifact_previous_keys,
           raw_retention_days: Keyword.get(opts, :raw_retention_days, 30),
           security_retention_days: Keyword.get(opts, :security_retention_days, 90)}

        {[child], name}

      server ->
        {[], server}
    end
  end
end
