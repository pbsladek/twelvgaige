defmodule Twelvgaige.Shell.Format do
  @moduledoc """
  Parser boundary for shell authoring formats.

  Format modules only parse source bytes into ordinary maps/lists. Shell
  validation, defaults, and workflow semantics stay in the shared loader and
  shell structs.
  """

  @callback extensions() :: [String.t()]
  @callback parse(binary(), Path.t()) :: {:ok, map()} | {:error, Twelvgaige.Error.t()}
end
