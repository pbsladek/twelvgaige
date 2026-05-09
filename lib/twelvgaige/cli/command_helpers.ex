defmodule Twelvgaige.CLI.CommandHelpers do
  @moduledoc false

  @spec encode_line(term()) :: String.t()
  def encode_line(payload), do: Jason.encode!(payload) <> "\n"

  @spec format_command_error(term(), :human | :json) :: String.t()
  def format_command_error(%Twelvgaige.Error{} = error, format), do: format_error(error, format)

  def format_command_error(:daemon_unavailable, :json) do
    encode_line(%{error: %{reason: "daemon_unavailable", message: "daemon unavailable"}})
  end

  def format_command_error(:daemon_unavailable, :human), do: "daemon unavailable\n"

  def format_command_error(:not_found, :json) do
    encode_line(%{error: %{reason: "round_not_found", message: "round not found"}})
  end

  def format_command_error(:not_found, :human), do: "error: round not found\n"

  def format_command_error(error, :json) do
    encode_line(%{error: %{reason: "unknown", message: inspect(error)}})
  end

  def format_command_error(error, :human), do: "error: #{inspect(error)}\n"

  @spec format_error(Twelvgaige.Error.t(), :human | :json) :: String.t()
  def format_error(error, :json), do: encode_line(%{error: Twelvgaige.Error.to_map(error)})
  def format_error(error, :human), do: "error: #{error.message}\n"

  @spec format_warnings(term()) :: String.t()
  def format_warnings(warnings) do
    warnings
    |> List.wrap()
    |> case do
      [] -> "  none"
      warnings -> Enum.map_join(warnings, "\n", &"  - #{&1}")
    end
  end

  @spec parse_format(String.t()) :: :human | :json
  def parse_format("json"), do: :json
  def parse_format("human"), do: :human
  def parse_format(_other), do: :human

  @spec parse_human_json_format(String.t()) ::
          {:ok, :human | :json} | {:error, Twelvgaige.Error.t()}
  def parse_human_json_format("human"), do: {:ok, :human}
  def parse_human_json_format("json"), do: {:ok, :json}

  def parse_human_json_format(_format) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "format must be human or json")}
  end

  @spec root_opts(keyword()) :: keyword()
  def root_opts(opts) do
    case Keyword.get(opts, :root) do
      nil -> []
      root -> [root: root]
    end
  end

  @spec parse_non_negative_integer(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> :error
    end
  end

  @spec parse_positive_integer(String.t()) :: {:ok, pos_integer()} | :error
  def parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> :error
    end
  end

  @spec value(term(), atom() | String.t(), term()) :: term()
  def value(map, key, default \\ nil)

  def value(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def value(_map, _key, default), do: default
end
