defmodule Twelvgaige.Workspace.Set do
  @moduledoc "Cross-repository workspace identity and commit provenance."

  @enforce_keys [:id, :owner_session_id, :repositories, :created_at]
  defstruct [
    :id,
    :owner_session_id,
    :repositories,
    :created_at,
    :finalized_at,
    schema_version: 1
  ]

  def input_commits(%__MODULE__{} = set) do
    Map.new(set.repositories, fn {name, workspace} -> {name, workspace.base_commit} end)
  end

  def output_commits(%__MODULE__{} = set) do
    Map.new(set.repositories, fn {name, workspace} -> {name, workspace.head_commit} end)
  end
end
