defmodule Twelvgaige.Tool.Builtins.Kubernetes.Describe do
  @moduledoc """
  Read bounded `kubectl describe` output.
  """

  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Tool.Builtins.Kubernetes.Common
  alias Twelvgaige.Tool.Idempotency

  @impl true
  def name, do: "kubectl_describe"

  @impl true
  def description, do: "Describe a Kubernetes resource with bounded redacted text output."

  @impl true
  def input_schema, do: Common.common_schema(["context", "resource", "name"])

  @impl true
  def safety_level, do: :read_only

  @impl true
  def idempotency, do: Idempotency.read_only()

  @impl true
  def execute(input, opts) do
    with {:ok, target} <- Common.target(input, opts),
         :ok <- require_name(target),
         {:ok, max_bytes} <- Common.max_bytes(input, opts),
         {:ok, result} <- Common.run_kubectl(args(target), target, opts),
         {excerpt, truncated} <- Common.bounded_excerpt(result.stdout, max_bytes) do
      {:ok,
       Common.output_base(target, "describe", result.duration_ms)
       |> Map.merge(%{
         text_excerpt: excerpt,
         truncated: truncated,
         output_bytes: byte_size(excerpt),
         exit_status: result.status
       })
       |> stringify_keys()}
    end
  end

  defp args(target) do
    Common.base_args(target) ++ ["describe", target.resource, target.name]
  end

  defp require_name(%{name: name}) when is_binary(name), do: :ok

  defp require_name(target) do
    Common.tool_error(:tool_input_invalid, "name is required for kubectl_describe", %{
      resource: target.resource
    })
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
