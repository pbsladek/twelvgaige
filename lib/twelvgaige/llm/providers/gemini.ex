defmodule Twelvgaige.LLM.Providers.Gemini do
  @moduledoc """
  Google Gemini provider adapter.

  The adapter keeps Gemini's `contents` and `functionCall` shapes at the edge
  of the system and returns Twelvgaige's normalized response structure.
  """

  @behaviour Twelvgaige.LLM.Provider

  alias Twelvgaige.Error
  alias Twelvgaige.LLM.Capabilities
  alias Twelvgaige.LLM.Providers.Common
  alias Twelvgaige.LLM.Response
  alias Twelvgaige.Redactor

  @default_base_url "https://generativelanguage.googleapis.com/v1beta/models"

  @impl true
  def provider_id, do: "gemini"

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
      |> Common.request(provider_id(), default_url(model), opts)

    with {:ok, response} <- Common.call_transport(request, opts),
         :ok <- ensure_success(response),
         {:ok, normalized} <- normalize_response(model, response, request) do
      {:ok, normalized}
    end
  end

  def complete(_model, _messages, _opts) do
    {:error, Error.new(:llm_error, :llm_bad_request, "gemini provider received invalid input")}
  end

  defp default_url(model) do
    "#{@default_base_url}/#{URI.encode_www_form(model)}:generateContent"
  end

  defp ensure_success(response) do
    if Common.ok_status?(response),
      do: :ok,
      else: {:error, Common.http_error(provider_id(), response)}
  end

  defp request_body(_model, messages, opts) do
    system = system_text(messages)

    %{
      "contents" => provider_contents(messages)
    }
    |> maybe_put_system(system)
    |> maybe_put("tools", Keyword.get(opts, :tools))
    |> maybe_put("generationConfig", Keyword.get(opts, :generation_config))
  end

  defp provider_contents(messages) do
    messages
    |> Enum.reject(&(Common.message_role(&1) == "system"))
    |> Enum.map(fn message ->
      %{
        "role" => gemini_role(Common.message_role(message)),
        "parts" => [%{"text" => Common.message_content(message)}]
      }
    end)
  end

  defp gemini_role("assistant"), do: "model"
  defp gemini_role("model"), do: "model"
  defp gemini_role(_role), do: "user"

  defp system_text(messages) do
    messages
    |> Enum.filter(&(Common.message_role(&1) == "system"))
    |> Enum.map(&Common.message_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp maybe_put_system(body, ""), do: body

  defp maybe_put_system(body, system) do
    Map.put(body, "system_instruction", %{"parts" => [%{"text" => system}]})
  end

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, _key, []), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp normalize_response(model, response, request) do
    body = Common.response_body(response)
    candidate = first_candidate(body)

    if safety_finish?(candidate) do
      {:error,
       Error.new(:llm_error, :llm_bad_request, "gemini provider blocked response for safety",
         retryable: false,
         safety_required: true,
         details: %{provider: provider_id(), body: Redactor.redact_json(body)}
       )}
    else
      {:ok, response_from_candidate(model, body, candidate, request)}
    end
  end

  defp response_from_candidate(model, body, candidate, request) do
    parts =
      candidate
      |> Map.get("content", %{})
      |> Map.get("parts", [])

    usage = Map.get(body, "usageMetadata", %{})

    %Response{
      provider: provider_id(),
      model: model,
      content: text_content(parts),
      tool_calls: tool_calls(parts),
      usage:
        Common.usage(
          Map.get(usage, "promptTokenCount"),
          Map.get(usage, "candidatesTokenCount"),
          usage_extra(usage)
        ),
      finish_reason: Map.get(candidate, "finishReason"),
      raw_redacted: Common.raw_redacted(request)
    }
  end

  defp usage_extra(usage) do
    extra = %{provider_usage: usage}

    case Map.get(usage, "totalTokenCount") do
      nil -> extra
      total -> Map.put(extra, :total_tokens, total)
    end
  end

  defp first_candidate(%{"candidates" => [candidate | _rest]}) when is_map(candidate),
    do: candidate

  defp first_candidate(_body), do: %{}

  defp safety_finish?(%{"finishReason" => finish_reason}) do
    String.upcase(to_string(finish_reason)) == "SAFETY"
  end

  defp safety_finish?(_candidate), do: false

  defp text_content(parts) when is_list(parts) do
    parts
    |> Enum.flat_map(fn
      %{"text" => text} when is_binary(text) -> [text]
      _part -> []
    end)
    |> Enum.join("")
  end

  defp text_content(_parts), do: ""

  defp tool_calls(parts) when is_list(parts) do
    parts
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {%{"functionCall" => call}, index} -> [normalize_function_call(call, index)]
      {%{"function_call" => call}, index} -> [normalize_function_call(call, index)]
      _other -> []
    end)
  end

  defp tool_calls(_parts), do: []

  defp normalize_function_call(call, index) when is_map(call) do
    %{
      "id" => Map.get(call, "id") || "function_call_#{index + 1}",
      "name" => Map.get(call, "name"),
      "input" => Common.parse_arguments(Map.get(call, "args", %{}))
    }
  end
end
