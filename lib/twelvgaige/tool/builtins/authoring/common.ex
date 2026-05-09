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
    case fetch_value(input, field) do
      {:ok, value} when is_boolean(value) -> value
      _other -> default
    end
  end

  @spec optional_string(map(), String.t(), String.t()) :: String.t()
  def optional_string(input, field, default) do
    case fetch_value(input, field) do
      {:ok, value} when is_binary(value) -> value
      _other -> default
    end
  end

  @spec fetch_string(map(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def fetch_string(input, field) do
    case fetch_value(input, field) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      _other ->
        tool_error(:tool_input_invalid, "#{field} must be a non-empty string")
    end
  end

  defp fetch_value(input, field) do
    case Enum.find(input, fn {key, _value} -> key_string(key) == field end) do
      {_key, value} -> {:ok, value}
      nil -> :error
    end
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: inspect(key)

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

    cond do
      expanded == root or within_relative_path?(relative) ->
        with :ok <- ensure_no_symlink_components(expanded, root) do
          {:ok, expanded}
        end

      true ->
        tool_error(:tool_denied, "path is outside the allowed root", %{path: expanded, root: root})
    end
  end

  defp ensure_no_symlink_components(expanded_path, expanded_root) do
    relative = Path.relative_to(expanded_path, expanded_root)

    relative
    |> Path.split()
    |> Enum.reduce_while({:ok, expanded_root}, fn segment, {:ok, acc} ->
      current = Path.join(acc, segment)

      case File.lstat(current) do
        {:ok, %{type: :symlink}} ->
          {:halt,
           tool_error(:tool_denied, "symlink paths are denied", %{
             path: current,
             root: expanded_root
           })}

        {:ok, _stat} ->
          {:cont, {:ok, current}}

        {:error, :enoent} ->
          {:halt, {:ok, current}}

        {:error, reason} ->
          {:halt,
           tool_error(:tool_non_retryable, "could not inspect file path", %{
             path: current,
             reason: reason
           })}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp within_relative_path?(relative) do
    relative != ".." and
      not String.starts_with?(relative, "../") and
      Path.type(relative) == :relative
  end
end
