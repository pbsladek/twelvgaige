defmodule Twelvgaige.Manager.IntegrationCandidate do
  @moduledoc "Human-reviewable integration result; deliberately has no merge operation."

  @enforce_keys [:id, :plan_id, :workspace_id, :source_children, :handoffs, :created_at]
  defstruct [
    :id,
    :plan_id,
    :workspace_id,
    :base_commit,
    :head_commit,
    :commit,
    :patch_artifact,
    :verification,
    :created_at,
    source_children: [],
    handoffs: [],
    artifacts: [],
    claims: [],
    status: :awaiting_verification,
    schema_version: 1,
    encoding_version: 1
  ]
end
