defmodule Twelvgaige.Tool.Call do
  @moduledoc """
  Normalized tool-call shape used by shot execution.

  Provider adapters eventually normalize native provider calls into this shape.
  Phase 2 also accepts common string-key and atom-key maps from the mock
  provider so tests can describe tool calls directly.
  """

  alias Twelvgaige.Error

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          input: map()
        }

  @enforce_keys [:id, :name, :input]
  defstruct [:id, :name, :input]

  @spec normalize(term(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def normalize(call, index) when is_map(call) and is_integer(index) and index >= 0 do
    with {:ok, name} <- fetch_name(call),
         {:ok, input} <- fetch_input(call),
         {:ok, id} <- fetch_id(call, index) do
      {:ok, %__MODULE__{id: id, name: name, input: input}}
    end
  end

  def normalize(_call, _index) do
    {:error,
     Error.new(:tool_error, :tool_input_invalid, "tool call must be a map",
       details: %{expected: "map"}
     )}
  end

  defp fetch_name(call) do
    case first_present(call, ["name", :name, "tool_name", :tool_name]) do
      name when is_binary(name) and name != "" ->
        {:ok, name}

      _value ->
        {:error,
         Error.new(:tool_error, :tool_input_invalid, "tool call name must be a non-empty string")}
    end
  end

  defp fetch_input(call) do
    value = first_present(call, ["input", :input, "arguments", :arguments])

    cond do
      is_nil(value) ->
        {:ok, %{}}

      is_map(value) ->
        {:ok, value}

      is_binary(value) ->
        case Jason.decode(value) do
          {:ok, decoded} when is_map(decoded) ->
            {:ok, decoded}

          {:ok, _decoded} ->
            input_error("tool call JSON arguments must decode to an object")

          {:error, reason} ->
            input_error("tool call arguments are not valid JSON", %{reason: inspect(reason)})
        end

      true ->
        input_error("tool call input must be a map or JSON object string")
    end
  end

  defp fetch_id(call, index) do
    case first_present(call, ["id", :id, "tool_call_id", :tool_call_id]) do
      id when is_binary(id) and id != "" -> {:ok, id}
      nil -> {:ok, "tool_call_#{index + 1}"}
      _value -> input_error("tool call id must be a string")
    end
  end

  defp first_present(map, keys) do
    Enum.find_value(keys, fn key ->
      if Map.has_key?(map, key), do: Map.fetch!(map, key)
    end)
  end

  defp input_error(message, details \\ %{}) do
    {:error, Error.new(:tool_error, :tool_input_invalid, message, details: details)}
  end
end
