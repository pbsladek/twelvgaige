defmodule Twelvgaige.Integration.Descriptor do
  @moduledoc "Pinned, revisioned identity for an admitted runtime or external integration."

  @statuses [:experimental, :supported, :deprecated, :blocked, :removed]

  @enforce_keys [
    :id,
    :kind,
    :vendor,
    :product,
    :adapter,
    :adapter_version,
    :artifact_version,
    :artifact_digest,
    :protocol_version,
    :schema_digest,
    :support_status,
    :catalog_revision
  ]
  defstruct [
    :id,
    :kind,
    :vendor,
    :product,
    :adapter,
    :adapter_version,
    :artifact_path,
    :artifact_version,
    :artifact_digest,
    :protocol_version,
    :schema_digest,
    :support_status,
    :license_or_terms_revision,
    :catalog_revision,
    :approved_at,
    :revoked_at,
    capabilities: %{},
    tested_platforms: [],
    auth_modes: [],
    endpoint_classes: [],
    data_regions: [],
    schema_version: 1,
    encoding_version: 1
  ]

  @type t :: %__MODULE__{}

  def new(attrs) do
    descriptor = struct!(__MODULE__, Map.new(attrs))

    cond do
      descriptor.support_status not in @statuses ->
        raise ArgumentError, "invalid integration support status"

      not digest?(descriptor.artifact_digest) or not digest?(descriptor.schema_digest) ->
        raise ArgumentError, "integration digests must be lowercase sha256 hex"

      true ->
        descriptor
    end
  end

  defp digest?(digest), do: is_binary(digest) and Regex.match?(~r/^[0-9a-f]{64}$/, digest)
end
