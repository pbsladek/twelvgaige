defmodule Twelvgaige.Sandbox.ImageTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Sandbox.Image

  test "requires pinned, signed, scanned images and marks explicit custom images unsupported" do
    image = %Image{
      reference: "registry.example/worker",
      digest: "sha256:" <> String.duplicate("a", 64),
      provenance: %{builder: "ci"},
      sbom_digest: String.duplicate("b", 64),
      vulnerability_result: :pass,
      signature_verified: true,
      support_status: :supported,
      catalog_revision: "catalog-1"
    }

    assert :ok = Image.admit(image)
    assert {:error, :image_revoked} = Image.admit(%{image | revoked_at: DateTime.utc_now()})

    custom = %{image | support_status: :experimental, custom?: true}
    assert {:error, :image_not_supported} = Image.admit(custom)
    assert {:ok, :unsupported_custom} = Image.admit(custom, allow_custom?: true)
  end
end
