defmodule Twelvgaige.Integration.KubernetesLiveTest do
  use ExUnit.Case, async: false

  @moduletag :k8s_live

  alias Twelvgaige.Tool.Builtins.Kubernetes.Events
  alias Twelvgaige.Tool.Builtins.Kubernetes.Get

  test "kubectl_get reads pods from an explicitly configured live cluster" do
    with_live_kubernetes(fn context, namespace, opts ->
      assert {:ok, result} =
               Get.execute(
                 %{
                   "context" => context,
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

  test "kubectl_events reads namespace events from an explicitly configured live cluster" do
    with_live_kubernetes(fn context, namespace, opts ->
      assert {:ok, result} =
               Events.execute(
                 %{
                   "context" => context,
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

  defp with_live_kubernetes(fun) do
    if System.get_env("TWELVGAIGE_K8S_LIVE") == "1" do
      context = System.fetch_env!("TWELVGAIGE_K8S_CONTEXT")
      namespace = System.get_env("TWELVGAIGE_K8S_NAMESPACE", "default")
      timeout_ms = timeout_ms()

      fun.(context, namespace, timeout_ms: timeout_ms)
    else
      :ok
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
end
