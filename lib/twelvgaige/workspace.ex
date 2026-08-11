defmodule Twelvgaige.Workspace do
  @moduledoc "Immutable identity and lifecycle record for a delegated-session workspace."

  @transports [:bind_worktree, :copy_snapshot]

  @enforce_keys [
    :id,
    :repository,
    :base_ref,
    :base_commit,
    :transport,
    :path,
    :writable,
    :created_at
  ]
  defstruct [
    :id,
    :round_id,
    :shot_id,
    :attempt,
    :repository,
    :base_ref,
    :base_commit,
    :source_mode,
    :source_manifest,
    :input_tree,
    :transport,
    :path,
    :branch,
    :head_commit,
    :workspace_baseline_commit,
    :owner_session_id,
    :created_at,
    :finalized_at,
    :quiescence_evidence,
    :quarantine_reason,
    :result_manifest,
    :result_artifact_ref,
    :creation_operation_id,
    :last_operation_id,
    :storage_reservation,
    :retention_expires_at,
    state: :ready,
    control_epoch: 0,
    writable: true,
    dirty: false,
    allowed_paths: [],
    read_only_references: [],
    artifact_refs: [],
    retention: :raw,
    schema_version: 2,
    encoding_version: 1
  ]

  @type transport :: :bind_worktree | :copy_snapshot
  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    transport = value(attrs, :transport, :copy_snapshot)
    if transport not in @transports, do: raise(ArgumentError, "unsupported workspace transport")

    %__MODULE__{
      id: required!(attrs, :id),
      round_id: value(attrs, :round_id),
      shot_id: value(attrs, :shot_id),
      attempt: value(attrs, :attempt),
      repository: required!(attrs, :repository) |> Path.expand(),
      base_ref: required!(attrs, :base_ref),
      base_commit: required!(attrs, :base_commit),
      source_mode: value(attrs, :source_mode, :committed),
      source_manifest: value(attrs, :source_manifest),
      input_tree: value(attrs, :input_tree),
      transport: transport,
      path: required!(attrs, :path) |> Path.expand(),
      branch: value(attrs, :branch),
      head_commit: value(attrs, :head_commit),
      workspace_baseline_commit:
        value(attrs, :workspace_baseline_commit, required!(attrs, :base_commit)),
      owner_session_id: value(attrs, :owner_session_id),
      created_at: required!(attrs, :created_at),
      finalized_at: value(attrs, :finalized_at),
      quiescence_evidence: value(attrs, :quiescence_evidence),
      quarantine_reason: value(attrs, :quarantine_reason),
      result_manifest: value(attrs, :result_manifest),
      result_artifact_ref: value(attrs, :result_artifact_ref),
      creation_operation_id: value(attrs, :creation_operation_id),
      last_operation_id: value(attrs, :last_operation_id),
      storage_reservation: value(attrs, :storage_reservation),
      retention_expires_at: value(attrs, :retention_expires_at),
      state: value(attrs, :state, :ready),
      control_epoch: value(attrs, :control_epoch, 0),
      writable: value(attrs, :writable, true),
      dirty: value(attrs, :dirty, false),
      allowed_paths: value(attrs, :allowed_paths, []),
      read_only_references: value(attrs, :read_only_references, []),
      artifact_refs: value(attrs, :artifact_refs, []),
      retention: value(attrs, :retention, :raw),
      schema_version: value(attrs, :schema_version, 2),
      encoding_version: value(attrs, :encoding_version, 1)
    }
  end

  defp required!(attrs, key) do
    case value(attrs, key, :missing) do
      :missing -> raise ArgumentError, "missing workspace field #{key}"
      value -> value
    end
  end

  defp value(attrs, key, default \\ nil)
  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default) when is_map(attrs),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
