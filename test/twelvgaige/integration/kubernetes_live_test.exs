defmodule Twelvgaige.Integration.KubernetesLiveTest do
  use ExUnit.Case, async: false

  @moduletag :k8s_live

  alias Twelvgaige.Tool.Builtins.Kubernetes.Describe
  alias Twelvgaige.Tool.Builtins.Kubernetes.Events
  alias Twelvgaige.Tool.Builtins.Kubernetes.Get
  alias Twelvgaige.Tool.Builtins.Kubernetes.Logs

  test "kubectl_get reads pods from a runtime-configured live cluster" do
    with_live_kubernetes(fn context, namespace, opts ->
      assert {:ok, result} =
               Get.execute(
                 %{
                   "namespace" => namespace,
                   "resource" => "pods",
                   "limit" => 5
                 },
                 opts
               )

      assert result["verb"] == "get"
      assert result["context"] == context
      assert result["namespace"] == namespace
      assert result["resource"] == "pods"
      assert is_list(result["items"])
      assert is_integer(result["summary"]["item_count"])
    end)
  end

  test "kubectl_events reads namespace events from a runtime-configured live cluster" do
    with_live_kubernetes(fn context, namespace, opts ->
      assert {:ok, result} =
               Events.execute(
                 %{
                   "namespace" => namespace,
                   "limit" => 5
                 },
                 opts
               )

      assert result["verb"] == "events"
      assert result["context"] == context
      assert result["namespace"] == namespace
      assert is_list(result["items"])
      assert is_integer(result["summary"]["event_count"])
    end)
  end

  test "kubectl_get, describe, and logs read the fixture workload" do
    with_live_fixture(fn context, namespace, selector, deployment, opts ->
      assert {:ok, pods} =
               Get.execute(
                 %{
                   "namespace" => namespace,
                   "resource" => "pods",
                   "selector" => selector,
                   "limit" => 5
                 },
                 opts
               )

      assert pods["context"] == context
      assert pods["namespace"] == namespace
      assert pods["summary"]["item_count"] >= 1

      pod_name =
        pods["items"]
        |> Enum.map(&get_in(&1, ["metadata", "name"]))
        |> Enum.find(&is_binary/1)

      assert is_binary(pod_name)

      assert {:ok, description} =
               Describe.execute(
                 %{
                   "namespace" => namespace,
                   "resource" => "deployments",
                   "name" => deployment
                 },
                 opts
               )

      assert description["context"] == context
      assert description["text_excerpt"] =~ deployment

      assert {:ok, logs} =
               Logs.execute(
                 %{
                   "namespace" => namespace,
                   "name" => pod_name,
                   "tail_lines" => 20,
                   "max_bytes" => 4096
                 },
                 opts
               )

      assert logs["context"] == context
      assert logs["name"] == pod_name
      assert logs["log_excerpt"] =~ "twelvgaige-live-log"
      assert Enum.any?(logs["lines"], &String.contains?(&1, "twelvgaige-live-log"))
    end)
  end

  test "runtime Kubernetes policy denies non-allowlisted namespace before kubectl runs" do
    with_live_kubernetes(fn _context, namespace, opts ->
      denied_namespace = namespace <> "-denied"

      assert {:error, error} =
               Get.execute(
                 %{
                   "namespace" => denied_namespace,
                   "resource" => "pods",
                   "limit" => 1
                 },
                 Keyword.put(opts, :allowed_namespaces, [namespace])
               )

      assert error.reason == :kubernetes_context_denied
      assert error.details.field == :namespace
      assert error.details.value == denied_namespace
    end)
  end

  test "least-privilege live kubeconfig denies resources outside the test role" do
    with_live_fixture(fn _context, namespace, _selector, _deployment, opts ->
      if System.get_env("TWELVGAIGE_K8S_KUBECONFIG") do
        assert {:error, error} =
                 Get.execute(
                   %{
                     "namespace" => namespace,
                     "resource" => "configmaps",
                     "limit" => 1
                   },
                   opts
                 )

        assert error.class == :tool_error
        assert error.reason == :tool_retryable
        assert error.details.stderr |> String.downcase() =~ "forbidden"
      end
    end)
  end

  defp with_live_kubernetes(fun) do
    if System.get_env("TWELVGAIGE_K8S_LIVE") == "1" do
      context = System.fetch_env!("TWELVGAIGE_K8S_CONTEXT")
      namespace = System.get_env("TWELVGAIGE_K8S_NAMESPACE", "default")

      opts =
        [
          timeout_ms: timeout_ms(),
          kubernetes_context: context,
          require_runtime_context?: true
        ]
        |> maybe_put_kubeconfig()

      fun.(context, namespace, opts)
    else
      :ok
    end
  end

  defp with_live_fixture(fun) do
    with_live_kubernetes(fn context, namespace, opts ->
      selector = System.get_env("TWELVGAIGE_K8S_FIXTURE_SELECTOR")
      deployment = System.get_env("TWELVGAIGE_K8S_FIXTURE_DEPLOYMENT")

      if present?(selector) and present?(deployment) do
        fun.(context, namespace, selector, deployment, opts)
      end
    end)
  end

  defp maybe_put_kubeconfig(opts) do
    case System.get_env("TWELVGAIGE_K8S_KUBECONFIG") do
      value when is_binary(value) and value != "" ->
        Keyword.put(opts, :kubernetes_kubeconfig, value)

      _missing ->
        opts
    end
  end

  defp timeout_ms do
    case System.get_env("TWELVGAIGE_K8S_TIMEOUT_MS") do
      nil ->
        30_000

      value ->
        case Integer.parse(value) do
          {timeout_ms, ""} when timeout_ms > 0 -> timeout_ms
          _other -> 30_000
        end
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
