defmodule Twelvgaige.CLI.Commands.ShotHelpers do
  @moduledoc false

  alias Twelvgaige.CLI.AuthoringIO
  alias Twelvgaige.Shell

  def write_refactored(
        result,
        opts,
        formatter,
        message \\ "refactored shell did not validate as a workflow"
      ) do
    with :ok <- AuthoringIO.write_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, formatter.(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            message,
            details: %{path: result.path}
          )

        AuthoringIO.format_write_error(error)

      {:error, error} ->
        AuthoringIO.format_write_error(error)
    end
  end

  def parsed_format(args, parser) do
    case parser.(args) do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  def csv_values(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def non_empty([]), do: nil

  def non_empty(values), do: values

  def empty_or_join([]), do: "none"

  def empty_or_join(values), do: Enum.join(values, ", ")
end
