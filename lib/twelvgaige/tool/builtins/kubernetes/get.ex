defmodule Twelvgaige.Tool.Builtins.Kubernetes.Get do
  @moduledoc """
  Read Kubernetes resources through `kubectl get -o json`.
  """

  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Tool.Builtins.Kubernetes.Common
  alias Twelvgaige.Tool.Idempotency

  @impl true
  def name, do: "kubectl_get"

  @impl true
  def description, do: "Read Kubernetes resources as JSON through structured kubectl argv."

  @impl true
  def input_schema, do: Common.common_schema(["context", "resource"])

  @impl true
  def safety_level, do: :read_only

  @impl true
  def idempotency, do: Idempotency.read_only()

  @impl true
  def execute(input, opts) do
    with {:ok, target} <- Common.target(input, opts),
         {:ok, max_bytes} <- Common.max_bytes(input, opts),
         {:ok, result} <- Common.run_kubectl(args(target), target, opts),
         {excerpt, truncated} <- Common.bounded_excerpt(result.stdout, max_bytes),
         {:ok, decoded} <- maybe_decode_json(result.stdout, truncated, target) do
      items =
        decoded
        |> Map.get("items", [])
        |> Common.limit_items(input)

      {:ok,
       Common.output_base(target, "get", result.duration_ms)
       |> Map.merge(%{
         items: items,
         summary: summary(decoded, items),
         raw_excerpt: if(truncated, do: excerpt, else: nil),
         truncated: truncated,
         output_bytes: byte_size(excerpt),
         exit_status: result.status
       })
       |> stringify_keys()}
    end
  end

  defp args(target) do
    Common.base_args(target) ++
      ["get", target.resource] ++
      name_arg(target.name) ++
      Common.selector_args(target) ++
      ["-o", "json"]
  end

  defp name_arg(nil), do: []
  defp name_arg(name), do: [name]

  defp maybe_decode_json(_stdout, true, _target), do: {:ok, %{"items" => []}}
  defp maybe_decode_json(stdout, false, target), do: Common.decode_json(stdout, target)

  defp summary(%{"kind" => kind} = decoded, items) do
    %{
      "kind" => kind,
      "item_count" => length(items),
      "resource_version" => get_in(decoded, ["metadata", "resourceVersion"])
    }
  end

  defp summary(_decoded, items), do: %{"item_count" => length(items)}

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
