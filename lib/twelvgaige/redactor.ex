defmodule Twelvgaige.Redactor do
  @moduledoc """
  Small redaction helpers for early tool outputs.

  This is intentionally conservative and string-oriented for Phase 2. A richer
  structured redactor can replace it later, but tools already have a single
  place to call before returning data that may enter logs, audit, or LLM
  messages.
  """

  @secret_key_regex ~r/(?i)\b(api[_-]?key|client[_-]?secret|cookie|credential|password|secret|token)\b\s*[:=]\s*([^\s,;]+)/u
  @quoted_secret_key_regex ~r/(?i)(["']?\b(?:api[_-]?key|client[_-]?secret|cookie|credential|password|secret|token)\b["']?\s*:\s*)(?:"[^"]*"|'[^']*'|[^\s,;}]+)/u
  @bearer_regex ~r/(?i)\bbearer\s+[A-Za-z0-9._~+\/=-]+/u
  @non_secret_keys MapSet.new(~w(
    input_tokens
    output_tokens
    total_tokens
    token_budget
    token_usage
    tokens
  ))
  @summary_payload_keys MapSet.new(~w(
    body
    content
    input
    llm_messages
    messages
    output
    prompt
    raw
    raw_output
    raw_prompt
    raw_response
    stderr
    stdout
    tool_output
  ))

  @spec redact_text(String.t()) :: String.t()
  def redact_text(text) when is_binary(text) do
    text
    |> String.replace(@bearer_regex, "Bearer [REDACTED]")
    |> String.replace(@quoted_secret_key_regex, "\\1\"[REDACTED]\"")
    |> String.replace(@secret_key_regex, "\\1=[REDACTED]")
  end

  @spec redact_json(term()) :: term()
  def redact_json(%Twelvgaige.Error{} = error) do
    %{error | message: redact_text(error.message), details: redact_json(error.details)}
  end

  def redact_json(%DateTime{} = value), do: value
  def redact_json(%_struct{} = value), do: value

  def redact_json(value) when is_map(value) do
    Map.new(value, fn {key, value} ->
      if secret_key?(key) do
        {key, "[REDACTED]"}
      else
        {key, redact_json(value)}
      end
    end)
  end

  def redact_json(value) when is_list(value), do: Enum.map(value, &redact_json/1)
  def redact_json(value) when is_binary(value), do: redact_text(value)
  def redact_json(value), do: value

  @doc """
  Redacts secret-shaped values, then summarizes high-sensitivity payload fields.

  This is intended for opt-in local retention modes where operators want to keep
  recovery/accounting metadata without retaining raw prompts, messages, tool
  inputs, or tool outputs.
  """
  @spec summarize_sensitive_payloads(term()) :: term()
  def summarize_sensitive_payloads(value) do
    value
    |> redact_json()
    |> summarize_payloads()
  end

  defp summarize_payloads(%DateTime{} = value), do: value
  defp summarize_payloads(%_struct{} = value), do: value

  defp summarize_payloads(%{} = map) do
    Map.new(map, fn {key, value} ->
      if summary_payload_key?(key) do
        {key, payload_summary(value)}
      else
        {key, summarize_payloads(value)}
      end
    end)
  end

  defp summarize_payloads(values) when is_list(values),
    do: Enum.map(values, &summarize_payloads/1)

  defp summarize_payloads(value), do: value

  defp payload_summary(value) when is_binary(value) do
    %{
      "summary" => "omitted",
      "type" => "string",
      "bytes" => byte_size(value)
    }
  end

  defp payload_summary(value) when is_list(value) do
    %{
      "summary" => "omitted",
      "type" => "array",
      "items" => length(value)
    }
  end

  defp payload_summary(%{} = value) do
    %{
      "summary" => "omitted",
      "type" => "object",
      "keys" => value |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
    }
  end

  defp payload_summary(nil), do: nil

  defp payload_summary(value) do
    %{
      "summary" => "omitted",
      "type" => value |> type_name() |> Atom.to_string()
    }
  end

  defp summary_payload_key?(key) when is_atom(key), do: summary_payload_key?(Atom.to_string(key))

  defp summary_payload_key?(key) when is_binary(key),
    do: MapSet.member?(@summary_payload_keys, key)

  defp summary_payload_key?(_key), do: false

  defp type_name(value) when is_boolean(value), do: :boolean
  defp type_name(value) when is_integer(value), do: :integer
  defp type_name(value) when is_float(value), do: :float
  defp type_name(value) when is_atom(value), do: :atom
  defp type_name(_value), do: :term

  defp secret_key?(key) when is_atom(key), do: secret_key?(Atom.to_string(key))

  defp secret_key?(key) when is_binary(key) do
    key = String.downcase(key)

    not MapSet.member?(@non_secret_keys, key) and
      String.contains?(key, [
        "api_key",
        "apikey",
        "authorization",
        "bearer",
        "client_secret",
        "cookie",
        "credential",
        "password",
        "secret",
        "token"
      ])
  end

  defp secret_key?(_key), do: false
end
