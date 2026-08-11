defmodule Twelvgaige.Workspace.Operation do
  @moduledoc "Durable write-ahead record for one idempotent workspace mutation."

  alias Twelvgaige.Workspace.Canonical

  @statuses [:intent_recorded, :side_effects_started, :completed, :failed, :needs_reconciliation]

  @enforce_keys [
    :id,
    :request_id,
    :kind,
    :workspace_id,
    :intent_digest,
    :status,
    :created_at,
    :updated_at
  ]
  defstruct [
    :id,
    :request_id,
    :kind,
    :workspace_id,
    :intent_digest,
    :status,
    :created_at,
    :updated_at,
    :completed_at,
    :error,
    :result,
    :expected_epoch,
    effects: [],
    schema_version: 1,
    encoding_version: 1
  ]

  @type t :: %__MODULE__{}

  def new(kind, workspace_id, intent, opts \\ [])
      when is_atom(kind) and is_binary(workspace_id) and is_map(intent) do
    request_id = Keyword.get(opts, :request_id, "req_" <> random_id())
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
    {:ok, digest} = Canonical.digest("workspace-operation-intent", 1, intent)

    %__MODULE__{
      id: "wop_" <> random_id(),
      request_id: request_id,
      kind: kind,
      workspace_id: workspace_id,
      intent_digest: digest,
      status: :intent_recorded,
      expected_epoch: Keyword.get(opts, :expected_epoch),
      created_at: now,
      updated_at: now
    }
  end

  def transition(%__MODULE__{} = operation, status, attrs \\ %{}) when status in @statuses do
    now = Map.get(attrs, :now, Twelvgaige.Clock.utc_now())

    %{
      operation
      | status: status,
        effects: Map.get(attrs, :effects, operation.effects),
        result: Map.get(attrs, :result, operation.result),
        error: Map.get(attrs, :error, operation.error),
        updated_at: now,
        completed_at: if(status == :completed, do: now, else: operation.completed_at)
    }
  end

  def terminal?(%__MODULE__{status: status}),
    do: status in [:completed, :failed, :needs_reconciliation]

  def valid?(%__MODULE__{status: status, request_id: request_id, intent_digest: digest}) do
    status in @statuses and is_binary(request_id) and request_id != "" and is_binary(digest)
  end

  def valid?(_operation), do: false

  defp random_id,
    do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)
end
