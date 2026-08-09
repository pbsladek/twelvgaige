defmodule Twelvgaige.Egress.Lease do
  @moduledoc "Short-lived session capability for broker-only network egress."

  @enforce_keys [:id, :session_id, :allowed_hosts, :allowed_ports, :expires_at, :access_token]
  defstruct [
    :id,
    :session_id,
    :allowed_hosts,
    :allowed_ports,
    :expires_at,
    :access_token,
    max_connections: 8,
    schema_version: 1,
    encoding_version: 1
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          session_id: String.t(),
          allowed_hosts: [String.t()],
          allowed_ports: [pos_integer()],
          expires_at: DateTime.t(),
          access_token: String.t() | nil,
          max_connections: pos_integer(),
          schema_version: pos_integer(),
          encoding_version: pos_integer()
        }
end

defimpl Inspect, for: Twelvgaige.Egress.Lease do
  import Inspect.Algebra

  def inspect(lease, _opts),
    do: concat(["#Twelvgaige.Egress.Lease<id=", lease.id, " token=[REDACTED]>"])
end
