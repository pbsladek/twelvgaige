defmodule Twelvgaige.Crypto.Key do
  @moduledoc """
  Resolved key plus metadata.

  `material` is intentionally redacted by its own Inspect implementation. The
  key metadata is safe to expose in status and errors as long as backend-specific
  paths or environment names are not treated as secrets.
  """

  alias Twelvgaige.Crypto.KeyMaterial

  @enforce_keys [:id, :backend, :status, :version, :material]
  defstruct [
    :id,
    :backend,
    :status,
    :version,
    :material,
    :created_at,
    :rotated_at,
    :retired_at,
    metadata: %{}
  ]

  @type status :: :active | :retired

  @type t :: %__MODULE__{
          id: String.t(),
          backend: atom(),
          status: status(),
          version: pos_integer(),
          material: KeyMaterial.t(),
          created_at: DateTime.t() | nil,
          rotated_at: DateTime.t() | nil,
          retired_at: DateTime.t() | nil,
          metadata: map()
        }

  @spec to_metadata(t()) :: map()
  def to_metadata(%__MODULE__{} = key) do
    %{
      "id" => key.id,
      "backend" => Atom.to_string(key.backend),
      "status" => Atom.to_string(key.status),
      "version" => key.version,
      "created_at" => iso8601(key.created_at),
      "rotated_at" => iso8601(key.rotated_at),
      "retired_at" => iso8601(key.retired_at),
      "metadata" => key.metadata
    }
  end

  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp iso8601(_datetime), do: nil
end

defimpl Inspect, for: Twelvgaige.Crypto.Key do
  import Inspect.Algebra

  def inspect(key, _opts) do
    concat([
      "#Twelvgaige.Crypto.Key<",
      key.id,
      " backend=",
      Atom.to_string(key.backend),
      " status=",
      Atom.to_string(key.status),
      " material=[REDACTED]>"
    ])
  end
end
