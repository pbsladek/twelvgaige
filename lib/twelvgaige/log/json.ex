defmodule Twelvgaige.Log.JSON do
  @moduledoc """
  Dependency-free JSON log event formatter.

  This is a formatting boundary, not a Logger backend. Runtime code can call it
  before writing to stderr, files, or a future Logger handler while keeping
  redaction and required field shape consistent.
  """

  alias Twelvgaige.Clock
  alias Twelvgaige.Error
  alias Twelvgaige.Redactor

  @reserved_keys ~w(timestamp level event message)

  @raw_value_keys MapSet.new(~w(
                      cookie
                      cookies
                      env
                      environment
                      full_command_environment
                      kubeconfig
                      llm_messages
                      llm_response
                      messages
                      prompt
                      prompts
                      raw_prompt
                      raw_response
                      stderr
                      stdout
                      tool_output
                      tool_result
                    ))

  @spec format(String.t() | atom(), String.t() | atom(), String.t(), map() | keyword(), keyword()) ::
          String.t()
  def format(level, event, message, metadata \\ %{}, opts \\ []) when is_binary(message) do
    to_map(level, event, message, metadata, opts)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  @spec to_map(String.t() | atom(), String.t() | atom(), String.t(), map() | keyword(), keyword()) ::
          map()
  def to_map(level, event, message, metadata \\ %{}, opts \\ []) when is_binary(message) do
    base = %{
      "timestamp" => timestamp(opts),
      "level" => stringify(level),
      "event" => stringify(event),
      "message" => message
    }

    metadata
    |> normalize_metadata()
    |> expand_error_fields()
    |> omit_raw_values()
    |> Redactor.redact_json()
    |> Map.drop(@reserved_keys)
    |> then(&Map.merge(base, &1))
  end

  defp timestamp(opts) do
    opts
    |> Keyword.get(:timestamp, Clock.utc_now())
    |> format_time()
  end

  defp normalize_metadata(metadata) when is_list(metadata) do
    metadata
    |> Enum.into(%{})
    |> normalize_metadata()
  end

  defp normalize_metadata(%{} = metadata), do: json_safe(metadata)
  defp normalize_metadata(_metadata), do: %{}

  defp expand_error_fields(%{"error" => %{} = error} = metadata) do
    metadata
    |> Map.delete("error")
    |> put_if_present("error_class", Map.get(error, "class"))
    |> put_if_present("error_reason", Map.get(error, "reason"))
    |> put_if_present("error_retryable", Map.get(error, "retryable"))
    |> put_if_present("error_safety_required", Map.get(error, "safety_required"))
  end

  defp expand_error_fields(metadata), do: metadata

  defp omit_raw_values(%{} = metadata) do
    Map.new(metadata, fn {key, value} ->
      if raw_value_key?(key) do
        {key, "[OMITTED]"}
      else
        {key, omit_raw_values(value)}
      end
    end)
  end

  defp omit_raw_values(values) when is_list(values), do: Enum.map(values, &omit_raw_values/1)
  defp omit_raw_values(value), do: value

  defp json_safe(%DateTime{} = time), do: format_time(time)
  defp json_safe(%Error{} = error), do: error |> Error.to_map() |> json_safe()

  defp json_safe(%_struct{} = struct) do
    struct
    |> Map.from_struct()
    |> json_safe()
  end

  defp json_safe(%{} = map) do
    Map.new(map, fn {key, value} -> {stringify(key), json_safe(value)} end)
  end

  defp json_safe(values) when is_list(values), do: Enum.map(values, &json_safe/1)
  defp json_safe(value) when is_boolean(value), do: value
  defp json_safe(nil), do: nil
  defp json_safe(value) when is_atom(value), do: stringify(value)
  defp json_safe(value), do: value

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  defp raw_value_key?(key) do
    normalized =
      key
      |> stringify()
      |> String.downcase()

    MapSet.member?(@raw_value_keys, normalized)
  end

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)

  defp format_time(%DateTime{} = time), do: DateTime.to_iso8601(time)
  defp format_time(time), do: to_string(time)
end
