defmodule Twelvgaige.Shot.Result do
  @moduledoc """
  Stable successful shot result returned by every executor.

  `content` remains as a compatibility alias for `text`; callers should prefer
  the explicit `text`, `output`, `usage`, and `artifacts` fields for new code.
  """

  @type t :: %__MODULE__{
          status: :complete,
          text: String.t(),
          content: String.t(),
          output: term(),
          usage: map(),
          artifacts: [map()],
          tool_calls: [map()],
          messages: [Twelvgaige.LLM.Conversation.message()]
        }

  @enforce_keys [:text, :output, :usage]
  defstruct status: :complete,
            text: "",
            content: "",
            output: nil,
            usage: %{},
            artifacts: [],
            tool_calls: [],
            messages: []

  @spec new(keyword()) :: t()
  def new(attrs) do
    text = Keyword.fetch!(attrs, :text)

    %__MODULE__{
      text: text,
      content: text,
      output: Keyword.fetch!(attrs, :output),
      usage: Keyword.fetch!(attrs, :usage),
      artifacts: Keyword.get(attrs, :artifacts, []),
      tool_calls: Keyword.get(attrs, :tool_calls, []),
      messages: Keyword.get(attrs, :messages, [])
    }
  end
end
