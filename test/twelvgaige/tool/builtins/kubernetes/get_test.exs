defmodule Twelvgaige.Tool.Builtins.Kubernetes.GetTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.Kubernetes.Get
  alias Twelvgaige.Tool.Executor

  test "builds structured kubectl get argv and returns parsed items" do
    runner = fn binary, args, opts ->
      send(self(), {:runner, binary, args, opts})

      {:ok,
       %{
         status: 0,
         stdout:
           Jason.encode!(%{
             "kind" => "PodList",
             "metadata" => %{"resourceVersion" => "12"},
             "items" => [
               %{"metadata" => %{"name" => "payments-a"}},
               %{"metadata" => %{"name" => "payments-b"}}
             ]
           }),
         stderr: "",
         duration_ms: 7
       }}
    end

    assert {:ok, result} =
             Get.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "payments",
                 "resource" => "pods",
                 "selector" => "app=payments",
                 "limit" => 1
               },
               command_runner: runner
             )

    assert_receive {:runner, "kubectl",
                    [
                      "--context",
                      "kind-dev",
                      "-n",
                      "payments",
                      "get",
                      "pods",
                      "--selector",
                      "app=payments",
                      "-o",
                      "json"
                    ], [timeout_ms: 30_000]}

    assert result["verb"] == "get"
    assert result["resource"] == "pods"
    assert result["summary"]["kind"] == "PodList"
    assert result["summary"]["item_count"] == 1
    assert [%{"metadata" => %{"name" => "payments-a"}}] = result["items"]
  end

  test "requires namespace for namespaced resources" do
    assert {:error, error} =
             Get.execute(%{"context" => "kind-dev", "resource" => "pods"},
               command_runner: unused_runner()
             )

    assert error.reason == :tool_input_invalid
    assert error.details.field == "namespace"
  end

  test "can take Kubernetes context from trusted runtime policy instead of tool input" do
    runner = fn binary, args, opts ->
      send(self(), {:runner, binary, args, opts})
      {:ok, %{status: 0, stdout: Jason.encode!(%{"items" => []}), stderr: "", duration_ms: 1}}
    end

    assert {:ok, result} =
             Get.execute(
               %{"namespace" => "payments", "resource" => "pods"},
               command_runner: runner,
               kubernetes_context: "kind-dev"
             )

    assert_receive {:runner, "kubectl",
                    ["--context", "kind-dev", "-n", "payments", "get", "pods", "-o", "json"],
                    [timeout_ms: 30_000]}

    assert result["context"] == "kind-dev"
  end

  test "schema allows runtime-owned Kubernetes context through the executor" do
    runner = fn _binary, _args, _opts ->
      {:ok, %{status: 0, stdout: Jason.encode!(%{"items" => []}), stderr: "", duration_ms: 1}}
    end

    assert {:ok, result} =
             Executor.execute(
               "kubectl_get",
               %{"namespace" => "payments", "resource" => "pods"},
               allowed_tools: ["kubectl_get"],
               limiter: nil,
               max_safety: :read_only,
               tool_opts: [command_runner: runner, kubernetes_context: "kind-dev"]
             )

    assert result["context"] == "kind-dev"
  end

  test "rejects model-supplied Kubernetes context that conflicts with runtime policy" do
    assert {:error, error} =
             Get.execute(
               %{"context" => "kind-prod", "namespace" => "payments", "resource" => "pods"},
               command_runner: unused_runner(),
               kubernetes_context: "kind-dev"
             )

    assert error.reason == :kubernetes_context_denied
    assert error.details.trusted_context == "kind-dev"
  end

  test "can require Kubernetes context to come from runtime policy" do
    assert {:error, error} =
             Get.execute(
               %{"context" => "kind-dev", "namespace" => "payments", "resource" => "pods"},
               command_runner: unused_runner(),
               require_runtime_context?: true
             )

    assert error.reason == :kubernetes_context_denied
  end

  test "passes trusted kubeconfig to kubectl environment" do
    runner = fn binary, args, opts ->
      send(self(), {:runner, binary, args, opts})
      {:ok, %{status: 0, stdout: Jason.encode!(%{"items" => []}), stderr: "", duration_ms: 1}}
    end

    assert {:ok, _result} =
             Get.execute(
               %{"namespace" => "payments", "resource" => "pods"},
               command_runner: runner,
               kubernetes_context: "kind-dev",
               kubernetes_kubeconfig: "fixtures/kubeconfig"
             )

    assert_receive {:runner, "kubectl", _args, opts}
    assert {"KUBECONFIG", kubeconfig} = List.keyfind(Keyword.fetch!(opts, :env), "KUBECONFIG", 0)
    assert kubeconfig == Path.expand("fixtures/kubeconfig")
  end

  test "denies cluster scope unless both input and trusted opts allow it" do
    assert {:error, error} =
             Get.execute(
               %{"context" => "kind-dev", "resource" => "nodes", "allow_cluster_scope" => true},
               command_runner: unused_runner()
             )

    assert error.reason == :kubernetes_cluster_scope_denied
    assert error.safety_required
  end

  test "allows trusted cluster scope without namespace argv" do
    runner = fn binary, args, _opts ->
      send(self(), {:runner, binary, args})
      {:ok, %{status: 0, stdout: Jason.encode!(%{"items" => []}), stderr: "", duration_ms: 1}}
    end

    assert {:ok, result} =
             Get.execute(
               %{"context" => "kind-dev", "resource" => "nodes", "allow_cluster_scope" => true},
               command_runner: runner,
               allow_cluster_scope: true
             )

    assert_receive {:runner, "kubectl", ["--context", "kind-dev", "get", "nodes", "-o", "json"]}
    assert result["namespace"] == nil
  end

  test "rejects resources outside the phase 2 allowlist" do
    assert {:error, error} =
             Get.execute(
               %{"context" => "kind-dev", "namespace" => "default", "resource" => "secrets"},
               command_runner: unused_runner()
             )

    assert error.reason == :kubernetes_resource_denied
  end

  test "enforces trusted runtime context namespace and resource allowlists" do
    base = %{"context" => "kind-prod", "namespace" => "payments", "resource" => "pods"}

    assert {:error, context_error} =
             Get.execute(base,
               command_runner: unused_runner(),
               allowed_contexts: ["kind-dev"]
             )

    assert context_error.reason == :kubernetes_context_denied
    assert context_error.details.field == :context

    assert {:error, namespace_error} =
             Get.execute(base,
               command_runner: unused_runner(),
               allowed_contexts: ["kind-prod"],
               allowed_namespaces: ["default"]
             )

    assert namespace_error.reason == :kubernetes_context_denied
    assert namespace_error.details.field == :namespace

    assert {:error, resource_error} =
             Get.execute(base,
               command_runner: unused_runner(),
               allowed_contexts: ["kind-prod"],
               allowed_namespaces: ["payments"],
               allowed_resources: ["deployments"]
             )

    assert resource_error.reason == :kubernetes_resource_denied
    assert resource_error.details.field == :resource
  end

  test "enforces trusted runtime name and selector patterns" do
    assert {:error, name_error} =
             Get.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "payments",
                 "resource" => "pods",
                 "name" => "admin-api"
               },
               command_runner: unused_runner(),
               allowed_name_patterns: ["^payments-"]
             )

    assert name_error.reason == :kubernetes_resource_denied
    assert name_error.details.field == :name

    assert {:error, selector_error} =
             Get.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "payments",
                 "resource" => "pods",
                 "selector" => "app=admin"
               },
               command_runner: unused_runner(),
               allowed_selector_patterns: ["^app=payments$"]
             )

    assert selector_error.reason == :kubernetes_resource_denied
    assert selector_error.details.field == :selector
  end

  defp unused_runner do
    fn _binary, _args, _opts -> flunk("kubectl should not run") end
  end
end
