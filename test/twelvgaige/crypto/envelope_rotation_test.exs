defmodule Twelvgaige.Crypto.EnvelopeRotationTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Crypto.EnvelopeCipher
  alias Twelvgaige.Crypto.EnvelopeFile
  alias Twelvgaige.Crypto.EnvelopeRotation
  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyMaterial

  test "rewraps an envelope file only after creating a backup" do
    root = tmp_dir!("twelvgaige_envelope_rotation")
    envelope_path = Path.join(root, "store-envelope.json")
    backup_path = Path.join(root, "store-envelope.backup.json")
    old_env = "TWELVGAIGE_OLD_REWRAP_KEY_#{System.unique_integer([:positive])}"
    new_env = "TWELVGAIGE_NEW_REWRAP_KEY_#{System.unique_integer([:positive])}"

    old_bytes = String.duplicate("a", 32)
    new_bytes = String.duplicate("b", 32)
    dek = String.duplicate("d", 32)

    System.put_env(old_env, "base64:" <> Base.encode64(old_bytes))
    System.put_env(new_env, "base64:" <> Base.encode64(new_bytes))

    on_exit(fn ->
      System.delete_env(old_env)
      System.delete_env(new_env)
    end)

    assert {:ok, envelope} =
             EnvelopeCipher.wrap_dek(dek, key("store-key", old_bytes, 1),
               nonce: String.duplicate(<<1>>, 12)
             )

    assert :ok = EnvelopeFile.write(envelope_path, envelope)

    assert {:ok,
            %{
              "status" => "ok",
              "mode" => "rewrap",
              "path" => ^envelope_path,
              "backup" => ^backup_path,
              "database_rekeyed" => false
            }} =
             EnvelopeRotation.rewrap_file(envelope_path,
               backup: backup_path,
               old_key_env: old_env,
               new_key_env: new_env
             )

    assert {:ok, old_envelope} = EnvelopeFile.read(backup_path)
    assert old_envelope.wrapped_dek == envelope.wrapped_dek

    assert {:ok, new_envelope} = EnvelopeFile.read(envelope_path)
    assert new_envelope.metadata["rotation"] == "rewrap"
    assert new_envelope.metadata["previous_key_id"] == "store-key"
    assert {:ok, ^dek} = EnvelopeCipher.unwrap_dek(new_envelope, key("store-key", new_bytes, 1))
  end

  test "failed rewrap leaves original envelope and backup intact" do
    root = tmp_dir!("twelvgaige_envelope_rotation_failure")
    envelope_path = Path.join(root, "store-envelope.json")
    backup_path = Path.join(root, "store-envelope.backup.json")
    old_env = "TWELVGAIGE_OLD_REWRAP_KEY_#{System.unique_integer([:positive])}"
    new_env = "TWELVGAIGE_NEW_REWRAP_KEY_#{System.unique_integer([:positive])}"

    old_bytes = String.duplicate("a", 32)
    wrong_old_bytes = String.duplicate("x", 32)
    new_bytes = String.duplicate("b", 32)

    System.put_env(old_env, "base64:" <> Base.encode64(wrong_old_bytes))
    System.put_env(new_env, "base64:" <> Base.encode64(new_bytes))

    on_exit(fn ->
      System.delete_env(old_env)
      System.delete_env(new_env)
    end)

    assert {:ok, envelope} =
             EnvelopeCipher.wrap_dek(String.duplicate("d", 32), key("store-key", old_bytes, 1),
               nonce: String.duplicate(<<1>>, 12)
             )

    assert :ok = EnvelopeFile.write(envelope_path, envelope)

    assert {:error, :dek_unwrap_failed} =
             EnvelopeRotation.rewrap_file(envelope_path,
               backup: backup_path,
               old_key_env: old_env,
               new_key_env: new_env
             )

    assert {:ok, current} = EnvelopeFile.read(envelope_path)
    assert current.wrapped_dek == envelope.wrapped_dek
    assert {:ok, backup} = EnvelopeFile.read(backup_path)
    assert backup.wrapped_dek == envelope.wrapped_dek
  end

  test "requires a backup path" do
    assert {:error, :envelope_backup_required} =
             EnvelopeRotation.rewrap_file("missing.json", old_key_env: "OLD", new_key_env: "NEW")
  end

  defp key(id, bytes, version) do
    {:ok, material} = KeyMaterial.new(bytes)

    %Key{
      id: id,
      backend: :env,
      status: :active,
      version: version,
      material: material
    }
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
