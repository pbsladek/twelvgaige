defmodule Twelvgaige.LLM.Providers.OpenAI do
  @moduledoc """
  OpenAI provider adapter.

  Chat Completions remains the compatibility default. Set `api: :responses` or
  `TWELVGAIGE_OPENAI_API=responses` to use the Responses API, including its
  typed input/output items, function tools, and structured-output shape.
  """

  @behaviour Twelvgaige.LLM.Provider

  alias Twelvgaige.Error
  alias Twelvgaige.LLM.Capabilities
  alias Twelvgaige.LLM.Providers.Common
  alias Twelvgaige.LLM.Response

  @chat_completions_url "https://api.openai.com/v1/chat/completions"
  @responses_url "https://api.openai.com/v1/responses"

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
    with {:ok, api} <- api(opts),
         request <- request(api, model, messages, opts),
         {:ok, response} <- Common.call_transport(request, opts),
         :ok <- ensure_success(response),
         {:ok, normalized} <- normalize_response(api, model, response, request) do
      {:ok, normalized}
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

  defp api(opts) do
    case Keyword.get(opts, :api, :chat_completions) do
      api when api in [:chat_completions, "chat_completions"] ->
        {:ok, :chat_completions}

      api when api in [:responses, "responses"] ->
        {:ok, :responses}

      api ->
        {:error,
         Error.new(
           :llm_error,
           :llm_bad_request,
           "openai api must be responses or chat_completions",
           details: %{api: inspect(api)}
         )}
    end
  end

  defp request(:chat_completions, model, messages, opts) do
    model
    |> chat_completions_body(messages, opts)
    |> Common.request(provider_id(), @chat_completions_url, opts)
  end

  defp request(:responses, model, messages, opts) do
    model
    |> responses_body(messages, opts)
    |> Common.request(provider_id(), @responses_url, opts)
  end

  defp chat_completions_body(model, messages, opts) do
    %{
      "model" => model,
      "messages" => Enum.map(messages, &chat_completions_message/1)
    }
    |> maybe_put("max_completion_tokens", chat_completion_token_limit(opts))
    |> maybe_put("tools", chat_completions_tools(Keyword.get(opts, :tools)))
    |> maybe_put("response_format", Keyword.get(opts, :response_format))
    |> maybe_put("reasoning_effort", Keyword.get(opts, :reasoning_effort))
    |> maybe_put("tool_choice", Keyword.get(opts, :tool_choice))
    |> maybe_put("parallel_tool_calls", Keyword.get(opts, :parallel_tool_calls))
  end

  defp chat_completion_token_limit(opts) do
    case Keyword.fetch(opts, :max_completion_tokens) do
      {:ok, limit} -> limit
      :error -> Keyword.get(opts, :max_tokens)
    end
  end

  defp responses_body(model, messages, opts) do
    %{
      "model" => model,
      "input" => responses_input(messages),
      "store" => Keyword.get(opts, :store, false)
    }
    |> maybe_put("instructions", responses_instructions(messages))
    |> maybe_put(
      "max_output_tokens",
      Keyword.get(opts, :max_output_tokens, Keyword.get(opts, :max_tokens))
    )
    |> maybe_put("tools", responses_tools(Keyword.get(opts, :tools)))
    |> maybe_put("text", responses_text(opts))
    |> maybe_put("reasoning", Keyword.get(opts, :reasoning))
    |> maybe_put("tool_choice", Keyword.get(opts, :tool_choice))
    |> maybe_put("parallel_tool_calls", Keyword.get(opts, :parallel_tool_calls))
    |> maybe_put("previous_response_id", Keyword.get(opts, :previous_response_id))
    |> maybe_put("include", Keyword.get(opts, :include))
    |> maybe_put("metadata", Keyword.get(opts, :metadata))
    |> maybe_put("service_tier", Keyword.get(opts, :service_tier))
    |> maybe_put("prompt_cache_key", Keyword.get(opts, :prompt_cache_key))
  end

  defp chat_completions_message(message) do
    case Common.message_role(message) do
      "assistant" ->
        %{"role" => "assistant", "content" => Common.message_content(message)}
        |> maybe_put(
          "tool_calls",
          chat_completions_tool_calls(Common.message_tool_calls(message))
        )

      "tool" ->
        %{
          "role" => "tool",
          "content" => Common.message_content(message),
          "tool_call_id" => Common.message_tool_call_id(message)
        }
        |> maybe_put("name", Common.message_name(message))

      role ->
        %{"role" => role, "content" => Common.message_content(message)}
    end
  end

  defp responses_instructions(messages) do
    messages
    |> Enum.filter(&(Common.message_role(&1) == "system"))
    |> Enum.map(&Common.message_content/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
    |> empty_to_nil()
  end

  defp responses_input(messages) do
    Enum.flat_map(messages, fn message ->
      case Common.message_role(message) do
        "system" ->
          []

        "assistant" ->
          case Common.message_provider_items(message) do
            [] -> reconstructed_responses_assistant(message)
            items -> items
          end

        "tool" ->
          [
            %{
              "type" => "function_call_output",
              "call_id" => Common.message_tool_call_id(message),
              "output" => Common.message_content(message)
            }
          ]

        role ->
          [%{"role" => role, "content" => Common.message_content(message)}]
      end
    end)
  end

  defp reconstructed_responses_assistant(message) do
    assistant_message =
      case Common.message_content(message) do
        "" -> []
        content -> [%{"role" => "assistant", "content" => content}]
      end

    function_calls = Enum.map(Common.message_tool_calls(message), &responses_function_call/1)
    assistant_message ++ function_calls
  end

  defp responses_function_call(call) do
    %{
      "type" => "function_call",
      "call_id" => call.id,
      "name" => call.name,
      "arguments" => Jason.encode!(call.input)
    }
  end

  defp chat_completions_tool_calls(calls) do
    Enum.map(calls, fn call ->
      %{
        "id" => call.id,
        "type" => "function",
        "function" => %{"name" => call.name, "arguments" => Jason.encode!(call.input)}
      }
    end)
  end

  defp chat_completions_tools(nil), do: nil

  defp chat_completions_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      case value(tool, :function) do
        %{} ->
          stringify_keys(tool)

        _other ->
          %{
            "type" => "function",
            "function" => %{
              "name" => value(tool, :name),
              "description" => value(tool, :description, ""),
              "parameters" => value(tool, :input_schema, %{"type" => "object"})
            }
          }
      end
    end)
  end

  defp responses_tools(nil), do: nil

  defp responses_tools(tools) when is_list(tools) do
    Enum.map(tools, fn tool ->
      case {value(tool, :type), value(tool, :function)} do
        {type, _function} when is_binary(type) and type != "function" ->
          stringify_keys(tool)

        {_type, %{} = function} ->
          responses_function_tool(function)

        {_type, _function} ->
          responses_function_tool(tool)
      end
    end)
  end

  defp responses_function_tool(tool) do
    %{
      "type" => "function",
      "name" => value(tool, :name),
      "description" => value(tool, :description, ""),
      "parameters" => value(tool, :parameters, value(tool, :input_schema, %{"type" => "object"})),
      "strict" => value(tool, :strict, false)
    }
  end

  defp responses_text(opts) do
    explicit_text = Keyword.get(opts, :text)

    case responses_format(Keyword.get(opts, :response_format)) do
      nil -> explicit_text
      format -> Map.merge(explicit_text || %{}, %{"format" => format})
    end
  end

  defp responses_format(nil), do: nil

  defp responses_format(format) when is_map(format) do
    case {value(format, :type), value(format, :json_schema)} do
      {"json_schema", %{} = json_schema} ->
        %{
          "type" => "json_schema",
          "name" => value(json_schema, :name),
          "strict" => value(json_schema, :strict, false),
          "schema" => value(json_schema, :schema, %{})
        }

      _other ->
        stringify_keys(format)
    end
  end

  defp responses_format(_format), do: nil

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp value(map, key, default \\ nil)

  defp value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_map, _key, default), do: default

  defp maybe_put(body, _key, nil), do: body
  defp maybe_put(body, _key, []), do: body
  defp maybe_put(body, key, value), do: Map.put(body, key, value)

  defp normalize_response(api, model, response, request) do
    body = Common.response_body(response)
    choice = first_choice(body)
    message = Map.get(choice, "message", %{})
    usage = Map.get(body, "usage", %{})

    with :ok <- ensure_not_refused(body, message),
         :ok <- ensure_complete(api, body, choice),
         {:ok, calls} <- normalize_tool_calls(tool_calls(message) ++ response_tool_calls(body)) do
      {:ok,
       %Response{
         provider: provider_id(),
         model: model,
         provider_response_id: Map.get(body, "id"),
         provider_items: response_items(body),
         content: message_content(body, message),
         tool_calls: calls,
         usage:
           Common.usage(input_tokens(usage), output_tokens(usage), %{
             provider_usage: usage
           }),
         finish_reason: Map.get(choice, "finish_reason") || Map.get(body, "status"),
         raw_redacted: Common.raw_redacted(request)
       }}
    end
  end

  defp ensure_complete(:responses, %{"status" => "incomplete"} = body, _choice) do
    reason = get_in(body, ["incomplete_details", "reason"])

    {:error,
     Error.new(:llm_error, :llm_incomplete, "openai response was incomplete",
       retryable: false,
       details: %{provider: provider_id(), incomplete_reason: reason}
     )}
  end

  defp ensure_complete(:responses, %{"status" => status}, _choice)
       when status in ["failed", "cancelled"] do
    {:error,
     Error.new(:llm_error, :llm_unknown, "openai response did not complete",
       retryable: false,
       details: %{provider: provider_id(), response_status: status}
     )}
  end

  defp ensure_complete(:chat_completions, _body, %{"finish_reason" => "length"}) do
    {:error,
     Error.new(:llm_error, :llm_incomplete, "openai chat completion reached its token limit",
       retryable: false,
       details: %{provider: provider_id(), incomplete_reason: "length"}
     )}
  end

  defp ensure_complete(:chat_completions, _body, %{"finish_reason" => "content_filter"}) do
    {:error,
     Error.new(:llm_error, :llm_bad_request, "openai chat completion was blocked",
       retryable: false,
       safety_required: true,
       details: %{provider: provider_id(), incomplete_reason: "content_filter"}
     )}
  end

  defp ensure_complete(_api, _body, _choice), do: :ok

  defp ensure_not_refused(body, message) do
    if refusal?(body, message) do
      {:error,
       Error.new(:llm_error, :llm_bad_request, "openai refused the request",
         retryable: false,
         safety_required: true,
         details: %{provider: provider_id()}
       )}
    else
      :ok
    end
  end

  defp refusal?(_body, %{"refusal" => refusal}) when is_binary(refusal) and refusal != "",
    do: true

  defp refusal?(%{"output" => output}, _message) when is_list(output) do
    Enum.any?(output, fn item ->
      item
      |> Map.get("content", [])
      |> Enum.any?(&(is_map(&1) and Map.get(&1, "type") == "refusal"))
    end)
  end

  defp refusal?(_body, _message), do: false

  defp first_choice(%{"choices" => [choice | _rest]}) when is_map(choice), do: choice
  defp first_choice(_body), do: %{}

  defp message_content(_body, %{"content" => content}) when is_binary(content), do: content
  defp message_content(body, _message), do: response_output_text(body)

  defp response_output_text(%{"output_text" => output_text}) when is_binary(output_text),
    do: output_text

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

  defp response_items(%{"output" => output}) when is_list(output),
    do: Enum.filter(output, &is_map/1)

  defp response_items(_body), do: []

  defp tool_calls(%{"tool_calls" => calls}) when is_list(calls), do: calls
  defp tool_calls(_message), do: []

  defp response_tool_calls(%{"output" => output}) when is_list(output) do
    output
    |> Enum.filter(&(Map.get(&1, "type") == "function_call"))
  end

  defp response_tool_calls(_body), do: []

  defp normalize_tool_calls(calls) do
    calls
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {call, index}, {:ok, acc} ->
      case normalize_tool_call(call, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _error} = error -> error
    end
  end

  defp normalize_tool_call(%{"function" => function} = call, index) when is_map(function) do
    normalize_tool_arguments(
      Map.get(call, "id") || "tool_call_#{index + 1}",
      Map.get(function, "name"),
      Map.get(function, "arguments")
    )
  end

  defp normalize_tool_call(%{"type" => "function_call", "name" => name} = call, index) do
    normalize_tool_arguments(
      Map.get(call, "call_id") || Map.get(call, "id") || "tool_call_#{index + 1}",
      name,
      Map.get(call, "arguments")
    )
  end

  defp normalize_tool_call(%{"name" => name} = call, index) do
    normalize_tool_arguments(
      Map.get(call, "id") || Map.get(call, "call_id") || "tool_call_#{index + 1}",
      name,
      Map.get(call, "arguments")
    )
  end

  defp normalize_tool_call(_call, index) do
    malformed_tool_call("tool_call_#{index + 1}", nil)
  end

  defp normalize_tool_arguments(id, name, arguments) do
    case Common.decode_arguments(arguments) do
      {:ok, input} -> {:ok, %{"id" => id, "name" => name, "input" => input}}
      {:error, :invalid_tool_arguments} -> malformed_tool_call(id, name)
    end
  end

  defp malformed_tool_call(id, name) do
    {:error,
     Error.new(:output_error, :output_parse_error, "openai returned malformed tool arguments",
       retryable: false,
       details: %{provider: provider_id(), tool_call_id: id, tool_name: name}
     )}
  end

  defp input_tokens(usage), do: Map.get(usage, "prompt_tokens") || Map.get(usage, "input_tokens")

  defp output_tokens(usage),
    do: Map.get(usage, "completion_tokens") || Map.get(usage, "output_tokens")
end
