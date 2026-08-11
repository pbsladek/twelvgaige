defmodule Twelvgaige.Lifecycle.FaultMatrix do
  @moduledoc """
  Authoritative lifecycle interruption boundaries.

  Production code calls `checkpoint/5` immediately before and after each
  listed durable transition or externally visible side effect. Qualification
  injects process termination through the same callback; ordinary execution
  has no callback and pays only the boundary validation cost.
  """

  @schema_version 1
  @positions [:before, :after]

  @common_operation_boundaries [
    :intent_persist,
    :side_effects_started_persist,
    :completed_persist,
    :failed_persist,
    :needs_reconciliation_persist
  ]

  @lifecycle_boundaries %{
    create: @common_operation_boundaries ++ [:workspace_materialize, :workspace_record_persist],
    capture: [:result_tree_capture, :commit_bundle_capture],
    finalize: @common_operation_boundaries ++ [:artifact_publish, :workspace_record_persist],
    export:
      @common_operation_boundaries ++ [:export_stage, :export_publish, :workspace_record_persist],
    review_apply:
      @common_operation_boundaries ++
        [
          :review_registration,
          :review_patch_apply,
          :review_result_verify,
          :workspace_record_persist
        ],
    direct_apply:
      @common_operation_boundaries ++
        [
          :backup_publish,
          :current_worktree_patch_apply,
          :current_worktree_result_verify,
          :workspace_record_persist
        ],
    reconcile:
      @common_operation_boundaries ++
        [
          :backup_restore,
          :export_resume,
          :cleanup_resume,
          :review_discard,
          :workspace_record_persist,
          :interrupted_operation_resolve
        ],
    review_cleanup:
      @common_operation_boundaries ++ [:review_registration_remove, :workspace_record_persist],
    retention_cleanup:
      @common_operation_boundaries ++ [:managed_path_remove, :workspace_record_persist],
    cleanup: @common_operation_boundaries ++ [:managed_path_remove, :workspace_record_persist],
    sandbox_resource_cleanup: [
      :resource_intent_persist,
      :admission_reserve,
      :creation_intent_persist,
      :completion_intent_persist,
      :credential_revoke,
      :egress_revoke,
      :boundary_revoke,
      :worker_stop,
      :quiescence_persist,
      :workspace_export,
      :workspace_export_persist,
      :worker_destroy,
      :boundary_destroy,
      :admission_release,
      :resource_record_delete
    ]
  }

  @type lifecycle :: atom()
  @type boundary :: atom()
  @type position :: :before | :after

  def schema_version, do: @schema_version

  def lifecycles, do: @lifecycle_boundaries

  def cases do
    for {lifecycle, boundaries} <- Enum.sort(@lifecycle_boundaries),
        boundary <- boundaries,
        position <- @positions do
      %{
        id: case_id(lifecycle, boundary, position),
        lifecycle: lifecycle,
        boundary: boundary,
        position: position,
        schema_version: @schema_version
      }
    end
  end

  def case_ids, do: MapSet.new(cases(), & &1.id)

  def case_id(lifecycle, boundary, position)
      when is_atom(lifecycle) and is_atom(boundary) and position in @positions do
    Enum.join([lifecycle, boundary, position], ".")
  end

  def operation_lifecycle(%{kind: :cleanup, request_id: "req_retention_" <> _rest}),
    do: :retention_cleanup

  def operation_lifecycle(%{kind: :create}), do: :create
  def operation_lifecycle(%{kind: :finalize}), do: :finalize
  def operation_lifecycle(%{kind: :export}), do: :export
  def operation_lifecycle(%{kind: :apply_review}), do: :review_apply
  def operation_lifecycle(%{kind: :apply_current}), do: :direct_apply
  def operation_lifecycle(%{kind: :reconcile}), do: :reconcile
  def operation_lifecycle(%{kind: :cleanup_review}), do: :review_cleanup
  def operation_lifecycle(%{kind: :cleanup}), do: :cleanup
  def operation_lifecycle(_operation), do: nil

  def operation_boundary(%{status: :intent_recorded}), do: :intent_persist
  def operation_boundary(%{status: :side_effects_started}), do: :side_effects_started_persist
  def operation_boundary(%{status: :completed}), do: :completed_persist
  def operation_boundary(%{status: :failed}), do: :failed_persist
  def operation_boundary(%{status: :needs_reconciliation}), do: :needs_reconciliation_persist
  def operation_boundary(_operation), do: nil

  def checkpoint(opts, lifecycle, boundary, position, metadata \\ %{})
      when is_list(opts) and is_atom(lifecycle) and is_atom(boundary) and
             position in @positions and is_map(metadata) do
    with :ok <- known_boundary(lifecycle, boundary) do
      event = %{
        id: case_id(lifecycle, boundary, position),
        schema_version: @schema_version,
        lifecycle: lifecycle,
        boundary: boundary,
        position: position,
        metadata: metadata
      }

      invoke(Keyword.get(opts, :fault_checkpoint_fun), event)
    end
  end

  def around(opts, lifecycle, boundary, metadata \\ %{}, fun)
      when is_function(fun, 0) do
    with :ok <- checkpoint(opts, lifecycle, boundary, :before, metadata) do
      result = fun.()

      case checkpoint(opts, lifecycle, boundary, :after, outcome_metadata(metadata, result)) do
        :ok -> result
        {:error, _reason} = error -> error
      end
    end
  end

  defp known_boundary(lifecycle, boundary) do
    case Map.fetch(@lifecycle_boundaries, lifecycle) do
      {:ok, boundaries} ->
        if boundary in boundaries,
          do: :ok,
          else: {:error, {:fault_matrix_boundary_unknown, lifecycle, boundary}}

      :error ->
        {:error, {:fault_matrix_lifecycle_unknown, lifecycle}}
    end
  end

  defp invoke(nil, _event), do: :ok

  defp invoke(fun, event) when is_function(fun, 1) do
    case fun.(event) do
      :ok -> :ok
      {:error, reason} -> {:error, {:fault_checkpoint_failed, event.id, reason}}
      other -> {:error, {:fault_checkpoint_invalid_result, event.id, other}}
    end
  end

  defp outcome_metadata(metadata, result) do
    Map.put(metadata, :outcome, if(success?(result), do: :ok, else: :error))
  end

  defp success?(:ok), do: true
  defp success?({:ok, _value}), do: true
  defp success?({:ok, _first, _second}), do: true
  defp success?({:ok, _first, _second, _third}), do: true
  defp success?(_result), do: false
end
