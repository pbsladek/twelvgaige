defmodule Twelvgaige.Tool.Builtins.Kubernetes.Scale do
  @moduledoc """
  Scale a namespaced Kubernetes workload through structured `kubectl scale` argv.
  """

  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Tool.Builtins.Kubernetes.Common
  alias Twelvgaige.Tool.Idempotency

  @resources ~w(deployments replicasets statefulsets)

  @impl true
  def name, do: "kubectl_scale"

  @impl true
  def description, do: "Set replicas on a namespaced Kubernetes workload."

  @impl true
  def input_schema do
    Common.write_schema(["context", "namespace", "resource", "name", "replicas"], @resources)
  end

  @impl true
  def safety_level, do: :idempotent_write

  @impl true
  def idempotency do
    Idempotency.idempotent(
      reconciliation_strategy: :read_after_write,
      side_effect_phase: :unknown
    )
  end

  @impl true
  def execute(input, opts) do
    with {:ok, target} <- Common.write_target(input, opts, @resources),
         :ok <- Common.require_name(target, name()),
         {:ok, replicas} <- Common.non_negative_integer(input, "replicas"),
         {:ok, max_bytes} <- Common.max_bytes(input, opts),
         {:ok, result} <- Common.run_kubectl(args(target, replicas), target, opts),
         {excerpt, truncated} <- Common.bounded_excerpt(result.stdout, max_bytes) do
      {:ok,
       Common.output_base(target, "scale", result.duration_ms)
       |> Map.merge(%{
         replicas: replicas,
         text_excerpt: excerpt,
         truncated: truncated,
         output_bytes: byte_size(excerpt),
         exit_status: result.status
       })
       |> stringify_keys()}
    end
  end

  defp args(target, replicas) do
    Common.base_args(target) ++
      [
        "scale",
        target.resource,
        target.name,
        "--replicas",
        Integer.to_string(replicas)
      ]
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
