defmodule Twelvgaige.Operations.KeysTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Artifact.Store, as: ArtifactStore
  alias Twelvgaige.Operations.{Keyring, Keys}

  test "wrapped artifact keys survive restart and rotation without plaintext key persistence" do
    root = Path.join(System.tmp_dir!(), "twelvgaige-keys-#{System.unique_integer([:positive])}")
    master = :crypto.strong_rand_bytes(32)

    assert {:ok, first} = Keys.resolve(data_root: root, operations_master_key: master)

    store =
      start_supervised!(
        {ArtifactStore,
         name: nil,
         root: Path.join(root, "artifacts"),
         key: first.artifact_key,
         key_id: first.artifact_key_id,
         previous_keys: first.artifact_previous_keys}
      )

    assert {:ok, ref} = ArtifactStore.put(%{secret: "artifact"}, server: store)
    keyring = start_supervised!({Keyring, name: nil, keys: first, artifact_store: store})

    assert {:ok, %{old_key_id: old_id, new_key_id: new_id}} =
             Keyring.rotate_artifact(server: keyring)

    refute new_id == old_id
    assert {:ok, %{secret: "artifact"}} = ArtifactStore.get(ref, server: store)

    key_file = File.read!(first.artifact_key_file)
    refute key_file =~ Base.encode64(first.artifact_key)
    refute key_file =~ Base.encode64(master)

    assert {:ok, restarted} = Keys.resolve(data_root: root, operations_master_key: master)
    assert restarted.artifact_key_id == new_id
    assert Map.has_key?(restarted.artifact_previous_keys, old_id)

    GenServer.stop(store)

    restarted_store =
      start_supervised!(
        {ArtifactStore,
         name: nil,
         root: Path.join(root, "artifacts"),
         key: restarted.artifact_key,
         key_id: restarted.artifact_key_id,
         previous_keys: restarted.artifact_previous_keys},
        id: :restarted_wrapped_artifact_store
      )

    assert {:ok, %{secret: "artifact"}} = ArtifactStore.get(ref, server: restarted_store)
  end

  test "a wrong host master key cannot authenticate the wrapped artifact key" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige-keys-wrong-#{System.unique_integer([:positive])}")

    assert {:ok, _keys} =
             Keys.resolve(data_root: root, operations_master_key: :crypto.strong_rand_bytes(32))

    assert {:error, {:operations_artifact_key_file_invalid, :artifact_key_authentication_failed}} =
             Keys.resolve(data_root: root, operations_master_key: :crypto.strong_rand_bytes(32))
  end
end
