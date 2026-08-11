defmodule Twelvgaige.Workspace.ResultManifest do
  @moduledoc "Versioned, digest-bound description of one finalized workspace tree."

  alias Twelvgaige.Workspace.Canonical

  @schema_version 2
  @encoding_version 1

  @enforce_keys [
    :workspace_id,
    :source_base_commit,
    :workspace_baseline_commit,
    :result_tree,
    :changed_paths,
    :patch_digest,
    :patch_bytes,
    :bundle_digest,
    :bundle_bytes,
    :no_change,
    :outcomes,
    :created_at,
    :manifest_digest
  ]
  defstruct [
    :workspace_id,
    :source_base_commit,
    :workspace_baseline_commit,
    :result_tree,
    :result_commit,
    :changed_paths,
    :patch_digest,
    :patch_bytes,
    :bundle_digest,
    :bundle_bytes,
    :no_change,
    :outcomes,
    :created_at,
    :manifest_digest,
    out_of_policy: [],
    artifact_ref: nil,
    schema_version: @schema_version,
    encoding_version: @encoding_version,
    digest_algorithm: "sha256"
  ]

  @type t :: %__MODULE__{}

  @spec new(keyword() | map()) :: {:ok, t()} | {:error, term()}
  def new(attrs) do
    with {:ok, workspace_id} <- required_binary(attrs, :workspace_id),
         {:ok, source_base} <- required_oid(attrs, :source_base_commit),
         {:ok, workspace_baseline} <- required_oid(attrs, :workspace_baseline_commit),
         {:ok, result_tree} <- required_oid(attrs, :result_tree),
         {:ok, changed_paths} <- changed_paths(value(attrs, :changed_paths, [])),
         {:ok, patch} <- required_binary_allow_empty(attrs, :patch),
         {:ok, patch_digest} <- Canonical.digest_bytes("result-patch", 1, patch),
         {:ok, _bundle, bundle_digest, bundle_bytes} <- bundle(attrs),
         {:ok, out_of_policy} <- changed_paths(value(attrs, :out_of_policy, [])),
         {:ok, outcomes} <- outcomes(value(attrs, :outcomes, %{})),
         {:ok, created_at} <- created_at(value(attrs, :created_at, Twelvgaige.Clock.utc_now())),
         result_commit <- optional_binary(attrs, :result_commit),
         no_change <- value(attrs, :no_change, changed_paths == []),
         true <- is_boolean(no_change),
         payload <-
           payload(%{
             schema_version: @schema_version,
             workspace_id: workspace_id,
             source_base_commit: source_base,
             workspace_baseline_commit: workspace_baseline,
             result_tree: result_tree,
             result_commit: result_commit,
             changed_paths: changed_paths,
             patch_digest: patch_digest,
             patch_bytes: byte_size(patch),
             bundle_digest: bundle_digest,
             bundle_bytes: bundle_bytes,
             no_change: no_change,
             outcomes: outcomes,
             out_of_policy: out_of_policy
           }),
         {:ok, manifest_digest} <- Canonical.digest("result-manifest", @encoding_version, payload) do
      {:ok,
       %__MODULE__{
         workspace_id: workspace_id,
         source_base_commit: source_base,
         workspace_baseline_commit: workspace_baseline,
         result_tree: result_tree,
         result_commit: result_commit,
         changed_paths: changed_paths,
         patch_digest: patch_digest,
         patch_bytes: byte_size(patch),
         bundle_digest: bundle_digest,
         bundle_bytes: bundle_bytes,
         no_change: no_change,
         outcomes: outcomes,
         out_of_policy: out_of_policy,
         created_at: created_at,
         manifest_digest: manifest_digest
       }}
    else
      false -> {:error, {:result_manifest_field_invalid, :no_change}}
      {:error, _reason} = error -> error
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = manifest) do
    manifest
    |> Map.from_struct()
    |> Map.update!(:created_at, &DateTime.to_iso8601/1)
  end

  @spec payload(t() | map()) :: map()
  def payload(%__MODULE__{} = manifest), do: manifest |> Map.from_struct() |> payload()

  def payload(manifest) when is_map(manifest) do
    schema_version = value(manifest, :schema_version, 1)

    base = %{
      "schema_version" => schema_version,
      "encoding_version" => @encoding_version,
      "digest_algorithm" => "sha256",
      "workspace_id" => value(manifest, :workspace_id),
      "source_base_commit" => value(manifest, :source_base_commit),
      "workspace_baseline_commit" => value(manifest, :workspace_baseline_commit),
      "result_tree" => value(manifest, :result_tree),
      "result_commit" => value(manifest, :result_commit),
      "changed_paths" => value(manifest, :changed_paths, []),
      "patch_digest" => value(manifest, :patch_digest),
      "patch_bytes" => value(manifest, :patch_bytes),
      "no_change" => value(manifest, :no_change),
      "outcomes" => value(manifest, :outcomes),
      "out_of_policy" => value(manifest, :out_of_policy, [])
    }

    case schema_version do
      1 ->
        base

      2 ->
        Map.merge(base, %{
          "bundle_digest" => value(manifest, :bundle_digest),
          "bundle_bytes" => value(manifest, :bundle_bytes)
        })

      _unsupported ->
        raise ArgumentError, "result manifest schema version is unsupported"
    end
  end

  defp outcomes(value) when is_map(value) do
    defaults = %{
      "agent_execution" => "completed",
      "result_capture" => "complete",
      "artifact_integrity" => "verified",
      "test_verification" => "not_run",
      "policy_compliance" => "compliant",
      "workspace_disposition" => "reviewable"
    }

    normalized = Map.new(value, fn {key, child} -> {to_string(key), to_string(child)} end)
    {:ok, Map.merge(defaults, normalized)}
  end

  defp outcomes(_value), do: {:error, :result_manifest_outcomes_invalid}

  defp changed_paths(paths) when is_list(paths) do
    if Enum.all?(paths, &is_map/1),
      do: {:ok, Enum.sort_by(paths, &path_sort_key/1)},
      else: {:error, :result_manifest_changed_paths_invalid}
  end

  defp changed_paths(_paths), do: {:error, :result_manifest_changed_paths_invalid}

  defp path_sort_key(path) do
    encoded = value(path, :path, value(path, :new_path, value(path, :old_path, %{})))

    case Canonical.decode_path(encoded) do
      {:ok, raw} -> raw
      {:error, _reason} -> raise ArgumentError, "result manifest path is invalid"
    end
  end

  defp required_binary(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _value -> {:error, {:result_manifest_field_invalid, key}}
    end
  end

  defp required_binary_allow_empty(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:result_manifest_field_invalid, key}}
    end
  end

  defp bundle(attrs) do
    case value(attrs, :bundle) do
      nil ->
        {:ok, nil, nil, nil}

      bundle when is_binary(bundle) ->
        with {:ok, digest} <- Canonical.digest_bytes("result-bundle", 1, bundle) do
          {:ok, bundle, digest, byte_size(bundle)}
        end

      _invalid ->
        {:error, {:result_manifest_field_invalid, :bundle}}
    end
  end

  defp required_oid(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) and byte_size(value) in [40, 64] -> {:ok, value}
      _value -> {:error, {:result_manifest_field_invalid, key}}
    end
  end

  defp optional_binary(attrs, key) do
    case value(attrs, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp created_at(%DateTime{} = value), do: {:ok, value}
  defp created_at(_value), do: {:error, {:result_manifest_field_invalid, :created_at}}

  defp value(attrs, key, default \\ nil)
  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default) when is_map(attrs),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
