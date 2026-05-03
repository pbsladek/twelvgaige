defmodule Twelvgaige.Log do
  @moduledoc """
  Runtime log emission boundary.

  JSON emission is opt-in through `:twelvgaige, :log_format` or
  `TWELVGAIGE_LOG_FORMAT=json`. The default is no-op so tests and foreground
  use stay quiet unless logging is explicitly enabled.
  """

  alias Twelvgaige.Log.File
  alias Twelvgaige.Log.JSON

  @spec emit(String.t() | atom(), String.t() | atom(), String.t(), map() | keyword(), keyword()) ::
          :ok
  def emit(level, event, message, metadata \\ %{}, opts \\ []) do
    case log_format(opts) do
      :json ->
        line = JSON.format(level, event, message, metadata, opts)
        write_json_line(line, opts)
        :ok

      _other ->
        :ok
    end
  end

  defp log_format(opts) do
    Keyword.get(opts, :format) ||
      Application.get_env(:twelvgaige, :log_format) ||
      env_log_format()
  end

  defp env_log_format do
    case System.get_env("TWELVGAIGE_LOG_FORMAT") do
      "json" -> :json
      _other -> nil
    end
  end

  defp write_json_line(line, opts) do
    cond do
      Keyword.has_key?(opts, :io) ->
        opts |> Keyword.fetch!(:io) |> IO.write(line)

      path = log_path(opts) ->
        _result = File.write_line(path, line, log_max_file_bytes(opts))
        :ok

      true ->
        :twelvgaige
        |> Application.get_env(:log_io, :standard_error)
        |> IO.write(line)
    end
  end

  defp log_path(opts) do
    Keyword.get(opts, :path) ||
      Keyword.get(opts, :file) ||
      Application.get_env(:twelvgaige, :log_path) ||
      System.get_env("TWELVGAIGE_LOG_PATH")
  end

  defp log_max_file_bytes(opts) do
    Keyword.get(opts, :max_file_bytes) ||
      Application.get_env(:twelvgaige, :log_max_file_bytes) ||
      env_positive_integer("TWELVGAIGE_LOG_MAX_BYTES")
  end

  defp env_positive_integer(name) do
    case System.get_env(name) do
      nil ->
        nil

      value ->
        case Integer.parse(value) do
          {integer, ""} when integer > 0 -> integer
          _invalid -> nil
        end
    end
  end
end
