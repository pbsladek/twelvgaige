defmodule Twelvgaige.Tool.Builtins.Authoring.ShellValidate do
  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Tool.Builtins.Authoring.Common
  alias Twelvgaige.Tool.Idempotency

  def name, do: "shell_validate"

  def description,
    do: "Validate a workflow or agent shell file and return its canonical identity."

  def input_schema do
    %{
      "type" => "object",
      "required" => ["path"],
      "properties" => %{"path" => %{"type" => "string"}},
      "additionalProperties" => false
    }
  end

  def safety_level, do: :read_only
  def idempotency, do: Idempotency.read_only()

  def execute(input, opts) do
    with {:ok, path} <- Common.path_input(input, opts),
         {:ok, shell} <- Twelvgaige.validate_shell(path) do
      {:ok,
       %{
         "path" => path,
         "kind" => shell.kind |> Atom.to_string(),
         "id" => shell.id,
         "version" => Map.get(shell, :version),
         "document" => Document.to_map(shell)
       }}
    else
      {:error, error} -> {:error, Common.normalize_error(error, "shell validation failed")}
    end
  end
end
