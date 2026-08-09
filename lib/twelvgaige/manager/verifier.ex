defmodule Twelvgaige.Manager.Verifier do
  @moduledoc "Independent evidence verifier and one-attempt repair-plan constructor."

  alias Twelvgaige.Manager.{Budget, ChildRecord, IntegrationCandidate}

  def verify(%IntegrationCandidate{} = candidate, worker_principals, verifier_principal, verifier)
      when is_list(worker_principals) and is_function(verifier, 1) do
    cond do
      verifier_principal in worker_principals ->
        {:error, :manager_verifier_not_independent}

      Enum.any?(candidate.claims, &(not typed_claim?(&1))) ->
        {:error, :manager_claim_evidence_invalid}

      true ->
        case verifier.(candidate) do
          {:ok, evidence} ->
            {:ok,
             %{
               candidate
               | status: :verified,
                 verification: %{principal: verifier_principal, evidence: evidence}
             }}

          {:error, reason} ->
            {:error, {:manager_verification_failed, reason}}
        end
    end
  end

  def repair_child(compiled, %ChildRecord{} = failed, %Budget{} = remaining, repair_count)
      when repair_count in [0, 1] do
    cond do
      repair_count >= 1 ->
        {:error, :manager_repair_limit_reached}

      not Budget.within?(failed.budget, remaining) ->
        {:error, :manager_repair_budget_exhausted}

      true ->
        task = %{
          failed.task
          | id: failed.task.id <> ":repair:1",
            role: :repair,
            attempt: 1,
            retry_of_task_id: failed.task.id,
            depends_on: []
        }

        {:ok, ChildRecord.new(compiled, task, %{attempt: 1})}
    end
  end

  defp typed_claim?(%{claim: claim, evidence: evidence})
       when is_binary(claim) and is_binary(evidence), do: true

  defp typed_claim?(%{"claim" => claim, "evidence" => evidence})
       when is_binary(claim) and is_binary(evidence), do: true

  defp typed_claim?(_claim), do: false
end
