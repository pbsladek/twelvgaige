defmodule Twelvgaige.Tool.Builtins.Authoring.ShellLint do
  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Shell.Lint
  alias Twelvgaige.Tool.Builtins.Authoring.Common
  alias Twelvgaige.Tool.Idempotency

  def name, do: "shell_lint"
  def description, do: "Run shell lint over a workflow shell or shell directory."

  def input_schema do
    %{
      "type" => "object",
      "required" => ["path"],
      "properties" => %{
        "path" => %{"type" => "string"},
        "strict" => %{"type" => "boolean"}
      },
      "additionalProperties" => false
    }
  end

  def safety_level, do: :read_only
  def idempotency, do: Idempotency.read_only()

  def execute(input, opts) do
    with {:ok, path} <- Common.path_input(input, opts),
         {:ok, report} <-
           Lint.run_target(path, strict?: Common.optional_boolean(input, "strict", false)) do
      {:ok, Lint.to_map(report)}
    else
      {:error, error} -> {:error, Common.normalize_error(error, "shell lint failed")}
    end
  end
end
