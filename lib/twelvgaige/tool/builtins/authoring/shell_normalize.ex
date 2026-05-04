defmodule Twelvgaige.Tool.Builtins.Authoring.ShellNormalize do
  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Tool.Builtins.Authoring.Common
  alias Twelvgaige.Tool.Idempotency

  def name, do: "shell_normalize"
  def description, do: "Return a normalized workflow or agent shell document."

  def input_schema do
    %{
      "type" => "object",
      "required" => ["path"],
      "properties" => %{
        "path" => %{"type" => "string"},
        "format" => %{"type" => "string", "enum" => ["map", "json", "yaml", "toml"]}
      },
      "additionalProperties" => false
    }
  end

  def safety_level, do: :read_only
  def idempotency, do: Idempotency.read_only()

  def execute(input, opts) do
    with {:ok, path} <- Common.path_input(input, opts),
         {:ok, shell} <- Twelvgaige.validate_shell(path),
         {:ok, output} <- normalized_output(shell, Common.optional_string(input, "format", "map")) do
      {:ok, %{"path" => path, "format" => output.format, "document" => output.document}}
    else
      {:error, error} -> {:error, Common.normalize_error(error, "shell normalize failed")}
    end
  end

  defp normalized_output(shell, "map"),
    do: {:ok, %{format: "map", document: Document.to_map(shell)}}

  defp normalized_output(shell, format) when format in ["json", "yaml", "toml"] do
    with {:ok, contents} <- Document.encode(shell, String.to_existing_atom(format)) do
      {:ok, %{format: format, document: contents}}
    end
  end

  defp normalized_output(_shell, _format) do
    Common.tool_error(:tool_input_invalid, "format must be map, json, yaml, or toml")
  end
end
