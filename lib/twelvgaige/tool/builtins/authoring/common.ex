defmodule Twelvgaige.Tool.Builtins.Authoring.Common do
  @moduledoc false

  alias Twelvgaige.Error

  @spec root(keyword()) :: Path.t()
  def root(opts), do: opts |> Keyword.get(:root, File.cwd!()) |> Path.expand()

  @spec path_input(map(), keyword(), String.t()) :: {:ok, Path.t()} | {:error, Error.t()}
  def path_input(input, opts, field \\ "path") do
    with {:ok, path} <- fetch_string(input, field),
         {:ok, path} <- resolve_path(path, root(opts)) do
      {:ok, path}
    end
  end

  @spec optional_boolean(map(), String.t(), boolean()) :: boolean()
  def optional_boolean(input, field, default) do
    case Map.get(input, field) || Map.get(input, String.to_atom(field)) do
      value when is_boolean(value) -> value
      _other -> default
    end
  end

  @spec optional_string(map(), String.t(), String.t()) :: String.t()
  def optional_string(input, field, default) do
    case Map.get(input, field) || Map.get(input, String.to_atom(field)) do
      value when is_binary(value) -> value
      _other -> default
    end
  end

  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def fetch_string(input, field) do
    case Map.get(input, field) || Map.get(input, String.to_atom(field)) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        tool_error(:tool_input_invalid, "#{field} must be a non-empty string")
    end
  end

  @spec json_report(map()) :: map()
  def json_report(map), do: map

  @spec normalize_error(Error.t(), String.t()) :: Error.t()
  def normalize_error(%Error{class: :tool_error} = error, _message), do: error

  def normalize_error(%Error{} = error, message) do
    Error.new(:tool_error, :tool_non_retryable, message,
      retryable: false,
      details: %{source_error: Error.to_map(error)}
    )
  end

  @spec tool_error(atom(), String.t(), map()) :: {:error, Error.t()}
  def tool_error(reason, message, details \\ %{}) do
    {:error,
     Error.new(:tool_error, reason, message,
       retryable: false,
       safety_required: reason == :tool_denied,
       details: details
     )}
  end

  defp resolve_path(path, root) do
    expanded = Path.expand(path, root)
    relative = Path.relative_to(expanded, root)

    if expanded == root or within_relative_path?(relative) do
      {:ok, expanded}
    else
      tool_error(:tool_denied, "path is outside the allowed root", %{path: expanded, root: root})
    end
  end

  defp within_relative_path?(relative) do
    relative != ".." and
      not String.starts_with?(relative, "../") and
      Path.type(relative) == :relative
  end
end
