defmodule Twelvgaige.Manager.WorkspaceFinalizer do
  @moduledoc "Finalizes a manager child's workspace after runtime quiescence is proven."

  alias Twelvgaige.Handoff
  alias Twelvgaige.Manager.ChildRecord
  alias Twelvgaige.Manager.VerificationSandbox
  alias Twelvgaige.Workspace.Manager, as: WorkspaceManager

  @spec finalize(ChildRecord.t(), term(), keyword()) :: term()
  def finalize(%ChildRecord{} = child, result, opts) do
    manager = Keyword.fetch!(opts, :workspace_manager)

    with {:ok, evidence} <- quiescence_evidence(result),
         {:ok, _workspace} <-
           WorkspaceManager.quiesce(child.workspace_id, evidence, server: manager),
         {:ok, verification} <- independent_verification(child, manager, opts),
         {:ok, workspace, report} <-
           WorkspaceManager.finalize(child.workspace_id,
             server: manager,
             artifact_store: Keyword.get(opts, :artifact_store),
             agent_execution: agent_outcome(result),
             test_verification: verification.status
           ),
         :ok <- compliant(workspace) do
      result
      |> attach_workspace_result(workspace, report)
      |> attach_verification_result(verification)
    else
      {:error, reason} ->
        _ = WorkspaceManager.quarantine(child.workspace_id, reason, server: manager)
        {:error, {:manager_workspace_finalization_failed, reason}}
    end
  end

  defp quiescence_evidence({:ok, %{runtime_quiescence: evidence}}),
    do: validate_quiescence(evidence)

  defp quiescence_evidence({:ok, %{session: %{result: %{runtime_quiescence: evidence}}}}),
    do: validate_quiescence(evidence)

  defp quiescence_evidence({:error, _reason, %{runtime_quiescence: evidence}}),
    do: validate_quiescence(evidence)

  defp quiescence_evidence(_result), do: {:error, :manager_runtime_quiescence_missing}

  defp validate_quiescence(
         %{
           runtime_stopped: true,
           runtime_identity: identity,
           stopped_at: %DateTime{}
         } = evidence
       )
       when is_binary(identity) and identity != "",
       do: {:ok, evidence}

  defp validate_quiescence(_evidence), do: {:error, :manager_runtime_quiescence_invalid}

  defp agent_outcome({:ok, _result}), do: :completed
  defp agent_outcome({:error, :deadline_exceeded, _evidence}), do: :timed_out
  defp agent_outcome({:error, :plan_deadline_exceeded, _evidence}), do: :timed_out
  defp agent_outcome({:error, :parent_cancelled, _evidence}), do: :cancelled
  defp agent_outcome({:error, _reason, _evidence}), do: :failed

  defp independent_verification(child, manager, opts) do
    commands = Keyword.get(opts, :verification_commands, [])

    if commands == [] do
      {:ok, %{status: :not_run, evidence: nil}}
    else
      with {:ok, workspace} <- WorkspaceManager.get(child.workspace_id, server: manager) do
        case VerificationSandbox.verify(workspace, commands, opts) do
          {:ok, evidence} -> {:ok, %{status: :passed, evidence: evidence}}
          {:error, reason} -> {:ok, %{status: :failed, evidence: %{reason: reason}}}
        end
      end
    end
  end

  defp attach_verification_result({:ok, result}, %{status: :failed} = verification) do
    {:error, :independent_verification_failed,
     result
     |> Map.put(:verification, verification)
     |> Map.put_new(:usage, %{tokens: 0, cost_micros: 0, time_ms: 0, tool_calls: 0})}
  end

  defp attach_verification_result({:ok, result}, verification),
    do: {:ok, Map.put(result, :verification, verification)}

  defp attach_verification_result({:error, reason, evidence}, verification),
    do: {:error, reason, Map.put(evidence, :verification, verification)}

  defp compliant(%{state: :quarantined}), do: {:error, :workspace_policy_rejected}
  defp compliant(_workspace), do: :ok

  defp attach_workspace_result(
         {:ok, %{handoff: %Handoff{} = handoff} = result},
         workspace,
         report
       ) do
    {:ok,
     result
     |> Map.put(:handoff, update_handoff(handoff, workspace, report))
     |> Map.put(:workspace_result, report.manifest)}
  end

  defp attach_workspace_result({:error, reason, evidence}, workspace, report)
       when is_map(evidence) do
    handoff =
      evidence
      |> Map.get(:handoff, failure_handoff(reason, workspace))
      |> update_handoff(workspace, report)

    {:error, reason,
     evidence
     |> Map.put(:handoff, handoff)
     |> Map.put(:workspace_result, report.manifest)}
  end

  defp failure_handoff(reason, workspace) do
    Handoff.new(%{
      objective_status: failure_status(reason),
      summary: "Delegated execution stopped before successful completion: #{inspect(reason)}",
      workspace_id: workspace.id,
      base_commit: workspace.base_commit
    })
  end

  defp failure_status(reason) when reason in [:parent_cancelled, :cancelled], do: :cancelled
  defp failure_status(_reason), do: :failed

  defp update_handoff(handoff, workspace, report) do
    artifacts =
      case report.artifact_ref do
        nil -> handoff.artifacts
        ref -> Enum.uniq(handoff.artifacts ++ [ref])
      end

    observed =
      Map.merge(handoff.observed, %{
        result_manifest_digest: report.manifest.manifest_digest,
        result_tree: report.manifest.result_tree,
        result_outcomes: report.manifest.outcomes
      })

    %{
      handoff
      | head_commit: workspace.head_commit,
        diff_artifact: report.artifact_ref,
        artifacts: artifacts,
        observed: observed
    }
  end
end
