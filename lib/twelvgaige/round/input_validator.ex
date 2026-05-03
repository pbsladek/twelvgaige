defmodule Twelvgaige.Round.InputValidator do
  @moduledoc """
  Runtime input validation for workflow rounds.

  Shell loading validates that `input_schema` itself uses the supported schema
  subset. This module validates a concrete round input against that schema
  before any shot can fire.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Schema.ValueValidator
  alias Twelvgaige.Shell.Workflow

  @spec validate(Workflow.t(), map()) :: :ok | {:error, Error.t()}
  def validate(%Workflow{input_schema: nil}, input) when is_map(input), do: :ok

  def validate(%Workflow{input_schema: schema}, input) when is_map(input) do
    ValueValidator.validate(input, schema,
      error_class: :input_error,
      error_reason: :input_schema_violation,
      retryable: false,
      schema_error_class: :compile_error
    )
  end

  def validate(%Workflow{}, _input) do
    {:error,
     Error.new(:input_error, :invalid_shell, "round input must be a map",
       details: %{expected: "map"}
     )}
  end
end
