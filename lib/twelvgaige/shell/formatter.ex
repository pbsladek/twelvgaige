defmodule Twelvgaige.Shell.Formatter do
  @moduledoc """
  Canonical shell formatting for authoring and CI.

  Formatting is deterministic and comment-dropping by design. It loads a shell
  through the normal parser, emits the canonical `Shell.Document` form in the
  source file's format, and reports whether the file would change.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Shell.Loader
  alias Twelvgaige.Shell.Workflow

  @type result :: %{
          path: Path.t(),
          format: Document.format(),
          kind: :workflow | :agent,
          id: String.t(),
          version: String.t() | nil,
          changed?: boolean(),
          original: String.t(),
          candidate: String.t(),
          diff: String.t()
        }

  @spec format(term(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def format(path, opts \\ [])

  def format(path, opts) when is_binary(path) do
    with {:ok, format} <- format_for_path(path),
         {:ok, original} <- read_file(path),
         {:ok, shell} <- Loader.load(path),
         {:ok, candidate} <- Document.encode(shell, format) do
      {:ok,
       %{
         path: path,
         format: format,
         kind: shell_kind(shell),
         id: shell.id,
         version: shell_version(shell),
         changed?: original != candidate,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end)
       }}
    end
  end

  def format(_path, _opts) do
    {:error, Error.new(:input_error, :invalid_shell, "shell fmt path must be a string")}
  end

  @spec to_map(result()) :: map()
  def to_map(result) do
    %{
      path: result.path,
      format: Atom.to_string(result.format),
      kind: Atom.to_string(result.kind),
      id: result.id,
      version: result.version,
      changed: result.changed?,
      diff: result.diff
    }
  end

  defp format_for_path(path) do
    case path |> Path.extname() |> String.downcase() do
      ".json" ->
        {:ok, :json}

      ".toml" ->
        {:ok, :toml}

      ".yaml" ->
        {:ok, :yaml}

      ".yml" ->
        {:ok, :yaml}

      extension ->
        invalid("unsupported shell file extension for shell fmt", %{extension: extension})
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        invalid("unable to read shell file", %{path: path, reason: inspect(reason)})
    end
  end

  defp shell_kind(%Workflow{}), do: :workflow
  defp shell_kind(%Agent{}), do: :agent

  defp shell_version(%Workflow{version: version}), do: version
  defp shell_version(%Agent{version: version}), do: version

  defp unified_diff(path, original, candidate) do
    original_lines = String.split(original, "\n", trim: false)
    candidate_lines = String.split(candidate, "\n", trim: false)
    max = max(length(original_lines), length(candidate_lines))

    body =
      0..(max - 1)
      |> Enum.flat_map(fn index ->
        old = Enum.at(original_lines, index)
        new = Enum.at(candidate_lines, index)

        cond do
          old == new and not is_nil(old) -> [" #{old}"]
          is_nil(old) -> ["+#{new}"]
          is_nil(new) -> ["-#{old}"]
          true -> ["-#{old}", "+#{new}"]
        end
      end)
      |> Enum.reject(&(&1 in [" ", "+", "-"]))
      |> Enum.join("\n")

    """
    --- #{path}
    +++ #{path}
    @@
    #{body}
    """
  end

  defp invalid(message, details) do
    {:error, Error.new(:input_error, :invalid_shell, message, details: details)}
  end
end
