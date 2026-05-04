defmodule Twelvgaige.Tool.Builtins.Authoring.ShellInventory do
  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Shell.Inventory
  alias Twelvgaige.Tool.Builtins.Authoring.Common
  alias Twelvgaige.Tool.Idempotency

  def name, do: "shell_inventory"
  def description, do: "Summarize workflow and agent shells in a directory."

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
         {:ok, report} <- Inventory.run(path) do
      {:ok, Inventory.to_map(report)}
    else
      {:error, error} -> {:error, Common.normalize_error(error, "shell inventory failed")}
    end
  end
end
