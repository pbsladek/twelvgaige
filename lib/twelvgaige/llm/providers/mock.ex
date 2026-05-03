defmodule Twelvgaige.LLM.Providers.Mock do
  @moduledoc """
  Deterministic mock provider for tests and Phase 1 local execution.
  """

  @behaviour Twelvgaige.LLM.Provider

  alias Twelvgaige.Error
  alias Twelvgaige.LLM.Capabilities
  alias Twelvgaige.LLM.Response

  @impl true
  def provider_id, do: "mock"

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
      default_timeout_ms: 1_000,
      default_max_concurrent_calls: 100
    }
  end

  @impl true
  def complete(model, messages, opts) when is_binary(model) and is_list(messages) do
    cond do
      error = Keyword.get(opts, :error) ->
        {:error, normalize_error(error)}

      response = Keyword.get(opts, :response) ->
        {:ok, normalize_response(model, response)}

      handler = Keyword.get(opts, :mock_handler) ->
        call_handler(handler, model, messages, opts)

      true ->
        {:ok,
         %Response{
           provider: provider_id(),
           model: model,
           content: default_content(messages),
           tool_calls: [],
           usage: %{input_tokens: 0, output_tokens: 0, total_tokens: 0, estimated: true},
           finish_reason: :stop,
           raw_redacted: %{provider: provider_id()}
         }}
    end
  end

  def complete(_model, _messages, _opts) do
    {:error, Error.new(:llm_error, :llm_bad_request, "mock provider received invalid input")}
  end

  defp call_handler(handler, model, messages, opts) when is_function(handler, 3) do
    handler.(model, messages, opts)
    |> normalize_handler_result(model)
  rescue
    error ->
      {:error,
       Error.new(:llm_error, :llm_unknown, "mock provider handler raised",
         retryable: true,
         details: %{reason: Exception.message(error)}
       )}
  end

  defp call_handler(handler, model, messages, _opts) when is_function(handler, 2) do
    handler.(model, messages)
    |> normalize_handler_result(model)
  rescue
    error ->
      {:error,
       Error.new(:llm_error, :llm_unknown, "mock provider handler raised",
         retryable: true,
         details: %{reason: Exception.message(error)}
       )}
  end

  defp call_handler(_handler, _model, _messages, _opts) do
    {:error, Error.new(:llm_error, :llm_bad_request, "mock handler must be a function")}
  end

  defp normalize_handler_result({:ok, %Response{} = response}, model),
    do: {:ok, normalize_response(model, response)}

  defp normalize_handler_result({:ok, response}, model),
    do: {:ok, normalize_response(model, response)}

  defp normalize_handler_result({:error, %Error{} = error}, _model), do: {:error, error}
  defp normalize_handler_result({:error, reason}, _model), do: {:error, normalize_error(reason)}
  defp normalize_handler_result(response, model), do: {:ok, normalize_response(model, response)}

  defp normalize_response(model, %Response{} = response),
    do: %{response | provider: provider_id(), model: model}

  defp normalize_response(model, content) when is_binary(content) do
    %Response{
      provider: provider_id(),
      model: model,
      content: content,
      finish_reason: :stop,
      raw_redacted: %{provider: provider_id()}
    }
  end

  defp normalize_response(model, response) when is_map(response) do
    %Response{
      provider: provider_id(),
      model: model,
      content: Map.get(response, :content) || Map.get(response, "content") || "",
      tool_calls: Map.get(response, :tool_calls) || Map.get(response, "tool_calls") || [],
      usage: Map.get(response, :usage) || Map.get(response, "usage") || %{},
      finish_reason: Map.get(response, :finish_reason) || Map.get(response, "finish_reason"),
      raw_redacted: %{provider: provider_id()}
    }
  end

  defp normalize_error(%Error{} = error), do: error

  defp normalize_error(reason) when is_atom(reason) do
    Error.new(:llm_error, reason, "mock provider returned #{reason}",
      retryable: retryable_reason?(reason)
    )
  end

  defp retryable_reason?(reason),
    do: reason in [:llm_timeout, :llm_rate_limited, :llm_provider_unavailable]

  defp default_content([]), do: "mock response"

  defp default_content(messages) do
    last_content =
      messages
      |> List.last()
      |> case do
        %{"content" => content} -> content
        %{content: content} -> content
        _ -> "mock response"
      end

    "mock response: #{last_content}"
  end
end
