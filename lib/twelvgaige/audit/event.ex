defmodule Twelvgaige.Audit.Event do
  @moduledoc """
  JSON-safe projection for durable audit records.

  Store backends persist audit records as maps because early phases do not yet
  require a richer audit struct. This module gives IPC, CLI, and future HTTP
  handlers one place to normalize those records before JSON encoding.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor

  @type t :: map()

  @doc "Normalizes and redacts an audit event before persistence or output."
  @spec sanitize(t()) :: map()
  def sanitize(%{} = event), do: Redactor.redact_json(event)

  @doc "Normalizes and redacts a list of audit events."
  @spec sanitize_many([t()]) :: [map()]
  def sanitize_many(events) when is_list(events), do: Enum.map(events, &sanitize/1)

  @doc "Converts an audit event to a JSON-safe map shape."
  @spec to_map(t()) :: map()
  def to_map(%{} = event) do
    event
    |> normalize_value()
    |> Redactor.redact_json()
  end

  defp normalize_value(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp normalize_value(%Error{} = error), do: error |> Error.to_map() |> normalize_value()

  defp normalize_value(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_value()
  end

  defp normalize_value(%{} = map) do
    Map.new(map, fn {key, value} -> {normalize_key(key), normalize_value(value)} end)
  end

  defp normalize_value(values) when is_list(values), do: Enum.map(values, &normalize_value/1)
  defp normalize_value(value) when is_tuple(value), do: inspect(value)
  defp normalize_value(value) when is_pid(value), do: inspect(value)
  defp normalize_value(value) when is_reference(value), do: inspect(value)
  defp normalize_value(value) when is_function(value), do: inspect(value)
  defp normalize_value(value) when is_port(value), do: inspect(value)
  defp normalize_value(nil), do: nil
  defp normalize_value(value) when is_boolean(value), do: value
  defp normalize_value(value) when is_atom(value), do: Atom.to_string(value)
  defp normalize_value(value), do: value

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)
end
