defmodule Twelvgaige.Authoring.Root do
  @moduledoc """
  Resolves the traphouse root for authoring commands.

  Runtime shell execution does not depend on this module. It exists so
  authoring commands have one explicit no-cross-root contract.
  """

  alias Twelvgaige.Error

  @type source :: :explicit | :cwd_traphouse | :none
  @type resolution :: %{
          root: Path.t() | nil,
          source: source(),
          user_local_included?: boolean()
        }

  @spec resolve(keyword()) :: {:ok, resolution()} | {:error, Error.t()}
  def resolve(opts \\ []) do
    cond do
      root = Keyword.get(opts, :root) ->
        explicit_root(root)

      root = find_cwd_traphouse(File.cwd!()) ->
        {:ok, resolution(root, :cwd_traphouse)}

      true ->
        {:ok, resolution(nil, :none)}
    end
  end

  @spec ensure_within_root(Path.t(), resolution()) :: :ok | {:error, Error.t()}
  def ensure_within_root(_path, %{root: nil}), do: :ok

  def ensure_within_root(path, %{root: root, source: source}) when is_binary(root) do
    expanded_path = Path.expand(path)
    expanded_root = Path.expand(root)
    relative = Path.relative_to(expanded_path, expanded_root)

    if expanded_path == expanded_root or within_relative_path?(relative) do
      :ok
    else
      {:error,
       Error.new(:input_error, :invalid_shell, "path is outside the resolved traphouse root",
         details: %{path: expanded_path, root: expanded_root, root_source: Atom.to_string(source)}
       )}
    end
  end

  @spec to_map(resolution()) :: map()
  def to_map(%{root: root, source: source, user_local_included?: user_local_included?}) do
    %{
      root: root,
      source: Atom.to_string(source),
      user_local_included: user_local_included?
    }
  end

  defp explicit_root(root) when is_binary(root) do
    expanded = Path.expand(root)

    if File.dir?(expanded) do
      {:ok, resolution(expanded, :explicit)}
    else
      {:error,
       Error.new(:input_error, :invalid_shell, "traphouse root does not exist",
         details: %{root: expanded}
       )}
    end
  end

  defp resolution(root, source) do
    %{root: root, source: source, user_local_included?: false}
  end

  defp find_cwd_traphouse(dir) do
    candidate = Path.join(dir, "traphouse")

    cond do
      File.dir?(candidate) ->
        Path.expand(candidate)

      parent = parent_dir(dir) ->
        find_cwd_traphouse(parent)

      true ->
        nil
    end
  end

  defp parent_dir(dir) do
    parent = Path.dirname(dir)
    if parent == dir, do: nil, else: parent
  end

  defp within_relative_path?(relative) do
    relative != ".." and
      not String.starts_with?(relative, "../") and
      Path.type(relative) == :relative
  end
end
