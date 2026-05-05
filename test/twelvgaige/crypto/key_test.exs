defmodule Twelvgaige.Crypto.KeyTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyMaterial

  test "key material requires at least 32 bytes" do
    assert {:error, :invalid_key_material} = KeyMaterial.new("too-short")
    assert {:error, :invalid_key_material} = KeyMaterial.new(:not_binary)

    assert {:ok, %KeyMaterial{bytes: bytes}} = KeyMaterial.new(String.duplicate("k", 32))
    assert byte_size(bytes) == 32
  end

  test "key metadata serializes without raw material" do
    created_at = ~U[2026-05-04 00:00:00Z]
    rotated_at = ~U[2026-05-05 00:00:00Z]
    {:ok, material} = KeyMaterial.new(String.duplicate("s", 32))

    metadata =
      %Key{
        id: "round-store",
        backend: :macos_keychain,
        status: :active,
        version: 3,
        material: material,
        created_at: created_at,
        rotated_at: rotated_at,
        metadata: %{"service" => "twelvgaige.test"}
      }
      |> Key.to_metadata()

    assert metadata == %{
             "id" => "round-store",
             "backend" => "macos_keychain",
             "status" => "active",
             "version" => 3,
             "created_at" => "2026-05-04T00:00:00Z",
             "rotated_at" => "2026-05-05T00:00:00Z",
             "retired_at" => nil,
             "metadata" => %{"service" => "twelvgaige.test"}
           }

    refute inspect(metadata) =~ material.bytes
  end

  test "key inspect output redacts material" do
    secret = String.duplicate("z", 32)
    {:ok, material} = KeyMaterial.new(secret)

    key = %Key{
      id: "inspect-key",
      backend: :file,
      status: :retired,
      version: 1,
      material: material
    }

    assert inspect(material) == "#Twelvgaige.Crypto.KeyMaterial<[REDACTED]>"

    assert inspect(key) ==
             "#Twelvgaige.Crypto.Key<inspect-key backend=file status=retired material=[REDACTED]>"

    refute inspect(key) =~ secret
  end
end
