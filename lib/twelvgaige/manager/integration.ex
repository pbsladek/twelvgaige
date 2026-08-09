defmodule Twelvgaige.Manager.Integration do
  @moduledoc "Builds a separate integration workspace from typed child handoffs without merging automatically."

  alias Twelvgaige.Handoff
  alias Twelvgaige.Manager.{ChildRecord, IntegrationCandidate}
  alias Twelvgaige.Workspace.Manager, as: WorkspaceManager

  def build(plan_id, children, opts \\ []) when is_list(children) do
    with :ok <- valid_handoffs(children),
         {:ok, workspace} <- integration_workspace(children, opts),
         :ok <- separate_workspace(workspace, children),
         {:ok, applied} <- apply_handoffs(workspace, children, opts) do
      handoffs = Enum.map(children, & &1.handoff)

      {:ok,
       %IntegrationCandidate{
         id: Twelvgaige.ID.new(:artifact),
         plan_id: plan_id,
         workspace_id: workspace.id,
         base_commit: workspace.base_commit,
         head_commit: Map.get(applied, :head_commit),
         commit: Map.get(applied, :commit),
         patch_artifact: Map.get(applied, :patch_artifact),
         source_children: Enum.map(children, & &1.id),
         handoffs: handoffs,
         artifacts: Enum.flat_map(handoffs, & &1.artifacts),
         claims: Enum.flat_map(handoffs, & &1.claims),
         created_at: DateTime.utc_now()
       }}
    end
  end

  defp valid_handoffs(children) do
    invalid =
      Enum.reject(children, fn
        %ChildRecord{status: :completed, handoff: %Handoff{} = handoff} ->
          is_binary(handoff.commit) or is_binary(handoff.diff_artifact) or handoff.artifacts != []

        _other ->
          false
      end)

    if invalid == [],
      do: :ok,
      else: {:error, {:manager_integration_handoff_invalid, Enum.map(invalid, & &1.id)}}
  end

  defp integration_workspace([first | _] = children, opts) do
    case Keyword.get(opts, :workspace_allocator) do
      allocator when is_function(allocator, 1) ->
        allocator.(first)

      nil ->
        WorkspaceManager.create(first.task.repository,
          server: Keyword.get(opts, :workspace_manager, WorkspaceManager),
          transport: :copy_snapshot,
          interactive?: false,
          base_ref: first.task.base_ref,
          round_id: first.round_id,
          shot_id: first.shot_id,
          writable: true,
          allowed_paths: Enum.uniq(Enum.flat_map(children, & &1.task.allowed_paths))
        )
    end
  end

  defp integration_workspace([], _opts), do: {:error, :manager_integration_empty}

  defp separate_workspace(%{id: id}, children) when is_binary(id) do
    if Enum.any?(children, &(&1.workspace_id == id)),
      do: {:error, :manager_integration_workspace_not_isolated},
      else: :ok
  end

  defp separate_workspace(_workspace, _children),
    do: {:error, :manager_integration_workspace_invalid}

  defp apply_handoffs(workspace, children, opts) do
    case Keyword.get(opts, :artifact_applier) do
      applier when is_function(applier, 2) -> applier.(workspace, children)
      nil -> {:error, :manager_artifact_applier_required}
    end
  end
end
