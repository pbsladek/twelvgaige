defmodule Twelvgaige.Crypto.KeyMaterial do
  @moduledoc """
  Raw symmetric key material with redacted inspection.

  This struct may contain bytes that can decrypt a future local store. Do not log
  it, include it in audit events, or serialize it directly.
  """

  @enforce_keys [:bytes]
  defstruct [:bytes]

  @type t :: %__MODULE__{bytes: binary()}

  @spec new(binary()) :: {:ok, t()} | {:error, term()}
  def new(bytes) when is_binary(bytes) and byte_size(bytes) >= 32 do
    {:ok, %__MODULE__{bytes: bytes}}
  end

  def new(_bytes), do: {:error, :invalid_key_material}
end

defimpl Inspect, for: Twelvgaige.Crypto.KeyMaterial do
  import Inspect.Algebra

  def inspect(_material, _opts), do: string("#Twelvgaige.Crypto.KeyMaterial<[REDACTED]>")
end
