defmodule Twelvgaige.Lifecycle.FaultMatrixTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Lifecycle.FaultMatrix
  alias Twelvgaige.Workspace.Operation

  test "enumerates a unique before and after case for every declared boundary" do
    cases = FaultMatrix.cases()
    ids = Enum.map(cases, & &1.id)

    assert length(ids) == MapSet.size(MapSet.new(ids))
    assert MapSet.new(ids) == FaultMatrix.case_ids()

    assert Map.keys(FaultMatrix.lifecycles()) |> MapSet.new() ==
             MapSet.new([
               :capture,
               :cleanup,
               :create,
               :direct_apply,
               :export,
               :finalize,
               :reconcile,
               :retention_cleanup,
               :review_apply,
               :review_cleanup,
               :sandbox_resource_cleanup
             ])

    Enum.each(FaultMatrix.lifecycles(), fn {lifecycle, boundaries} ->
      Enum.each(boundaries, fn boundary ->
        assert "#{lifecycle}.#{boundary}.before" in ids
        assert "#{lifecycle}.#{boundary}.after" in ids
      end)
    end)
  end

  test "around invokes the same production checkpoint contract used by fault injection" do
    parent = self()

    opts = [
      fault_checkpoint_fun: fn event ->
        send(parent, {:checkpoint, event})
        :ok
      end
    ]

    assert {:ok, :value} =
             FaultMatrix.around(opts, :export, :export_publish, %{workspace_id: "ws_test"}, fn ->
               {:ok, :value}
             end)

    assert_receive {:checkpoint, before}
    assert before.id == "export.export_publish.before"
    assert before.position == :before
    refute Map.has_key?(before.metadata, :outcome)

    assert_receive {:checkpoint, after_event}
    assert after_event.id == "export.export_publish.after"
    assert after_event.position == :after
    assert after_event.metadata.outcome == :ok
  end

  test "unknown boundaries and callback failures fail closed" do
    assert {:error, {:fault_matrix_boundary_unknown, :export, :not_registered}} =
             FaultMatrix.checkpoint([], :export, :not_registered, :before)

    opts = [fault_checkpoint_fun: fn _event -> {:error, :simulated_termination} end]

    assert {:error,
            {:fault_checkpoint_failed, "export.export_publish.before", :simulated_termination}} =
             FaultMatrix.around(opts, :export, :export_publish, fn -> :ok end)
  end

  test "durable operation kinds and phases map to registered lifecycle cases" do
    operations = [
      Operation.new(:create, "ws_test", %{}, request_id: "req_create"),
      Operation.new(:finalize, "ws_test", %{}, request_id: "req_finalize"),
      Operation.new(:export, "ws_test", %{}, request_id: "req_export"),
      Operation.new(:apply_review, "ws_test", %{}, request_id: "req_review"),
      Operation.new(:apply_current, "ws_test", %{}, request_id: "req_direct"),
      Operation.new(:reconcile, "ws_test", %{}, request_id: "req_reconcile"),
      Operation.new(:cleanup_review, "ws_test", %{}, request_id: "req_cleanup_review"),
      Operation.new(:cleanup, "ws_test", %{}, request_id: "req_cleanup"),
      Operation.new(:cleanup, "ws_test", %{}, request_id: "req_retention_test")
    ]

    assert Enum.map(operations, &FaultMatrix.operation_lifecycle/1) == [
             :create,
             :finalize,
             :export,
             :review_apply,
             :direct_apply,
             :reconcile,
             :review_cleanup,
             :cleanup,
             :retention_cleanup
           ]

    for operation <- operations,
        status <- [
          :intent_recorded,
          :side_effects_started,
          :completed,
          :failed,
          :needs_reconciliation
        ] do
      operation = Operation.transition(operation, status)
      lifecycle = FaultMatrix.operation_lifecycle(operation)
      boundary = FaultMatrix.operation_boundary(operation)

      assert FaultMatrix.checkpoint([], lifecycle, boundary, :before) == :ok
      assert FaultMatrix.checkpoint([], lifecycle, boundary, :after) == :ok
    end
  end
end
