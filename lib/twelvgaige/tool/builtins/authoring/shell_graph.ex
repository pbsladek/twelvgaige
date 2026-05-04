defmodule Twelvgaige.Tool.Builtins.Authoring.ShellGraph do
  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Shell.Graph
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Tool.Builtins.Authoring.Common
  alias Twelvgaige.Tool.Idempotency

  def name, do: "shell_graph"
  def description, do: "Build the deterministic DAG graph for a workflow shell."

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
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         {:ok, graph} <- Graph.build(workflow) do
      {:ok, Map.put(Graph.to_map(graph), :path, path)}
    else
      {:ok, _other} ->
        Common.tool_error(:tool_input_invalid, "shell_graph requires a workflow shell")

      {:error, error} ->
        {:error, Common.normalize_error(error, "shell graph failed")}
    end
  end
end
