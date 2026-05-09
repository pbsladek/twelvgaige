defmodule Twelvgaige.Tool.RuntimeConfig do
  @moduledoc """
  Runtime tool policy loaded from process environment.

  This is intentionally narrow. It lets CLI and daemon rounds opt into local HTTP
  destinations without letting model output carry network policy.
  """

  @http_tools ["http_get", "http_post"]

  @spec merge(keyword()) :: keyword()
  def merge(opts) when is_list(opts) do
    case http_opts_from_env() do
      [] ->
        opts

      http_opts ->
        Keyword.update(
          opts,
          :tool_opts_by_name,
          http_tool_opts(http_opts),
          &merge_http_opts(&1, http_opts)
        )
    end
  end

  def merge(opts), do: opts

  defp http_opts_from_env do
    []
    |> maybe_put(:allowed_hosts, allowed_hosts(System.get_env("TWELVGAIGE_HTTP_ALLOWED_HOSTS")))
    |> maybe_put(:allow_private_hosts, boolean_env("TWELVGAIGE_HTTP_ALLOW_PRIVATE_HOSTS"))
    |> maybe_put(:timeout_ms, positive_integer_env("TWELVGAIGE_HTTP_TIMEOUT_MS"))
    |> maybe_put(:default_max_bytes, positive_integer_env("TWELVGAIGE_HTTP_DEFAULT_MAX_BYTES"))
  end

  defp allowed_hosts(nil), do: nil
  defp allowed_hosts(""), do: nil

  defp allowed_hosts(value) when is_binary(value) do
    hosts =
      value
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

    if hosts == [], do: nil, else: hosts
  end

  defp boolean_env(name) do
    case System.get_env(name) do
      value when value in ["1", "true", "TRUE", "yes", "YES", "on", "ON"] -> true
      value when value in ["0", "false", "FALSE", "no", "NO", "off", "OFF"] -> false
      _missing_or_invalid -> nil
    end
  end

  defp positive_integer_env(name) do
    case System.get_env(name) do
      value when is_binary(value) ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> integer
          _invalid -> nil
        end

      _missing ->
        nil
    end
  end

  defp http_tool_opts(http_opts), do: Map.new(@http_tools, &{&1, http_opts})

  defp merge_http_opts(existing, http_opts) do
    existing
    |> normalize_by_name()
    |> then(fn by_name ->
      Enum.reduce(@http_tools, by_name, fn tool, acc ->
        Map.update(acc, tool, http_opts, &put_new_opts(&1, http_opts))
      end)
    end)
  end

  defp normalize_by_name(%{} = map) do
    Map.new(map, fn {key, value} -> {key_string(key), normalize_tool_opts(value)} end)
  end

  defp normalize_by_name(list) when is_list(list) do
    Map.new(list, fn
      {key, value} -> {key_string(key), normalize_tool_opts(value)}
      other -> {inspect(other), []}
    end)
  end

  defp normalize_by_name(_other), do: %{}

  defp normalize_tool_opts(value) when is_list(value), do: value
  defp normalize_tool_opts(_value), do: []

  defp put_new_opts(existing, defaults) do
    Enum.reduce(defaults, existing, fn {key, value}, acc ->
      Keyword.put_new(acc, key, value)
    end)
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: inspect(key)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
