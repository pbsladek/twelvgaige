defmodule Twelvgaige.Tool.Builtins.Authoring.ToolCatalogRead do
  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Tool.Catalog
  alias Twelvgaige.Tool.Builtins.Authoring.Common
  alias Twelvgaige.Tool.Idempotency

  def name, do: "tool_catalog_read"
  def description, do: "Read metadata for one built-in tool or all built-in tools."

  def input_schema do
    %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{"name" => %{"type" => "string"}},
      "additionalProperties" => false
    }
  end

  def safety_level, do: :read_only
  def idempotency, do: Idempotency.read_only()

  def execute(input, _opts) do
    with {:ok, name} <- Common.fetch_string(input, "name"),
         {:ok, result} <- read_tool(name) do
      {:ok, result}
    else
      {:error, error} -> {:error, Common.normalize_error(error, "tool catalog read failed")}
    end
  end

  defp read_tool("all") do
    tools =
      Catalog.names()
      |> Enum.map(fn name ->
        {:ok, metadata} = Catalog.metadata(name)
        metadata_map(metadata)
      end)

    {:ok, %{"tools" => tools}}
  end

  defp read_tool(name) do
    with {:ok, metadata} <- Catalog.metadata(name) do
      {:ok, %{"tool" => metadata_map(metadata)}}
    end
  end

  defp metadata_map(metadata) do
    %{
      "name" => metadata.name,
      "description" => metadata.description,
      "safety_level" => Atom.to_string(metadata.safety_level),
      "idempotency" => %{
        "class" => Atom.to_string(metadata.idempotency.class),
        "reconciliation_strategy" => Atom.to_string(metadata.idempotency.reconciliation_strategy),
        "side_effect_phase" => Atom.to_string(metadata.idempotency.side_effect_phase),
        "requires_key" => metadata.idempotency.requires_key?
      },
      "input_schema" => metadata.input_schema
    }
  end
end
