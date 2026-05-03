defmodule Twelvgaige.Tool.InputValidator do
  @moduledoc """
  Small JSON Schema subset validator for tool input maps.

  This mirrors the shell schema subset used in Phase 1 and intentionally avoids
  dynamic code evaluation. It validates values, while `Twelvgaige.Shell.Schema`
  validates schema shape.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Schema.ValueValidator
  alias Twelvgaige.Shell.Schema

  @spec validate(term(), Schema.t() | map()) :: :ok | {:error, Error.t()}
  def validate(value, schema) do
    ValueValidator.validate(value, schema,
      error_class: :tool_error,
      error_reason: :tool_input_invalid,
      schema_error_class: :internal_error
    )
  end
end
