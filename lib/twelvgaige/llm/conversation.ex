defmodule Twelvgaige.LLM.Conversation do
  @moduledoc """
  Provider-neutral conversation values.

  Provider adapters translate this shape at the network edge. Keeping assistant
  tool calls and tool results in the conversation prevents a multi-turn tool
  exchange from losing its call identity during a provider round trip.
  """

  alias Twelvgaige.Error

  @roles ~w(system user assistant tool)

  @type tool_call :: %{
          required(:id) => String.t(),
          required(:name) => String.t(),
          required(:input) => map()
        }

  @type message :: %{
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:tool_calls) => [tool_call()],
          optional(:tool_call_id) => String.t(),
          optional(:name) => String.t(),
          optional(:source) => atom() | String.t()
        }

  @spec normalize_messages([map()]) :: {:ok, [message()]} | {:error, Error.t()}
  def normalize_messages(messages) when is_list(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {message, index}, {:ok, acc} ->
      case normalize_message(message, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, %Error{}} = error -> error
    end
  end

  def normalize_messages(_messages), do: conversation_error("messages must be a list", %{})

  @spec message(String.t() | atom(), term(), keyword()) :: message()
  def message(role, content, opts \\ []) do
    %{
      role: to_string(role),
      content: normalize_content(content)
    }
    |> put_if(:tool_calls, Keyword.get(opts, :tool_calls))
    |> put_if(:tool_call_id, Keyword.get(opts, :tool_call_id))
    |> put_if(:name, Keyword.get(opts, :name))
    |> put_if(:source, Keyword.get(opts, :source))
  end

  @spec assistant(Twelvgaige.LLM.Response.t()) :: message()
  def assistant(response) do
    message(:assistant, response.content,
      tool_calls:
        response.tool_calls
        |> Enum.with_index()
        |> Enum.map(fn {call, index} -> normalize_tool_call!(call, index) end),
      source: :provider
    )
  end

  @spec tool_result(String.t(), String.t(), String.t(), keyword()) :: message()
  def tool_result(call_id, name, content, opts \\ []) do
    message(:tool, content,
      tool_call_id: call_id,
      name: name,
      source: Keyword.get(opts, :source, :tool_execution)
    )
  end

  @spec role(map()) :: String.t()
  def role(message), do: value(message, :role, "user") |> to_string()

  @spec content(map()) :: String.t()
  def content(message), do: message |> value(:content, "") |> normalize_content()

  @spec tool_calls(map()) :: [tool_call()]
  def tool_calls(message) do
    case value(message, :tool_calls, []) do
      calls when is_list(calls) ->
        calls
        |> Enum.with_index()
        |> Enum.map(fn {call, index} -> normalize_tool_call!(call, index) end)

      _other ->
        []
    end
  end

  @spec tool_call_id(map()) :: String.t() | nil
  def tool_call_id(message), do: value(message, :tool_call_id, nil)

  @spec name(map()) :: String.t() | nil
  def name(message), do: value(message, :name, nil)

  defp normalize_message(%{} = message, index) do
    role = role(message)
    content = content(message)

    cond do
      role not in @roles ->
        conversation_error("message has an unsupported role", %{index: index, role: role})

      role == "tool" and not present_string?(tool_call_id(message)) ->
        conversation_error("tool result is missing tool_call_id", %{index: index})

      true ->
        normalized =
          message(role, content,
            tool_calls: if(role == "assistant", do: tool_calls(message), else: nil),
            tool_call_id: tool_call_id(message),
            name: name(message),
            source: value(message, :source, nil)
          )

        {:ok, normalized}
    end
  rescue
    _error -> conversation_error("message contains an invalid tool call", %{index: index})
  end

  defp normalize_message(_message, index) do
    conversation_error("message must be a map", %{index: index})
  end

  defp normalize_tool_call!(call, index) when is_map(call) do
    id = value(call, :id, value(call, :call_id, "tool_call_#{index + 1}"))
    name = value(call, :name, nil)
    input = call |> value(:input, value(call, :arguments, %{})) |> normalize_input()

    if present_string?(id) and present_string?(name) and is_map(input) do
      %{id: id, name: name, input: input}
    else
      raise ArgumentError, "invalid tool call"
    end
  end

  defp normalize_tool_call!(_call, _index), do: raise(ArgumentError, "invalid tool call")

  defp normalize_input(input) when is_map(input), do: input

  defp normalize_input(input) when is_binary(input) do
    case Jason.decode(input) do
      {:ok, %{} = decoded} -> decoded
      _other -> input
    end
  end

  defp normalize_input(input), do: input

  defp normalize_content(nil), do: ""
  defp normalize_content(content) when is_binary(content), do: content
  defp normalize_content(content), do: Jason.encode!(content)

  defp present_string?(value), do: is_binary(value) and value != ""

  defp put_if(map, _key, nil), do: map
  defp put_if(map, _key, []), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp value(map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp conversation_error(message, details) do
    {:error,
     Error.new(:llm_error, :llm_bad_request, message,
       retryable: false,
       details: details
     )}
  end
end
