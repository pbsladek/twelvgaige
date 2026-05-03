defmodule Twelvgaige.LLM.Providers.Ollama do
  @moduledoc """
  Ollama provider adapter for local model runtimes.

  Ollama is treated as a local runtime with conservative default concurrency.
  The adapter targets `/api/chat` with `stream: false` and normalizes the
  response into Twelvgaige's provider-neutral response shape.
  """

  @behaviour Twelvgaige.LLM.Provider

  alias Twelvgaige.Error
  alias Twelvgaige.LLM.Capabilities
  alias Twelvgaige.LLM.Providers.Common
  alias Twelvgaige.LLM.Response

  @default_host "http://localhost:11434"

  @impl true
  def provider_id, do: "ollama"

  @impl true
  def capabilities(_config) do
    %Capabilities{
      provider: provider_id(),
      supports_tools: false,
      supports_json_schema: false,
      supports_streaming: false,
      supports_system_messages: true,
      supports_token_usage: true,
      local_runtime: true,
      default_timeout_ms: 120_000,
      default_max_concurrent_calls: 1
    }
  end

  @impl true
  def complete(model, messages, opts) when is_binary(model) and is_list(messages) do
    request_opts = Keyword.delete(opts, :base_url)

    request =
      model
      |> request_body(messages, opts)
      |> Common.request(provider_id(), endpoint(opts), request_opts)

    with {:ok, response} <- Common.call_transport(request, opts),
         :ok <- ensure_success(response) do
      {:ok, normalize_response(model, response, request)}
    end
  end

  def complete(_model, _messages, _opts) do
    {:error, Error.new(:llm_error, :llm_bad_request, "ollama provider received invalid input")}
  end

  defp endpoint(opts) do
    base =
      Keyword.get(opts, :base_url) ||
        System.get_env("OLLAMA_HOST") ||
        @default_host

    base = String.trim_trailing(base, "/")

    if String.ends_with?(base, "/api/chat") do
      base
    else
      "#{base}/api/chat"
    end
  end

  defp ensure_success(response) do
    if Common.ok_status?(response),
      do: :ok,
      else: {:error, Common.http_error(provider_id(), response)}
  end

  defp request_body(model, messages, opts) do
    %{
      "model" => model,
      "stream" => false,
      "messages" => Enum.map(messages, &provider_message/1)
    }
    |> maybe_put("options", Keyword.get(opts, :options))
    |> maybe_put("tools", Keyword.get(opts, :tools))
  end

  defp provider_message(message) do
    %{
      "role" => ollama_role(Common.message_role(message)),
      "content" => Common.message_content(message)
    }
  end

  defp ollama_role("system"), do: "system"
  defp ollama_role("assistant"), do: "assistant"
  defp ollama_role(_role), do: "user"

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, _key, []), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp normalize_response(model, response, request) do
    body = Common.response_body(response)
    message = Map.get(body, "message", %{})

    %Response{
      provider: provider_id(),
      model: model,
      content: Map.get(message, "content") || Map.get(body, "response") || "",
      tool_calls: tool_calls(message),
      usage:
        Common.usage(Map.get(body, "prompt_eval_count"), Map.get(body, "eval_count"), %{
          provider_usage: Map.take(body, ["prompt_eval_count", "eval_count", "eval_duration"])
        }),
      finish_reason: Map.get(body, "done_reason"),
      raw_redacted: Common.raw_redacted(request)
    }
  end

  defp tool_calls(%{"tool_calls" => calls}) when is_list(calls) do
    calls
    |> Enum.with_index()
    |> Enum.map(fn {call, index} -> normalize_tool_call(call, index) end)
  end

  defp tool_calls(_message), do: []

  defp normalize_tool_call(%{"function" => function} = call, index) when is_map(function) do
    %{
      "id" => Map.get(call, "id") || "tool_call_#{index + 1}",
      "name" => Map.get(function, "name"),
      "input" => Common.parse_arguments(Map.get(function, "arguments"))
    }
  end

  defp normalize_tool_call(%{"name" => name} = call, index) do
    %{
      "id" => Map.get(call, "id") || "tool_call_#{index + 1}",
      "name" => name,
      "input" => Common.parse_arguments(Map.get(call, "arguments"))
    }
  end

  defp normalize_tool_call(_call, index) do
    %{"id" => "tool_call_#{index + 1}", "name" => nil, "input" => %{}}
  end
end
