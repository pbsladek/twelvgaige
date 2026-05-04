defmodule Twelvgaige.Crypto.EnvelopeCipherTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Crypto.Envelope
  alias Twelvgaige.Crypto.EnvelopeCipher
  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyMaterial

  test "wraps and unwraps a DEK without exposing it in inspect output" do
    key = key("store-key", String.duplicate("a", 32), version: 1)
    dek = String.duplicate("d", 32)

    assert {:ok, %Envelope{} = envelope} =
             EnvelopeCipher.wrap_dek(dek, key, nonce: String.duplicate(<<1>>, 12))

    refute envelope.wrapped_dek == dek
    refute inspect(envelope) =~ dek
    assert envelope.metadata["key_version"] == 1

    assert {:ok, ^dek} = EnvelopeCipher.unwrap_dek(envelope, key)
  end

  test "rewrap rotates only the envelope and preserves the DEK" do
    old_key = key("store-key", String.duplicate("a", 32), version: 1)
    new_key = key("store-key", String.duplicate("b", 32), version: 2)
    dek = String.duplicate("d", 32)

    assert {:ok, old_envelope} =
             EnvelopeCipher.wrap_dek(dek, old_key, nonce: String.duplicate(<<1>>, 12))

    assert {:ok, new_envelope} =
             EnvelopeCipher.rewrap_dek(
               old_envelope,
               old_key,
               new_key,
               nonce: String.duplicate(<<2>>, 12)
             )

    refute new_envelope.wrapped_dek == old_envelope.wrapped_dek
    assert new_envelope.metadata["rotation"] == "rewrap"
    assert new_envelope.metadata["previous_key_version"] == 1
    assert {:ok, ^dek} = EnvelopeCipher.unwrap_dek(new_envelope, new_key)
  end

  test "failed rewrap leaves old envelope valid and returns a clear error" do
    old_key = key("store-key", String.duplicate("a", 32), version: 1)
    wrong_old_key = key("store-key", String.duplicate("x", 32), version: 1)
    new_key = key("store-key", String.duplicate("b", 32), version: 2)
    dek = String.duplicate("d", 32)

    assert {:ok, old_envelope} =
             EnvelopeCipher.wrap_dek(dek, old_key, nonce: String.duplicate(<<1>>, 12))

    assert {:error, :dek_unwrap_failed} =
             EnvelopeCipher.rewrap_dek(old_envelope, wrong_old_key, new_key)

    assert {:ok, ^dek} = EnvelopeCipher.unwrap_dek(old_envelope, old_key)
  end

  test "refuses mismatched or retired keys" do
    key = key("store-key", String.duplicate("a", 32), version: 1)
    other = key("other-key", String.duplicate("a", 32), version: 1)
    retired = %{key | status: :retired}
    dek = String.duplicate("d", 32)

    assert {:ok, envelope} = EnvelopeCipher.wrap_dek(dek, key)
    assert {:error, :envelope_key_mismatch} = EnvelopeCipher.unwrap_dek(envelope, other)
    assert {:error, :key_retired} = EnvelopeCipher.wrap_dek(dek, retired)
    assert {:error, :key_retired} = EnvelopeCipher.unwrap_dek(envelope, retired)
  end

  defp key(id, bytes, opts) do
    {:ok, material} = KeyMaterial.new(bytes)

    %Key{
      id: id,
      backend: :test,
      status: Keyword.get(opts, :status, :active),
      version: Keyword.fetch!(opts, :version),
      material: material
    }
  end
end
