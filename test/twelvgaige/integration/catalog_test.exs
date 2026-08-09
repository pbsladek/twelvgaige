defmodule Twelvgaige.Integration.CatalogTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Integration.Catalog
  alias Twelvgaige.Integration.Descriptor

  test "admits support states and capabilities deterministically" do
    supported = descriptor("supported", :supported)
    deprecated = descriptor("deprecated", :deprecated)
    experimental = descriptor("experimental", :experimental)
    blocked = descriptor("blocked", :blocked)
    descriptors = [supported, deprecated, experimental, blocked]

    assert {:ok, ^supported} =
             Catalog.resolve(descriptors, "supported", required_capabilities: [:resume])

    assert {:error, {:integration_capability_missing, [:fork]}} =
             Catalog.resolve(descriptors, "supported", required_capabilities: [:fork])

    assert {:error, :deprecated_integration_new_work} =
             Catalog.resolve(descriptors, "deprecated")

    assert {:ok, ^deprecated} = Catalog.resolve(descriptors, "deprecated", resume?: true)

    assert {:error, :experimental_integration_unattended} =
             Catalog.resolve(descriptors, "experimental")

    assert {:ok, ^experimental} = Catalog.resolve(descriptors, "experimental", unattended?: false)
    assert {:error, {:integration_blocked, :blocked}} = Catalog.resolve(descriptors, "blocked")
  end

  defp descriptor(id, status) do
    Descriptor.new(%{
      id: id,
      kind: :agent_runtime,
      vendor: "test",
      product: id,
      adapter: "mock",
      adapter_version: "1",
      artifact_version: "1",
      artifact_digest: String.duplicate("a", 64),
      protocol_version: "1",
      schema_digest: String.duplicate("b", 64),
      support_status: status,
      catalog_revision: "catalog-1",
      capabilities: %{resume: true}
    })
  end
end
