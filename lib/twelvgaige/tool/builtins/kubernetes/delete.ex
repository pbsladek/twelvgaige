defmodule Twelvgaige.Tool.Builtins.Kubernetes.Delete do
  @moduledoc """
  Delete a single namespaced Kubernetes object through structured `kubectl delete` argv.
  """

  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Tool.Builtins.Kubernetes.Common
  alias Twelvgaige.Tool.Idempotency

  @resources ~w(pods deployments replicasets statefulsets daemonsets services ingress jobs cronjobs configmaps)

  @impl true
  def name, do: "kubectl_delete"

  @impl true
  def description, do: "Delete one explicitly named namespaced Kubernetes object."

  @impl true
  def input_schema do
    Common.write_schema(["context", "namespace", "resource", "name", "confirm"], @resources)
  end

  @impl true
  def safety_level, do: :destructive

  @impl true
  def idempotency do
    Idempotency.non_idempotent(
      reconciliation_strategy: :manual,
      side_effect_phase: :unknown
    )
  end

  @impl true
  def execute(input, opts) do
    with :ok <- Common.require_confirm(input, name()),
         {:ok, target} <- Common.write_target(input, opts, @resources),
         :ok <- Common.require_name(target, name()),
         {:ok, max_bytes} <- Common.max_bytes(input, opts),
         {:ok, result} <- Common.run_kubectl(args(target), target, opts),
         {excerpt, truncated} <- Common.bounded_excerpt(result.stdout, max_bytes) do
      {:ok,
       Common.output_base(target, "delete", result.duration_ms)
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
    Common.base_args(target) ++ ["delete", target.resource, target.name]
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
