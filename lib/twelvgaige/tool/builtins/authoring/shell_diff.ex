defmodule Twelvgaige.Tool.Builtins.Authoring.ShellDiff do
  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Tool.Builtins.Authoring.Common
  alias Twelvgaige.Tool.Idempotency

  def name, do: "shell_diff"
  def description, do: "Compare two shell files by normalized canonical document."

  def input_schema do
    %{
      "type" => "object",
      "required" => ["left_path", "right_path"],
      "properties" => %{
        "left_path" => %{"type" => "string"},
        "right_path" => %{"type" => "string"}
      },
      "additionalProperties" => false
    }
  end

  def safety_level, do: :read_only
  def idempotency, do: Idempotency.read_only()

  def execute(input, opts) do
    with {:ok, left_path} <- Common.path_input(input, opts, "left_path"),
         {:ok, right_path} <- Common.path_input(input, opts, "right_path"),
         {:ok, left} <- Twelvgaige.validate_shell(left_path),
         {:ok, right} <- Twelvgaige.validate_shell(right_path) do
      left_doc = Document.to_map(left)
      right_doc = Document.to_map(right)

      {:ok,
       %{
         "left_path" => left_path,
         "right_path" => right_path,
         "equal" => left_doc == right_doc,
         "left_digest" => digest(left_doc),
         "right_digest" => digest(right_doc),
         "changed_top_level_keys" => changed_top_level_keys(left_doc, right_doc)
       }}
    else
      {:error, error} -> {:error, Common.normalize_error(error, "shell diff failed")}
    end
  end

  defp digest(document) do
    encoded = Jason.encode!(document)
    "sha256:" <> (:crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower))
  end

  defp changed_top_level_keys(left, right) do
    (Map.keys(left) ++ Map.keys(right))
    |> Enum.uniq()
    |> Enum.filter(&(Map.get(left, &1) != Map.get(right, &1)))
    |> Enum.sort()
  end
end
