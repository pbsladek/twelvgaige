defmodule Twelvgaige.LLM.Providers.Anthropic do
  @moduledoc """
  Anthropic provider adapter.

  The adapter translates Twelvgaige's normalized message shape into the
  Anthropic Messages API request shape and normalizes successful fixture/live
  responses back into `Twelvgaige.LLM.Response`.
  """

  @behaviour Twelvgaige.LLM.Provider

  alias Twelvgaige.Error
  alias Twelvgaige.LLM.Capabilities
  alias Twelvgaige.LLM.Providers.Common
  alias Twelvgaige.LLM.Response

  @default_url "https://api.anthropic.com/v1/messages"

  @impl true
  def provider_id, do: "anthropic"

  @impl true
  def capabilities(_config) do
    %Capabilities{
      provider: provider_id(),
      supports_tools: true,
      supports_json_schema: false,
      supports_streaming: false,
      supports_system_messages: true,
      supports_token_usage: true,
      local_runtime: false,
      default_timeout_ms: 30_000,
      default_max_concurrent_calls: 4
    }
  end

  @impl true
  def complete(model, messages, opts) when is_binary(model) and is_list(messages) do
    request =
      model
      |> request_body(messages, opts)
      |> Common.request(provider_id(), @default_url, opts)

    with {:ok, response} <- Common.call_transport(request, opts),
         :ok <- ensure_success(response) do
      {:ok, normalize_response(model, response, request)}
    end
  end

  def complete(_model, _messages, _opts) do
    {:error, Error.new(:llm_error, :llm_bad_request, "anthropic provider received invalid input")}
  end

  defp ensure_success(response) do
    if Common.ok_status?(response),
      do: :ok,
      else: {:error, Common.http_error(provider_id(), response)}
  end

  defp request_body(model, messages, opts) do
    system = system_text(messages)

    %{
      "model" => model,
      "max_tokens" => Keyword.get(opts, :max_tokens, 4096),
      "messages" => provider_messages(messages)
    }
    |> maybe_put_system(system)
    |> maybe_put_tools(opts)
  end

  defp provider_messages(messages) do
    messages
    |> Enum.reject(&(Common.message_role(&1) == "system"))
    |> Enum.map(fn message ->
      %{
        "role" => anthropic_role(Common.message_role(message)),
        "content" => Common.message_content(message)
      }
    end)
  end

  defp anthropic_role("assistant"), do: "assistant"
  defp anthropic_role(_role), do: "user"

  defp system_text(messages) do
    messages
    |> Enum.filter(&(Common.message_role(&1) == "system"))
    |> Enum.map(&Common.message_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp maybe_put_system(body, ""), do: body
  defp maybe_put_system(body, system), do: Map.put(body, "system", system)

  defp maybe_put_tools(body, opts) do
    case Keyword.get(opts, :tools, []) do
      [] -> body
      tools when is_list(tools) -> Map.put(body, "tools", tools)
      _other -> body
    end
  end

  defp normalize_response(model, response, request) do
    body = Common.response_body(response)
    blocks = Map.get(body, "content", [])
    usage = Map.get(body, "usage", %{})

    %Response{
      provider: provider_id(),
      model: model,
      content: text_content(blocks),
      tool_calls: tool_calls(blocks),
      usage:
        Common.usage(Map.get(usage, "input_tokens"), Map.get(usage, "output_tokens"), %{
          provider_usage: usage
        }),
      finish_reason: Map.get(body, "stop_reason"),
      raw_redacted: Common.raw_redacted(request)
    }
  end

  defp text_content(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      _block -> []
    end)
    |> Enum.join("")
  end

  defp text_content(_blocks), do: ""

  defp tool_calls(blocks) when is_list(blocks) do
    blocks
    |> Enum.filter(&(Map.get(&1, "type") == "tool_use"))
    |> Enum.map(fn block ->
      %{
        "id" => Map.get(block, "id"),
        "name" => Map.get(block, "name"),
        "input" => Map.get(block, "input", %{})
      }
    end)
  end

  defp tool_calls(_blocks), do: []
end
