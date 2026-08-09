defmodule Twelvgaige.Handoff do
  @moduledoc "Typed delegated-work result separating authored claims from observed evidence."

  @statuses [:complete, :partial, :failed, :cancelled]

  @enforce_keys [:objective_status, :summary, :workspace_id, :base_commit]
  defstruct [
    :objective_status,
    :summary,
    :workspace_id,
    :base_commit,
    :head_commit,
    :commit,
    :diff_artifact,
    :test_artifact,
    open_questions: [],
    claims: [],
    observed: %{},
    artifacts: [],
    schema_version: 1,
    encoding_version: 1
  ]

  def new(attrs) do
    handoff = struct!(__MODULE__, Map.new(attrs))

    if handoff.objective_status not in @statuses,
      do: raise(ArgumentError, "invalid handoff status")

    Enum.each(handoff.claims, &validate_claim!/1)
    handoff
  end

  defp validate_claim!(%{claim: claim, evidence: evidence})
       when is_binary(claim) and is_binary(evidence),
       do: :ok

  defp validate_claim!(%{"claim" => claim, "evidence" => evidence})
       when is_binary(claim) and is_binary(evidence),
       do: :ok

  defp validate_claim!(_claim), do: raise(ArgumentError, "handoff claims require typed evidence")
end
