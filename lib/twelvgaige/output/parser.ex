defmodule Twelvgaige.Output.Parser do
  @moduledoc """
  Parses and validates final shot output.

  Without an output schema, Twelvgaige keeps the final assistant content as an
  opaque string. With an output schema, the final assistant content must decode
  to JSON and validate against the supported schema subset before a shot can be
  marked complete.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Schema.ValueValidator
  alias Twelvgaige.Shell.Schema

  @spec parse(term(), Schema.t() | map() | nil) :: {:ok, term()} | {:error, Error.t()}
  def parse(content, nil) when is_binary(content), do: {:ok, %{"content" => content}}
  def parse(nil, nil), do: {:ok, %{"content" => ""}}

  def parse(content, %Schema{} = schema) when is_binary(content) do
    with {:ok, decoded} <- decode_content(content),
         :ok <- validate_schema(decoded, schema) do
      {:ok, decoded}
    end
  end

  def parse(content, schema) when is_map(schema) do
    with {:ok, %Schema{} = schema} <- Schema.from_map(schema) do
      parse(content, schema)
    else
      {:error, error} ->
        {:error,
         Error.new(:internal_error, :unsupported_schema_keyword, error.message,
           details: error.details
         )}
    end
  end

  def parse(_content, %Schema{}) do
    {:error,
     Error.new(:output_error, :output_parse_error, "shot output content must be a string",
       retryable: true,
       details: %{expected: "string"}
     )}
  end

  defp decode_content(content) do
    candidates =
      content
      |> String.trim()
      |> json_candidates()

    Enum.reduce_while(candidates, parse_error(content), fn candidate, _last_error ->
      case Jason.decode(candidate) do
        {:ok, decoded} -> {:halt, {:ok, decoded}}
        {:error, error} -> {:cont, parse_error(candidate, error)}
      end
    end)
  end

  defp json_candidates(trimmed) do
    [trimmed]
    |> append_candidate(fenced_json(trimmed))
    |> append_candidate(extracted_json(trimmed))
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp append_candidate(candidates, nil), do: candidates
  defp append_candidate(candidates, candidate), do: candidates ++ [String.trim(candidate)]

  defp fenced_json(content) do
    case Regex.run(~r/```(?:json)?\s*(.*?)```/s, content, capture: :all_but_first) do
      [candidate] -> candidate
      _no_match -> nil
    end
  end

  defp extracted_json(content) do
    first_object = first_index(content, "{")
    last_object = last_index(content, "}")
    first_array = first_index(content, "[")
    last_array = last_index(content, "]")

    candidates = [
      slice_candidate(content, first_object, last_object),
      slice_candidate(content, first_array, last_array)
    ]

    Enum.find(candidates, & &1)
  end

  defp slice_candidate(_content, nil, _last), do: nil
  defp slice_candidate(_content, _first, nil), do: nil

  defp slice_candidate(content, first, last) when first <= last do
    binary_part(content, first, last - first + 1)
  end

  defp slice_candidate(_content, _first, _last), do: nil

  defp first_index(content, pattern) do
    case :binary.match(content, pattern) do
      {index, _length} -> index
      :nomatch -> nil
    end
  end

  defp last_index(content, pattern) do
    content
    |> :binary.matches(pattern)
    |> List.last()
    |> case do
      {index, _length} -> index
      nil -> nil
    end
  end

  defp validate_schema(decoded, schema) do
    ValueValidator.validate(decoded, schema,
      error_class: :output_error,
      error_reason: :output_schema_violation,
      retryable: true,
      schema_error_class: :internal_error
    )
  end

  defp parse_error(content, error \\ nil) do
    details = %{bytes: byte_size(content)}
    details = if error, do: Map.put(details, :reason, Exception.message(error)), else: details

    {:error,
     Error.new(:output_error, :output_parse_error, "shot output was not valid JSON",
       retryable: true,
       details: details
     )}
  end
end
