defmodule Twelvgaige.Shell.Format.YAML do
  @moduledoc false

  @behaviour Twelvgaige.Shell.Format

  alias Twelvgaige.Shell.Validation, as: V

  @impl true
  def extensions, do: [".yaml", ".yml"]

  @impl true
  def parse(contents, path) when is_binary(contents) do
    with {:ok, document} <- parse_document(contents, path) do
      case normalize_yaml(document) do
        map when is_map(map) ->
          {:ok, map}

        _other ->
          V.error(:invalid_shell, "YAML shell document must be a map", [], %{
            file_path: path,
            format: "yaml"
          })
      end
    end
  end

  defp parse_document(contents, path) do
    case :yamerl_constr.string(String.to_charlist(contents), [:str_node_as_binary]) do
      [document] ->
        {:ok, document}

      [] ->
        V.error(:invalid_shell, "YAML shell file is empty", [], %{
          file_path: path,
          format: "yaml"
        })

      _documents ->
        V.error(:invalid_shell, "YAML shell file must contain exactly one document", [], %{
          file_path: path,
          format: "yaml"
        })
    end
  rescue
    error ->
      V.error(:invalid_shell, "failed to parse YAML shell file", [], %{
        file_path: path,
        format: "yaml",
        reason: Exception.message(error)
      })
  catch
    kind, reason ->
      V.error(:invalid_shell, "failed to parse YAML shell file", [], %{
        file_path: path,
        format: "yaml",
        reason: inspect({kind, reason})
      })
  end

  defp normalize_yaml(value) when is_list(value) do
    if keyword_mapping?(value) do
      Map.new(value, fn {key, child} -> {normalize_key(key), normalize_yaml(child)} end)
    else
      Enum.map(value, &normalize_yaml/1)
    end
  end

  defp normalize_yaml(value), do: value

  defp keyword_mapping?([]), do: false

  defp keyword_mapping?(value) do
    Enum.all?(value, fn
      {_key, _value} -> true
      _other -> false
    end)
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key), do: to_string(key)
end
