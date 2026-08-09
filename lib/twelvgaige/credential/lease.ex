defmodule Twelvgaige.Credential.Lease do
  @moduledoc "Short-lived, session-bound credential and egress capability."

  @enforce_keys [
    :id,
    :session_id,
    :round_id,
    :shot_id,
    :attempt,
    :runtime,
    :principal,
    :provider_account,
    :models,
    :destinations,
    :budget,
    :expires_at,
    :access_token
  ]
  defstruct [
    :id,
    :session_id,
    :round_id,
    :shot_id,
    :attempt,
    :runtime,
    :principal,
    :provider_account,
    :models,
    :destinations,
    :budget,
    :expires_at,
    :access_token,
    schema_version: 1,
    encoding_version: 1
  ]
end

defimpl Inspect, for: Twelvgaige.Credential.Lease do
  import Inspect.Algebra

  def inspect(lease, _opts),
    do: concat(["#Twelvgaige.Credential.Lease<id=", lease.id, " token=[REDACTED]>"])
end
