defmodule Twelvgaige.Schema.ValueValidator do
  @moduledoc """
  Value validator for the supported JSON Schema subset.

  Shell schema validation checks that definitions only use the supported
  keywords. This module validates runtime values against those definitions and
  lets callers choose the subsystem-specific error class and reason.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Schema

  @spec validate(term(), Schema.t() | map(), keyword()) :: :ok | {:error, Error.t()}
  def validate(value, schema, opts \\ [])

  def validate(value, %Schema{root: schema}, opts) do
    validate_value(value, schema, [], opts)
  end

  def validate(value, schema, opts) when is_map(schema) do
    with {:ok, %Schema{} = schema} <- Schema.from_map(schema) do
      validate(value, schema, opts)
    else
      {:error, error} ->
        {:error,
         Error.new(
           Keyword.get(opts, :schema_error_class, :internal_error),
           :unsupported_schema_keyword,
           error.message,
           details: error.details
         )}
    end
  end

  defp validate_value(value, schema, path, opts) do
    with :ok <- validate_enum(value, schema, path, opts),
         :ok <- validate_type(value, Map.get(schema, "type"), schema, path, opts) do
      :ok
    end
  end

  defp validate_enum(value, %{"enum" => enum}, path, opts) do
    if value in enum do
      :ok
    else
      value_error("value is not in enum", path, opts, %{allowed: enum})
    end
  end

  defp validate_enum(_value, _schema, _path, _opts), do: :ok

  defp validate_type(_value, nil, _schema, _path, _opts), do: :ok

  defp validate_type(value, "object", schema, path, opts) when is_map(value) do
    with :ok <- validate_required(value, Map.get(schema, "required", []), path, opts),
         :ok <- validate_additional_properties(value, schema, path, opts) do
      validate_properties(value, Map.get(schema, "properties", %{}), path, opts)
    end
  end

  defp validate_type(value, "array", schema, path, opts) when is_list(value) do
    case Map.fetch(schema, "items") do
      {:ok, item_schema} ->
        value
        |> Enum.with_index()
        |> Enum.reduce_while(:ok, fn {item, index}, :ok ->
          case validate_value(item, item_schema, path ++ [index], opts) do
            :ok -> {:cont, :ok}
            {:error, _error} = error -> {:halt, error}
          end
        end)

      :error ->
        :ok
    end
  end

  defp validate_type(value, "string", _schema, _path, _opts) when is_binary(value), do: :ok
  defp validate_type(value, "integer", _schema, _path, _opts) when is_integer(value), do: :ok
  defp validate_type(value, "number", _schema, _path, _opts) when is_number(value), do: :ok
  defp validate_type(value, "boolean", _schema, _path, _opts) when is_boolean(value), do: :ok
  defp validate_type(nil, "null", _schema, _path, _opts), do: :ok

  defp validate_type(_value, type, _schema, path, opts) do
    value_error("expected #{type}", path, opts, %{expected: type})
  end

  defp validate_required(value, required, path, opts) do
    Enum.reduce_while(required, :ok, fn key, :ok ->
      if has_key?(value, key) do
        {:cont, :ok}
      else
        {:halt, value_error("missing required field #{inspect(key)}", path ++ [key], opts)}
      end
    end)
  end

  defp validate_additional_properties(
         value,
         %{"additionalProperties" => false} = schema,
         path,
         opts
       ) do
    allowed =
      schema
      |> Map.get("properties", %{})
      |> Map.keys()
      |> MapSet.new()

    Enum.reduce_while(Map.keys(value), :ok, fn key, :ok ->
      key_string = key_string(key)

      if MapSet.member?(allowed, key_string) do
        {:cont, :ok}
      else
        {:halt,
         value_error("unknown input field #{inspect(key_string)}", path ++ [key_string], opts, %{
           field: key_string
         })}
      end
    end)
  end

  defp validate_additional_properties(_value, _schema, _path, _opts), do: :ok

  defp validate_properties(value, properties, path, opts) do
    Enum.reduce_while(properties, :ok, fn {key, property_schema}, :ok ->
      case fetch_key(value, key) do
        {:ok, property_value} ->
          case validate_value(property_value, property_schema, path ++ [key], opts) do
            :ok -> {:cont, :ok}
            {:error, _error} = error -> {:halt, error}
          end

        :error ->
          {:cont, :ok}
      end
    end)
  end

  defp has_key?(map, key) do
    Enum.any?(Map.keys(map), &(key_string(&1) == key))
  end

  defp fetch_key(map, key) do
    case Enum.find(map, fn {map_key, _value} -> key_string(map_key) == key end) do
      {_map_key, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: inspect(key)

  defp value_error(message, path, opts, details \\ %{}) do
    {:error,
     Error.new(
       Keyword.fetch!(opts, :error_class),
       Keyword.fetch!(opts, :error_reason),
       message,
       retryable: Keyword.get(opts, :retryable, false),
       details: Map.merge(%{path: path}, details)
     )}
  end
end
