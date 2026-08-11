defmodule Twelvgaige.Workspace.Result do
  @moduledoc "Loads and verifies a finalized workspace result artifact."

  alias Twelvgaige.Artifact.Store, as: ArtifactStore
  alias Twelvgaige.Lifecycle.FaultMatrix
  alias Twelvgaige.Workspace.{Canonical, ResultManifest}

  def load(%{state: :reviewable} = workspace, artifact_store) when not is_nil(artifact_store) do
    case Map.get(workspace, :result_artifact_ref) do
      nil ->
        {:error, :workspace_result_artifact_missing}

      ref ->
        with {:ok, payload} <- ArtifactStore.get(ref, server: artifact_store),
             {:ok, manifest, patch, bundle} <- payload_parts(payload),
             :ok <- verify_manifest(manifest, workspace.result_manifest),
             :ok <- verify_patch(patch, manifest),
             :ok <- verify_bundle(bundle, manifest) do
          {:ok, %{manifest: manifest, patch: patch, bundle: bundle, artifact_ref: ref}}
        else
          {:error, _reason} = error -> error
        end
    end
  end

  def load(%{state: state}, _artifact_store),
    do: {:error, {:workspace_result_not_reviewable, state}}

  def export(workspace, artifact_store, destination, opts \\ []) do
    destination = Path.expand(destination)
    write? = Keyword.get(opts, :write?, false)

    with {:ok, result} <- load(workspace, artifact_store),
         false <- File.exists?(destination) do
      report = export_report(workspace, destination, result, not write?)

      if write?, do: write_export(destination, result, report, opts), else: {:ok, report}
    else
      true -> {:error, :workspace_export_destination_exists}
      {:error, _reason} = error -> error
    end
  end

  @doc "Resumes or verifies an interrupted export at its exact recorded destination."
  def resume_export(workspace, artifact_store, destination, opts \\ []) do
    destination = Path.expand(destination)
    staging = staging_path(destination, Keyword.fetch!(opts, :request_id))

    with {:ok, result} <- load(Map.put(workspace, :state, :reviewable), artifact_store) do
      report = export_report(workspace, destination, result, false)

      cond do
        File.dir?(destination) ->
          with :ok <- verify_export_directory(destination, result) do
            {:ok, Map.put(report, :resumed, true)}
          end

        File.dir?(staging) ->
          with :ok <- verify_export_directory(staging, result),
               false <- File.exists?(destination),
               :ok <-
                 FaultMatrix.around(
                   opts,
                   :reconcile,
                   :export_resume,
                   lifecycle_metadata(report, opts),
                   fn -> File.rename(staging, destination) end
                 ) do
            {:ok, Map.put(report, :resumed, true)}
          else
            true -> {:error, :workspace_export_destination_exists}
            {:error, _reason} = error -> error
          end

        File.exists?(staging) ->
          {:error, :workspace_export_staging_invalid}

        true ->
          with {:ok, resumed} <- write_export(destination, result, report, opts) do
            {:ok, Map.put(resumed, :resumed, true)}
          end
      end
    end
  end

  defp write_export(destination, result, report, opts) do
    staging = staging_path(destination, Keyword.get(opts, :request_id, Twelvgaige.ID.new(:event)))
    metadata = lifecycle_metadata(report, opts)

    with false <- File.exists?(staging),
         :ok <-
           FaultMatrix.around(opts, :export, :export_stage, metadata, fn ->
             write_export_staging(staging, result)
           end),
         :ok <-
           FaultMatrix.around(opts, :export, :export_publish, metadata, fn ->
             File.rename(staging, destination)
           end) do
      {:ok, %{report | dry_run: false}}
    else
      true ->
        {:error, :workspace_export_staging_exists}

      {:error, reason} ->
        cleanup_export_staging(staging)
        {:error, {:workspace_export_failed, reason}}
    end
  end

  defp write_export_staging(staging, result) do
    manifest_path = Path.join(staging, "manifest.json")
    patch_path = Path.join(staging, "result.patch")
    bundle_path = Path.join(staging, "result.bundle")

    with :ok <- File.mkdir(staging),
         :ok <- File.chmod(staging, 0o700),
         {:ok, json} <- Jason.encode(result.manifest, pretty: true),
         :ok <- File.write(manifest_path, [json, "\n"], [:binary, :exclusive]),
         :ok <- File.chmod(manifest_path, 0o600),
         :ok <- File.write(patch_path, result.patch, [:binary, :exclusive]),
         :ok <- File.chmod(patch_path, 0o600),
         :ok <- write_bundle(bundle_path, result.bundle) do
      :ok
    end
  end

  def staging_path(destination, request_id) when is_binary(request_id) and request_id != "" do
    suffix =
      :crypto.hash(:sha256, request_id)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 20)

    Path.join(Path.dirname(destination), ".twelvgaige-export-#{suffix}")
  end

  defp verify_export_directory(directory, result) do
    manifest_path = Path.join(directory, "manifest.json")
    patch_path = Path.join(directory, "result.patch")
    bundle_path = Path.join(directory, "result.bundle")

    with {:ok, manifest_json} <- File.read(manifest_path),
         {:ok, manifest} <- Jason.decode(manifest_json),
         true <- field(manifest, :manifest_digest) == field(result.manifest, :manifest_digest),
         :ok <- verify_manifest(manifest, result.manifest),
         {:ok, patch} <- File.read(patch_path),
         true <- patch == result.patch,
         :ok <- verify_patch(patch, result.manifest),
         {:ok, bundle} <- read_export_bundle(bundle_path, result.bundle),
         :ok <- verify_bundle(bundle, result.manifest) do
      :ok
    else
      false -> {:error, :workspace_export_verification_failed}
      {:error, _reason} = error -> error
    end
  end

  defp read_export_bundle(_path, nil), do: {:ok, nil}
  defp read_export_bundle(path, _expected), do: File.read(path)

  defp export_report(workspace, destination, result, dry_run?) do
    %{
      workspace_id: workspace.id,
      destination: destination,
      patch_digest: field(result.manifest, :patch_digest),
      manifest_digest: field(result.manifest, :manifest_digest),
      patch_bytes: byte_size(result.patch),
      bundle_bytes: if(is_binary(result.bundle), do: byte_size(result.bundle), else: 0),
      files: export_files(result.bundle),
      dry_run: dry_run?
    }
  end

  defp cleanup_export_staging(staging) do
    case File.lstat(staging) do
      {:ok, %{type: :directory}} -> File.rm_rf(staging)
      {:error, :enoent} -> :ok
      _other -> :ok
    end
  end

  defp lifecycle_metadata(report, opts) do
    %{
      operation_id: Keyword.get(opts, :operation_id),
      request_id: Keyword.get(opts, :request_id),
      workspace_id: report.workspace_id
    }
  end

  defp payload_parts(%{manifest: manifest, patch: patch} = payload)
       when is_map(manifest) and is_binary(patch),
       do: {:ok, manifest, patch, Map.get(payload, :bundle)}

  defp payload_parts(%{"manifest" => manifest, "patch" => patch} = payload)
       when is_map(manifest) and is_binary(patch),
       do: {:ok, manifest, patch, Map.get(payload, "bundle")}

  defp payload_parts(_payload), do: {:error, :workspace_result_artifact_invalid}

  defp verify_manifest(manifest, expected) when is_map(manifest) and not is_nil(expected) do
    with expected_digest when is_binary(expected_digest) <- field(expected, :manifest_digest),
         ^expected_digest <- field(manifest, :manifest_digest),
         {:ok, actual_digest} <-
           Canonical.digest(
             "result-manifest",
             field(manifest, :encoding_version, 1),
             ResultManifest.payload(manifest)
           ),
         ^expected_digest <- actual_digest,
         [] <- field(manifest, :out_of_policy, []),
         "compliant" <- field(field(manifest, :outcomes, %{}), :policy_compliance) do
      :ok
    else
      _mismatch -> {:error, :workspace_result_manifest_verification_failed}
    end
  end

  defp verify_manifest(_manifest, _expected),
    do: {:error, :workspace_result_manifest_verification_failed}

  defp verify_patch(patch, manifest) do
    with {:ok, digest} <- Canonical.digest_bytes("result-patch", 1, patch),
         ^digest <- field(manifest, :patch_digest),
         size when size == byte_size(patch) <- field(manifest, :patch_bytes) do
      :ok
    else
      _mismatch -> {:error, :workspace_result_patch_verification_failed}
    end
  end

  defp verify_bundle(nil, manifest) do
    if is_nil(field(manifest, :bundle_digest)) and is_nil(field(manifest, :bundle_bytes)),
      do: :ok,
      else: {:error, :workspace_result_bundle_verification_failed}
  end

  defp verify_bundle(bundle, manifest) when is_binary(bundle) do
    with {:ok, digest} <- Canonical.digest_bytes("result-bundle", 1, bundle),
         ^digest <- field(manifest, :bundle_digest),
         size when size == byte_size(bundle) <- field(manifest, :bundle_bytes) do
      :ok
    else
      _mismatch -> {:error, :workspace_result_bundle_verification_failed}
    end
  end

  defp verify_bundle(_bundle, _manifest),
    do: {:error, :workspace_result_bundle_verification_failed}

  defp export_files(nil), do: ["manifest.json", "result.patch"]
  defp export_files(_bundle), do: ["manifest.json", "result.patch", "result.bundle"]

  defp write_bundle(_path, nil), do: :ok

  defp write_bundle(path, bundle) when is_binary(bundle) do
    with :ok <- File.write(path, bundle, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp field(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end
