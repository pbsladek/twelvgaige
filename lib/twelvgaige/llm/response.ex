defmodule Twelvgaige.LLM.Response do
  @moduledoc """
  Normalized LLM provider response.
  """

  @type t :: %__MODULE__{
          provider: String.t(),
          model: String.t(),
          content: String.t(),
          tool_calls: [map()],
          provider_response_id: String.t() | nil,
          provider_items: [map()],
          usage: map(),
          finish_reason: atom() | String.t() | nil,
          raw_redacted: map() | nil
        }

  @enforce_keys [:provider, :model]
  defstruct [
    :provider,
    :model,
    :provider_response_id,
    content: "",
    tool_calls: [],
    provider_items: [],
    usage: %{},
    finish_reason: nil,
    raw_redacted: nil
  ]
end
