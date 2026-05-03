defmodule Twelvgaige.Tool.Builtins.Kubernetes.Logs do
  @moduledoc """
  Read bounded Kubernetes pod logs.
  """

  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Tool.Builtins.Kubernetes.Common
  alias Twelvgaige.Tool.Idempotency

  @default_tail_lines 200
  @max_tail_lines 1_000
  @max_since_seconds 86_400

  @impl true
  def name, do: "kubectl_logs"

  @impl true
  def description, do: "Read bounded, redacted Kubernetes pod logs."

  @impl true
  def input_schema do
    schema = Common.common_schema(["context", "namespace", "name"])
    put_in(schema, ["properties", "resource"], %{"type" => "string", "enum" => ["pods"]})
  end

  @impl true
  def safety_level, do: :read_only

  @impl true
  def idempotency, do: Idempotency.read_only()

  @impl true
  def execute(input, opts) do
    input = Map.put_new(input, "resource", "pods")

    with {:ok, target} <- Common.target(input, opts),
         :ok <- require_pod_name(target),
         {:ok, max_bytes} <- Common.max_bytes(input, opts),
         {:ok, tail_lines} <-
           Common.positive_integer(input, "tail_lines", @default_tail_lines, @max_tail_lines),
         {:ok, since_seconds} <- since_seconds(input),
         {:ok, result} <-
           Common.run_kubectl(args(target, input, tail_lines, since_seconds), target, opts),
         {excerpt, truncated_by_bytes} <- Common.bounded_excerpt(result.stdout, max_bytes) do
      lines = split_lines(excerpt)

      {:ok,
       Common.output_base(target, "logs", result.duration_ms)
       |> Map.merge(%{
         container: Common.optional_string(input, "container"),
         tail_lines: tail_lines,
         since_seconds: since_seconds,
         line_count: length(lines),
         output_bytes: byte_size(excerpt),
         truncated: truncated_by_bytes,
         log_excerpt: excerpt,
         lines: lines,
         exit_status: result.status
       })
       |> stringify_keys()}
    end
  end

  defp args(target, input, tail_lines, since_seconds) do
    Common.base_args(target) ++
      ["logs", target.name, "--tail", Integer.to_string(tail_lines)] ++
      since_arg(since_seconds) ++
      container_arg(Common.optional_string(input, "container"))
  end

  defp require_pod_name(%{name: name}) when is_binary(name), do: :ok

  defp require_pod_name(_target) do
    Common.tool_error(:tool_input_invalid, "name is required for kubectl_logs")
  end

  defp since_seconds(input) do
    case Common.positive_integer(input, "since_seconds", 1, @max_since_seconds) do
      {:ok, 1} ->
        if present?(input, "since_seconds"), do: {:ok, 1}, else: {:ok, nil}

      result ->
        result
    end
  end

  defp since_arg(nil), do: []
  defp since_arg(since_seconds), do: ["--since", "#{since_seconds}s"]

  defp container_arg(nil), do: []
  defp container_arg(container), do: ["--container", container]

  defp split_lines(""), do: []
  defp split_lines(text), do: String.split(text, "\n", trim: true)

  defp present?(map, key) do
    Enum.any?(map, fn {map_key, _value} -> to_string(map_key) == key end)
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
