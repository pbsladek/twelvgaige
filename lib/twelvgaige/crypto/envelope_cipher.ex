defmodule Twelvgaige.Crypto.EnvelopeCipher do
  @moduledoc """
  Envelope encryption primitives for future encrypted local stores.

  A data-encryption key (DEK) is wrapped with an active key-encryption key
  resolved from a key-manager backend. Rewrap rotation decrypts only the wrapped
  DEK and writes a new envelope; it does not require database re-encryption.
  """

  alias Twelvgaige.Crypto.Envelope
  alias Twelvgaige.Crypto.Key

  @algorithm "AES-256-GCM"
  @schema_version 1
  @aad "twelvgaige:v1:dek-envelope"
  @nonce_bytes 12
  @tag_bytes 16

  @type dek :: binary()

  @spec generate_dek() :: dek()
  def generate_dek, do: :crypto.strong_rand_bytes(32)

  @spec wrap_dek(dek(), Key.t(), keyword()) :: {:ok, Envelope.t()} | {:error, term()}
  def wrap_dek(dek, key, opts \\ [])

  def wrap_dek(dek, %Key{status: :active} = key, opts)
      when is_binary(dek) and byte_size(dek) >= 32 do
    nonce = Keyword.get(opts, :nonce, :crypto.strong_rand_bytes(@nonce_bytes))

    with :ok <- valid_nonce(nonce),
         {ciphertext, tag} <- encrypt(dek, key, nonce) do
      {:ok,
       Envelope.new(
         schema_version: @schema_version,
         key_id: key.id,
         key_backend: key.backend,
         algorithm: @algorithm,
         wrapped_dek: ciphertext,
         metadata: %{
           "nonce" => Base.encode64(nonce),
           "tag" => Base.encode64(tag),
           "wrapped_at" => now_iso8601(),
           "key_version" => key.version
         }
       )}
    end
  end

  def wrap_dek(_dek, %Key{status: :retired}, _opts), do: {:error, :key_retired}
  def wrap_dek(_dek, %Key{}, _opts), do: {:error, :inactive_key}
  def wrap_dek(_dek, _key, _opts), do: {:error, :invalid_wrap_input}

  @spec unwrap_dek(Envelope.t(), Key.t()) :: {:ok, dek()} | {:error, term()}
  def unwrap_dek(%Envelope{} = envelope, %Key{status: :active} = key) do
    with :ok <- match_envelope_key(envelope, key),
         {:ok, nonce} <- decode_metadata_b64(envelope, "nonce"),
         {:ok, tag} <- decode_metadata_b64(envelope, "tag") do
      case decrypt(envelope.wrapped_dek, tag, key, nonce) do
        dek when is_binary(dek) -> {:ok, dek}
        :error -> {:error, :dek_unwrap_failed}
      end
    end
  end

  def unwrap_dek(_envelope, %Key{status: :retired}), do: {:error, :key_retired}
  def unwrap_dek(_envelope, _key), do: {:error, :invalid_unwrap_input}

  @spec rewrap_dek(Envelope.t(), Key.t(), Key.t(), keyword()) ::
          {:ok, Envelope.t()} | {:error, term()}
  def rewrap_dek(%Envelope{} = envelope, %Key{} = old_key, %Key{} = new_key, opts \\ []) do
    with {:ok, dek} <- unwrap_dek(envelope, old_key),
         {:ok, rewrapped} <- wrap_dek(dek, new_key, opts) do
      {:ok,
       %{
         rewrapped
         | metadata:
             Map.merge(rewrapped.metadata, %{
               "rotation" => "rewrap",
               "previous_key_id" => envelope.key_id,
               "previous_key_backend" => Atom.to_string(envelope.key_backend),
               "previous_key_version" => envelope.metadata["key_version"],
               "rotated_at" => now_iso8601()
             })
       }}
    end
  end

  defp encrypt(dek, %Key{} = key, nonce) do
    :crypto.crypto_one_time_aead(
      :aes_256_gcm,
      key.material.bytes,
      nonce,
      dek,
      @aad,
      @tag_bytes,
      true
    )
  end

  defp decrypt(ciphertext, tag, %Key{} = key, nonce) do
    :crypto.crypto_one_time_aead(
      :aes_256_gcm,
      key.material.bytes,
      nonce,
      ciphertext,
      @aad,
      tag,
      false
    )
  end

  defp valid_nonce(nonce) when is_binary(nonce) and byte_size(nonce) == @nonce_bytes, do: :ok
  defp valid_nonce(_nonce), do: {:error, :invalid_nonce}

  defp match_envelope_key(%Envelope{} = envelope, %Key{} = key) do
    cond do
      envelope.algorithm != @algorithm ->
        {:error, :unsupported_envelope_algorithm}

      envelope.schema_version != @schema_version ->
        {:error, :unsupported_envelope_schema}

      envelope.key_id != key.id ->
        {:error, :envelope_key_mismatch}

      envelope.key_backend != key.backend ->
        {:error, :envelope_key_mismatch}

      true ->
        :ok
    end
  end

  defp decode_metadata_b64(%Envelope{metadata: metadata}, field) do
    with value when is_binary(value) <- Map.get(metadata, field),
         {:ok, decoded} <- Base.decode64(value) do
      {:ok, decoded}
    else
      _invalid -> {:error, {:invalid_envelope_metadata, field}}
    end
  end

  defp now_iso8601,
    do: DateTime.to_iso8601(DateTime.truncate(Twelvgaige.Clock.utc_now(), :second))
end
