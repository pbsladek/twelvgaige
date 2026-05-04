defmodule Twelvgaige.Tool.Builtins.Authoring.ShellImpact do
  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Shell.Impact
  alias Twelvgaige.Tool.Builtins.Authoring.Common
  alias Twelvgaige.Tool.Idempotency

  def name, do: "shell_impact"
  def description, do: "Report workflows impacted by an agent, tool, or template reference."

  def input_schema do
    %{
      "type" => "object",
      "required" => ["path", "selector_kind", "selector_value"],
      "properties" => %{
        "path" => %{"type" => "string"},
        "selector_kind" => %{"type" => "string", "enum" => ["agent", "tool", "template"]},
        "selector_value" => %{"type" => "string"}
      },
      "additionalProperties" => false
    }
  end

  def safety_level, do: :read_only
  def idempotency, do: Idempotency.read_only()

  def execute(input, opts) do
    with {:ok, path} <- Common.path_input(input, opts),
         {:ok, selector_kind} <- selector_kind(input),
         {:ok, selector_value} <- Common.fetch_string(input, "selector_value"),
         {:ok, report} <- Impact.run(path, selector_kind, selector_value) do
      {:ok, Impact.to_map(report)}
    else
      {:error, error} -> {:error, Common.normalize_error(error, "shell impact failed")}
    end
  end

  defp selector_kind(input) do
    case Common.optional_string(input, "selector_kind", "") do
      "agent" ->
        {:ok, :agent}

      "tool" ->
        {:ok, :tool}

      "template" ->
        {:ok, :template}

      _other ->
        Common.tool_error(:tool_input_invalid, "selector_kind must be agent, tool, or template")
    end
  end
end
