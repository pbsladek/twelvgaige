defmodule Twelvgaige.Authoring.ShotRefactor.Validation do
  @moduledoc false

  alias Twelvgaige.Error

  @spec format_for_path(Path.t()) :: {:ok, :json | :toml | :yaml} | {:error, Error.t()}
  def format_for_path(path) when is_binary(path) do
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
        invalid("unsupported shell file extension for shot refactor", %{extension: extension})
    end
  end

  @spec unified_diff(Path.t(), String.t(), String.t()) :: String.t()
  def unified_diff(path, original, candidate) do
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

  @spec invalid(String.t(), map()) :: {:error, Error.t()}
  def invalid(message, details \\ %{}) do
    {:error, Error.new(:input_error, :invalid_shell, message, details: details)}
  end
end
