defmodule Twelvgaige.Manager.ChildFactory do
  @moduledoc "Allocates a distinct workspace and delegated-session identity for each governed child."

  alias Twelvgaige.Manager.ChildRecord
  alias Twelvgaige.Workspace.Manager, as: WorkspaceManager

  def prepare(%ChildRecord{} = child, opts \\ []) do
    session_id = child.delegated_session_id || delegated_session_id(child.id)
    workspace_id = child.workspace_id || workspace_id(child.id)
    child = %{child | delegated_session_id: session_id, workspace_id: workspace_id}

    with {:ok, workspace} <- resolve_or_allocate_workspace(child, opts),
         {:ok, workspace} <- bind_workspace(workspace, session_id, opts) do
      {:ok, %{child | delegated_session_id: session_id, workspace_id: workspace.id}}
    end
  end

  @doc "Returns the stable delegated-session identity reserved for a manager child."
  def delegated_session_id(child_id) when is_binary(child_id),
    do: deterministic_id(:session, child_id)

  @doc "Returns the stable workspace identity reserved for a manager child."
  def workspace_id(child_id) when is_binary(child_id),
    do: deterministic_id(:workspace, child_id)

  defp resolve_or_allocate_workspace(%{workspace_id: workspace_id} = child, opts)
       when is_binary(workspace_id) do
    result =
      case Keyword.get(opts, :workspace_resolver) do
        resolver when is_function(resolver, 1) ->
          resolver.(workspace_id)

        nil ->
          WorkspaceManager.get(workspace_id,
            server: Keyword.get(opts, :workspace_manager, WorkspaceManager)
          )
      end

    case result do
      {:ok, workspace} ->
        {:ok, workspace}

      {:error, reason} when reason in [:not_found, :workspace_not_found] ->
        allocate_workspace(child, opts)

      other ->
        other
    end
  end

  defp allocate_workspace(child, opts) do
    case Keyword.get(opts, :workspace_allocator) do
      allocator when is_function(allocator, 1) ->
        allocator.(child)

      nil ->
        WorkspaceManager.create(child.task.repository,
          server: Keyword.get(opts, :workspace_manager, WorkspaceManager),
          workspace_id: child.workspace_id,
          transport: Keyword.get(opts, :workspace_transport, :copy_snapshot),
          interactive?: false,
          base_ref: child.task.base_ref,
          source_mode: child.task.source_mode || :committed,
          expected_source_state_token: child.task.source_state_token,
          include_untracked: child.task.include_untracked || false,
          include_ignored: child.task.include_ignored || false,
          round_id: child.round_id,
          shot_id: child.shot_id,
          attempt: child.attempt,
          writable: child.task.write,
          allowed_paths: child.task.allowed_paths
        )
    end
  end

  defp deterministic_id(kind, child_id) do
    suffix =
      :crypto.hash(:sha256, :erlang.term_to_binary({kind, child_id}))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 20)

    Twelvgaige.ID.prefix_slug(kind) <> "_" <> suffix
  end

  defp bind_workspace(workspace, session_id, opts) do
    case Keyword.get(opts, :workspace_binder) do
      binder when is_function(binder, 2) ->
        binder.(workspace, session_id)

      nil ->
        WorkspaceManager.bind_owner(workspace.id, session_id,
          server: Keyword.get(opts, :workspace_manager, WorkspaceManager)
        )
    end
  end
end
