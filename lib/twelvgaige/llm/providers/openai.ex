defmodule Twelvgaige.LLM.Providers.OpenAI do
  @moduledoc """
  OpenAI provider adapter.

  Phase 2 targets the Chat Completions-compatible request/response shape. The
  normalization also accepts the newer Responses API output envelope for
  fixture compatibility, but no live HTTP transport is wired into normal tests.
  """

  @behaviour Twelvgaige.LLM.Provider

  alias Twelvgaige.Error
  alias Twelvgaige.LLM.Capabilities
  alias Twelvgaige.LLM.Providers.Common
  alias Twelvgaige.LLM.Response

  @default_url "https://api.openai.com/v1/chat/completions"

  @impl true
  def provider_id, do: "openai"

  @impl true
  def capabilities(_config) do
    %Capabilities{
      provider: provider_id(),
      supports_tools: true,
      supports_json_schema: true,
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
    {:error, Error.new(:llm_error, :llm_bad_request, "openai provider received invalid input")}
  end

  defp ensure_success(response) do
    if Common.ok_status?(response),
      do: :ok,
      else: {:error, Common.http_error(provider_id(), response)}
  end

  defp request_body(model, messages, opts) do
    %{
      "model" => model,
      "messages" => Enum.map(messages, &provider_message/1)
    }
    |> maybe_put("max_tokens", Keyword.get(opts, :max_tokens))
    |> maybe_put("tools", Keyword.get(opts, :tools))
    |> maybe_put("response_format", Keyword.get(opts, :response_format))
  end

  defp provider_message(message) do
    %{
      "role" => Common.message_role(message),
      "content" => Common.message_content(message)
    }
  end

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, _key, []), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp normalize_response(model, response, request) do
    body = Common.response_body(response)
    choice = first_choice(body)
    message = Map.get(choice, "message", %{})
    usage = Map.get(body, "usage", %{})

    %Response{
      provider: provider_id(),
      model: model,
      content: message_content(body, message),
      tool_calls: tool_calls(message) ++ response_tool_calls(body),
      usage:
        Common.usage(input_tokens(usage), output_tokens(usage), %{
          provider_usage: usage
        }),
      finish_reason: Map.get(choice, "finish_reason") || Map.get(body, "status"),
      raw_redacted: Common.raw_redacted(request)
    }
  end

  defp first_choice(%{"choices" => [choice | _rest]}) when is_map(choice), do: choice
  defp first_choice(_body), do: %{}

  defp message_content(_body, %{"content" => content}) when is_binary(content), do: content
  defp message_content(body, _message), do: response_output_text(body)

  defp response_output_text(%{"output" => output}) when is_list(output) do
    output
    |> Enum.flat_map(fn
      %{"content" => content} when is_list(content) ->
        Enum.flat_map(content, fn
          %{"type" => type, "text" => text}
          when type in ["output_text", "text"] and is_binary(text) ->
            [text]

          _part ->
            []
        end)

      _item ->
        []
    end)
    |> Enum.join("")
  end

  defp response_output_text(_body), do: ""

  defp tool_calls(%{"tool_calls" => calls}) when is_list(calls), do: normalize_tool_calls(calls)
  defp tool_calls(_message), do: []

  defp response_tool_calls(%{"output" => output}) when is_list(output) do
    output
    |> Enum.filter(&(Map.get(&1, "type") == "function_call"))
    |> normalize_tool_calls()
  end

  defp response_tool_calls(_body), do: []

  defp normalize_tool_calls(calls) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn {call, index} -> normalize_tool_call(call, index) end)
  end

  defp normalize_tool_call(%{"function" => function} = call, index) when is_map(function) do
    %{
      "id" => Map.get(call, "id") || "tool_call_#{index + 1}",
      "name" => Map.get(function, "name"),
      "input" => Common.parse_arguments(Map.get(function, "arguments"))
    }
  end

  defp normalize_tool_call(%{"name" => name} = call, index) do
    %{
      "id" => Map.get(call, "id") || Map.get(call, "call_id") || "tool_call_#{index + 1}",
      "name" => name,
      "input" => Common.parse_arguments(Map.get(call, "arguments"))
    }
  end

  defp normalize_tool_call(_call, index) do
    %{"id" => "tool_call_#{index + 1}", "name" => nil, "input" => %{}}
  end

  defp input_tokens(usage), do: Map.get(usage, "prompt_tokens") || Map.get(usage, "input_tokens")

  defp output_tokens(usage),
    do: Map.get(usage, "completion_tokens") || Map.get(usage, "output_tokens")
end
