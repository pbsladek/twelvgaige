defmodule Twelvgaige.Crypto.Envelope do
  @moduledoc """
  Metadata for envelope-encrypted data encryption keys.

  The encrypted DEK is opaque to this struct. Backend implementations own the
  wrapping mechanism and key storage.
  """

  @enforce_keys [:schema_version, :key_id, :key_backend, :algorithm, :wrapped_dek]
  defstruct [:schema_version, :key_id, :key_backend, :algorithm, :wrapped_dek, metadata: %{}]

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          key_id: String.t(),
          key_backend: atom(),
          algorithm: String.t(),
          wrapped_dek: binary(),
          metadata: map()
        }

  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      schema_version: Keyword.get(opts, :schema_version, 1),
      key_id: Keyword.fetch!(opts, :key_id),
      key_backend: Keyword.fetch!(opts, :key_backend),
      algorithm: Keyword.fetch!(opts, :algorithm),
      wrapped_dek: Keyword.fetch!(opts, :wrapped_dek),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end
end

defimpl Inspect, for: Twelvgaige.Crypto.Envelope do
  import Inspect.Algebra

  def inspect(envelope, _opts) do
    concat([
      "#Twelvgaige.Crypto.Envelope<key_id=",
      envelope.key_id,
      " backend=",
      Atom.to_string(envelope.key_backend),
      " wrapped_dek=[REDACTED]>"
    ])
  end
end
