defmodule Twelvgaige.Tool.Builtins.Authoring.PatchPlan do
  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Tool.Builtins.Authoring.Common
  alias Twelvgaige.Tool.Idempotency

  def name, do: "patch_plan"
  def description, do: "Create a digest-bound read-only patch plan from proposed changes."

  def input_schema do
    %{
      "type" => "object",
      "required" => ["path", "changes"],
      "properties" => %{
        "path" => %{"type" => "string"},
        "changes" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["action", "description"],
            "properties" => %{
              "action" => %{"type" => "string"},
              "description" => %{"type" => "string"},
              "target" => %{"type" => "string"}
            },
            "additionalProperties" => false
          }
        }
      },
      "additionalProperties" => false
    }
  end

  def safety_level, do: :read_only
  def idempotency, do: Idempotency.read_only()

  def execute(input, opts) do
    with {:ok, path} <- Common.path_input(input, opts),
         {:ok, contents} <- File.read(path),
         {:ok, changes} <- changes(input) do
      plan = %{
        "kind" => "twelvgaige.patch_plan",
        "path" => path,
        "base_digest" => sha256(contents),
        "changes" => changes
      }

      {:ok, Map.put(plan, "plan_digest", sha256(Jason.encode!(plan)))}
    else
      {:error, %Twelvgaige.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        Common.tool_error(:tool_non_retryable, "could not read patch target", %{
          reason: inspect(reason)
        })
    end
  end

  defp changes(input) do
    case Map.get(input, "changes") || Map.get(input, :changes) do
      changes when is_list(changes) and changes != [] -> {:ok, changes}
      _other -> Common.tool_error(:tool_input_invalid, "changes must be a non-empty list")
    end
  end

  defp sha256(contents) do
    digest = :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
    "sha256:#{digest}"
  end
end
