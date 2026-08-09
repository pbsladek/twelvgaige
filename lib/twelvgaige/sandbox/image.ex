defmodule Twelvgaige.Sandbox.Image do
  @moduledoc "Supply-chain admission record for a sandbox worker image."

  @enforce_keys [
    :reference,
    :digest,
    :provenance,
    :sbom_digest,
    :vulnerability_result,
    :signature_verified,
    :support_status,
    :catalog_revision
  ]
  defstruct [
    :reference,
    :digest,
    :provenance,
    :sbom_digest,
    :vulnerability_result,
    :signature_verified,
    :support_status,
    :catalog_revision,
    :revoked_at,
    custom?: false,
    schema_version: 1,
    encoding_version: 1
  ]

  def admit(%__MODULE__{} = image, opts \\ []) do
    cond do
      not String.match?(image.digest, ~r/^sha256:[0-9a-f]{64}$/) ->
        {:error, :image_digest_invalid}

      not image.signature_verified ->
        {:error, :image_signature_unverified}

      not is_nil(image.revoked_at) ->
        {:error, :image_revoked}

      image.vulnerability_result not in [:pass, "pass"] ->
        {:error, :image_vulnerability_gate_failed}

      image.support_status == :supported ->
        :ok

      image.custom? and Keyword.get(opts, :allow_custom?, false) ->
        {:ok, :unsupported_custom}

      true ->
        {:error, :image_not_supported}
    end
  end
end
