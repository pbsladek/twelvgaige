defmodule Twelvgaige.Artifact.Ref do
  @moduledoc "Immutable reference to an encrypted artifact payload."

  @enforce_keys [:id, :digest, :bytes, :retention_class, :created_at]
  defstruct [
    :id,
    :round_id,
    :session_id,
    :media_type,
    :digest,
    :bytes,
    :retention_class,
    :created_at,
    :expires_at,
    schema_version: 1,
    encoding_version: 1,
    encrypted: true
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          round_id: String.t() | nil,
          session_id: String.t() | nil,
          media_type: String.t() | nil,
          digest: String.t(),
          bytes: non_neg_integer(),
          retention_class: :raw | :security | :permanent,
          created_at: DateTime.t(),
          expires_at: DateTime.t() | nil,
          schema_version: pos_integer(),
          encoding_version: pos_integer(),
          encrypted: true
        }
end
