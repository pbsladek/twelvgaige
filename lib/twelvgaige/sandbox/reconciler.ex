defmodule Twelvgaige.Sandbox.Reconciler do
  @moduledoc "Classifies durable sandbox resources as resumable, missing, or quarantined."

  def reconcile(records, backend, opts \\ []) when is_map(records) do
    Map.new(records, fn {resource_id, record} ->
      durable = %{resource_id: resource_id, manifest: record.manifest}

      decision =
        case backend.reconcile(durable, opts) do
          {:ok, status, observed} when status in [:resume, :missing, :quarantine] ->
            %{status: status, observed: observed}

          {:error, reason} ->
            %{status: :quarantine, reason: reason}

          other ->
            %{status: :quarantine, reason: {:invalid_reconciliation_response, other}}
        end

      {resource_id, decision}
    end)
  end

  def classify_unknown(resource_ids, known_records) do
    resource_ids
    |> Enum.reject(&Map.has_key?(known_records, &1))
    |> Map.new(&{&1, %{status: :quarantine, reason: :unknown_managed_resource}})
  end
end
