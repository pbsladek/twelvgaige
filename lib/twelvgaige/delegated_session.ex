defmodule Twelvgaige.DelegatedSession do
  @moduledoc "Durable, provider-neutral identity and lifecycle for delegated agent work."

  @statuses [
    :preparing,
    :authenticating,
    :creating_sandbox,
    :starting,
    :running,
    :cancelling,
    :completed,
    :failed,
    :cancelled,
    :awaiting_reconciliation,
    :finalizing,
    :finalized
  ]
  @terminal [:completed, :failed, :cancelled, :awaiting_reconciliation, :finalized]

  @enforce_keys [
    :id,
    :round_id,
    :shot_id,
    :attempt,
    :runtime,
    :driver,
    :runtime_version,
    :workspace_id,
    :base_commit,
    :auth_profile_id,
    :auth_revision,
    :sandbox_profile,
    :sandbox_manifest_digest,
    :policy_revision,
    :deadline,
    :created_at
  ]
  defstruct [
    :id,
    :round_id,
    :shot_id,
    :attempt,
    :runtime,
    :driver,
    :runtime_version,
    :integration_descriptor_id,
    :external_session_id,
    :external_turn_id,
    :workspace_id,
    :base_commit,
    :head_commit,
    :auth_profile_id,
    :auth_revision,
    :principal,
    :provider_tenant,
    :sandbox_profile,
    :sandbox_manifest_digest,
    :sandbox_resource_id,
    :egress_lease_id,
    :policy_revision,
    :budgets,
    :deadline,
    :result,
    :exit_reason,
    :created_at,
    :updated_at,
    :finalized_at,
    status: :preparing,
    capabilities: %{},
    effective_capabilities: [],
    last_event_sequence: 0,
    last_usage: %{},
    artifact_refs: [],
    schema_version: 1,
    encoding_version: 1
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    status = value(attrs, :status, :preparing)
    if status not in @statuses, do: raise(ArgumentError, "invalid delegated session status")

    struct!(__MODULE__, %{
      id: required!(attrs, :id),
      round_id: required!(attrs, :round_id),
      shot_id: required!(attrs, :shot_id),
      attempt: required!(attrs, :attempt),
      runtime: required!(attrs, :runtime),
      driver: required!(attrs, :driver),
      runtime_version: required!(attrs, :runtime_version),
      integration_descriptor_id: value(attrs, :integration_descriptor_id),
      external_session_id: value(attrs, :external_session_id),
      external_turn_id: value(attrs, :external_turn_id),
      workspace_id: required!(attrs, :workspace_id),
      base_commit: required!(attrs, :base_commit),
      head_commit: value(attrs, :head_commit),
      auth_profile_id: required!(attrs, :auth_profile_id),
      auth_revision: required!(attrs, :auth_revision),
      principal: value(attrs, :principal),
      provider_tenant: value(attrs, :provider_tenant),
      sandbox_profile: required!(attrs, :sandbox_profile),
      sandbox_manifest_digest: required!(attrs, :sandbox_manifest_digest),
      sandbox_resource_id: value(attrs, :sandbox_resource_id),
      egress_lease_id: value(attrs, :egress_lease_id),
      policy_revision: required!(attrs, :policy_revision),
      budgets: value(attrs, :budgets, %{}),
      deadline: required!(attrs, :deadline),
      result: value(attrs, :result),
      exit_reason: value(attrs, :exit_reason),
      created_at: required!(attrs, :created_at),
      updated_at: value(attrs, :updated_at),
      finalized_at: value(attrs, :finalized_at),
      status: status,
      capabilities: value(attrs, :capabilities, %{}),
      effective_capabilities: value(attrs, :effective_capabilities, []),
      last_event_sequence: value(attrs, :last_event_sequence, 0),
      last_usage: value(attrs, :last_usage, %{}),
      artifact_refs: value(attrs, :artifact_refs, []),
      schema_version: value(attrs, :schema_version, 1),
      encoding_version: value(attrs, :encoding_version, 1)
    })
  end

  @spec resume_compatible?(t(), t() | map()) :: :ok | {:error, {:identity_drift, [atom()]}}
  def resume_compatible?(%__MODULE__{} = durable, candidate) do
    candidate = if match?(%__MODULE__{}, candidate), do: candidate, else: new(candidate)

    fields = [
      :runtime,
      :driver,
      :runtime_version,
      :integration_descriptor_id,
      :workspace_id,
      :base_commit,
      :auth_profile_id,
      :auth_revision,
      :sandbox_profile,
      :sandbox_manifest_digest,
      :egress_lease_id,
      :policy_revision,
      :principal,
      :budgets,
      :deadline,
      :capabilities,
      :effective_capabilities
    ]

    drift = Enum.filter(fields, &(Map.fetch!(durable, &1) != Map.fetch!(candidate, &1)))
    if drift == [], do: :ok, else: {:error, {:identity_drift, drift}}
  end

  @spec transition(t(), atom(), keyword()) :: {:ok, t()} | {:error, term()}
  def transition(%__MODULE__{} = session, next_status, opts \\ []) do
    if next_status in allowed_next(session.status) do
      now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

      {:ok,
       %{
         session
         | status: next_status,
           updated_at: now,
           finalized_at: if(next_status == :finalized, do: now, else: session.finalized_at),
           result: Keyword.get(opts, :result, session.result),
           exit_reason: Keyword.get(opts, :exit_reason, session.exit_reason)
       }}
    else
      {:error, {:invalid_session_transition, session.status, next_status}}
    end
  end

  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  defp allowed_next(:preparing), do: [:authenticating, :failed, :cancelled]
  defp allowed_next(:authenticating), do: [:creating_sandbox, :failed, :cancelled]
  defp allowed_next(:creating_sandbox), do: [:starting, :failed, :cancelled]
  defp allowed_next(:starting), do: [:running, :failed, :cancelling, :awaiting_reconciliation]
  defp allowed_next(:running), do: [:cancelling, :completed, :failed, :awaiting_reconciliation]
  defp allowed_next(:cancelling), do: [:cancelled, :failed, :awaiting_reconciliation]
  defp allowed_next(status) when status in [:completed, :failed, :cancelled], do: [:finalizing]
  defp allowed_next(:awaiting_reconciliation), do: [:running, :failed, :cancelled, :finalizing]
  defp allowed_next(:finalizing), do: [:finalized, :failed]
  defp allowed_next(:finalized), do: []

  defp required!(attrs, key) do
    case value(attrs, key, :missing) do
      :missing -> raise ArgumentError, "missing delegated session field #{key}"
      value -> value
    end
  end

  defp value(attrs, key, default \\ nil)
  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default) when is_map(attrs),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
