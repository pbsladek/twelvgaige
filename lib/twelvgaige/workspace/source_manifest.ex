defmodule Twelvgaige.Workspace.SourceManifest do
  @moduledoc "Canonical description of the exact source state admitted to a workspace."

  alias Twelvgaige.Workspace.Canonical

  @schema_version 1
  @encoding_version 1
  @modes [:committed, :staged, :working_tree]

  @enforce_keys [
    :repository_identity,
    :base_commit,
    :base_tree,
    :source_mode,
    :input_tree,
    :workspace_baseline_commit,
    :overlay_entries,
    :source_state_token,
    :manifest_digest
  ]
  defstruct [
    :repository_identity,
    :base_commit,
    :base_tree,
    :source_mode,
    :input_tree,
    :workspace_baseline_commit,
    :overlay_entries,
    :source_state_token,
    :manifest_digest,
    exclusions: [],
    limits: %{},
    include_untracked: false,
    include_ignored: false,
    schema_version: @schema_version,
    encoding_version: @encoding_version,
    digest_algorithm: "sha256"
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    source_mode = value(attrs, :source_mode, :committed)
    overlay_entries = value(attrs, :overlay_entries, [])

    with true <- source_mode in @modes,
         true <- is_list(overlay_entries),
         {:ok, base_commit} <- oid(attrs, :base_commit),
         {:ok, base_tree} <- oid(attrs, :base_tree),
         {:ok, input_tree} <- oid(attrs, :input_tree),
         {:ok, workspace_baseline} <- oid(attrs, :workspace_baseline_commit),
         {:ok, source_state_token} <- binary(attrs, :source_state_token),
         repository_identity when is_map(repository_identity) <-
           value(attrs, :repository_identity),
         payload <- %{
           "schema_version" => @schema_version,
           "encoding_version" => @encoding_version,
           "digest_algorithm" => "sha256",
           "repository_identity" => repository_identity,
           "base_commit" => base_commit,
           "base_tree" => base_tree,
           "source_mode" => Atom.to_string(source_mode),
           "input_tree" => input_tree,
           "workspace_baseline_commit" => workspace_baseline,
           "overlay_entries" => overlay_entries,
           "source_state_token" => source_state_token,
           "exclusions" => value(attrs, :exclusions, []),
           "limits" => value(attrs, :limits, %{}),
           "include_untracked" => value(attrs, :include_untracked, false),
           "include_ignored" => value(attrs, :include_ignored, false)
         },
         {:ok, manifest_digest} <- Canonical.digest("source-manifest", @encoding_version, payload) do
      {:ok,
       %__MODULE__{
         repository_identity: repository_identity,
         base_commit: base_commit,
         base_tree: base_tree,
         source_mode: source_mode,
         input_tree: input_tree,
         workspace_baseline_commit: workspace_baseline,
         overlay_entries: overlay_entries,
         source_state_token: source_state_token,
         exclusions: value(attrs, :exclusions, []),
         limits: value(attrs, :limits, %{}),
         include_untracked: value(attrs, :include_untracked, false),
         include_ignored: value(attrs, :include_ignored, false),
         manifest_digest: manifest_digest
       }}
    else
      false -> {:error, :source_manifest_invalid}
      nil -> {:error, :source_manifest_invalid}
      {:error, _reason} = error -> error
      _invalid -> {:error, :source_manifest_invalid}
    end
  end

  defp oid(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) and byte_size(value) in [40, 64] -> {:ok, value}
      _value -> {:error, {:source_manifest_field_invalid, key}}
    end
  end

  defp binary(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:source_manifest_field_invalid, key}}
    end
  end

  defp value(attrs, key, default \\ nil)
  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default) when is_map(attrs),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
