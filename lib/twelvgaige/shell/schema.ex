defmodule Twelvgaige.Shell.Schema do
  @moduledoc """
  Phase 1 JSON Schema subset validation for shell-declared schemas.
  """

  alias Twelvgaige.Shell.Validation, as: V

  @supported_keywords ~w(type required properties items enum additionalProperties)
  @types ~w(object array string number integer boolean null)

  @type t :: %__MODULE__{root: map()}

  defstruct [:root]

  @spec from_map(term(), [term()]) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(schema, path \\ []) do
    with {:ok, root} <- normalize_schema(schema, path) do
      {:ok, %__MODULE__{root: root}}
    end
  end

  @spec validate(term()) :: :ok | {:error, Twelvgaige.Error.t()}
  def validate(schema) do
    case normalize_schema(schema, []) do
      {:ok, _schema} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp normalize_schema(schema, path) do
    with {:ok, schema} <- V.map(schema, path) do
      Enum.reduce_while(schema, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        with {:ok, key} <- schema_key(key, path),
             {:ok, value} <- normalize_keyword(key, value, path ++ [key]) do
          {:cont, {:ok, Map.put(acc, key, value)}}
        else
          {:error, _error} = error -> {:halt, error}
          :error -> {:halt, unsupported_keyword_error(key, path)}
        end
      end)
    end
  end

  defp schema_key(key, path) do
    with {:ok, key} <- V.key_to_string(key) do
      if key in @supported_keywords do
        {:ok, key}
      else
        unsupported_keyword_error(key, path ++ [key])
      end
    else
      :error ->
        V.error(:invalid_shell, "schema keyword names must be strings or atoms", path, %{
          field: inspect(key)
        })
    end
  end

  defp normalize_keyword("type", value, path) when is_binary(value) do
    if value in @types do
      {:ok, value}
    else
      V.error(:invalid_shell, "unsupported schema type #{inspect(value)}", path, %{
        allowed: @types
      })
    end
  end

  defp normalize_keyword("type", value, path) when is_atom(value) do
    normalize_keyword("type", Atom.to_string(value), path)
  end

  defp normalize_keyword("type", _value, path) do
    V.error(:invalid_shell, "schema type must be a string", path, %{expected: "string"})
  end

  defp normalize_keyword("required", value, path) do
    V.non_empty_string_list(value, path)
  end

  defp normalize_keyword("properties", value, path) do
    with {:ok, value} <- V.map(value, path) do
      Enum.reduce_while(value, {:ok, %{}}, fn {property, schema}, {:ok, acc} ->
        with {:ok, property} <- property_name(property, path),
             {:ok, schema} <- normalize_schema(schema, path ++ [property]) do
          {:cont, {:ok, Map.put(acc, property, schema)}}
        else
          {:error, _error} = error -> {:halt, error}
        end
      end)
    end
  end

  defp normalize_keyword("items", value, path), do: normalize_schema(value, path)

  defp normalize_keyword("enum", value, path) when is_list(value) do
    if Enum.all?(value, &json_value?/1) do
      {:ok, value}
    else
      V.error(:invalid_shell, "schema enum values must be JSON-compatible", path, %{
        expected: "json_value"
      })
    end
  end

  defp normalize_keyword("enum", _value, path),
    do: V.error(:invalid_shell, "schema enum must be a list", path)

  defp normalize_keyword("additionalProperties", value, _path) when is_boolean(value),
    do: {:ok, value}

  defp normalize_keyword("additionalProperties", _value, path) do
    V.error(:invalid_shell, "additionalProperties must be a boolean", path, %{expected: "boolean"})
  end

  defp property_name(property, path) do
    with {:ok, property} <- V.key_to_string(property),
         {:ok, property} <- V.non_empty_string(property, path) do
      {:ok, property}
    else
      :error ->
        V.error(:invalid_shell, "schema property names must be strings or atoms", path, %{
          field: inspect(property)
        })

      {:error, _error} = error ->
        error
    end
  end

  defp unsupported_keyword_error(key, path) do
    V.error(:unsupported_schema_keyword, "unsupported schema keyword #{inspect(key)}", path, %{
      keyword: key
    })
  end

  defp json_value?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value), do: true

  defp json_value?(value) when is_list(value), do: Enum.all?(value, &json_value?/1)

  defp json_value?(value) when is_map(value) do
    Enum.all?(value, fn {key, value} ->
      is_binary(key) and json_value?(value)
    end)
  end

  defp json_value?(_value), do: false
end
