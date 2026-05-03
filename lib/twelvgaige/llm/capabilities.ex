defmodule Twelvgaige.LLM.Capabilities do
  @moduledoc """
  Provider capability declaration.
  """

  @type t :: %__MODULE__{
          provider: String.t(),
          supports_tools: boolean(),
          supports_json_schema: boolean(),
          supports_streaming: boolean(),
          supports_system_messages: boolean(),
          supports_token_usage: boolean(),
          local_runtime: boolean(),
          default_timeout_ms: pos_integer(),
          default_max_concurrent_calls: pos_integer()
        }

  @enforce_keys [:provider]
  defstruct provider: nil,
            supports_tools: false,
            supports_json_schema: false,
            supports_streaming: false,
            supports_system_messages: true,
            supports_token_usage: false,
            local_runtime: false,
            default_timeout_ms: 30_000,
            default_max_concurrent_calls: 1
end
