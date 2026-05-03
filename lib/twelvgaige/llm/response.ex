defmodule Twelvgaige.LLM.Response do
  @moduledoc """
  Normalized LLM provider response.
  """

  @type t :: %__MODULE__{
          provider: String.t(),
          model: String.t(),
          content: String.t(),
          tool_calls: [map()],
          usage: map(),
          finish_reason: atom() | String.t() | nil,
          raw_redacted: map() | nil
        }

  @enforce_keys [:provider, :model]
  defstruct [
    :provider,
    :model,
    content: "",
    tool_calls: [],
    usage: %{},
    finish_reason: nil,
    raw_redacted: nil
  ]
end
