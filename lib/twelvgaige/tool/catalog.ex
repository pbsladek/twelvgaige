defmodule Twelvgaige.Tool.Catalog do
  @moduledoc """
  Built-in tool catalog.

  Runtime-loaded tools are intentionally out of scope until the daemon and
  durable audit path exist. This pure catalog keeps Phase 2 deterministic and
  unit-testable.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Tool.Builtins.Authoring.PatchPlan
  alias Twelvgaige.Tool.Builtins.Authoring.ShellDiff
  alias Twelvgaige.Tool.Builtins.Authoring.ShellGraph
  alias Twelvgaige.Tool.Builtins.Authoring.ShellImpact
  alias Twelvgaige.Tool.Builtins.Authoring.ShellInventory
  alias Twelvgaige.Tool.Builtins.Authoring.ShellLint
  alias Twelvgaige.Tool.Builtins.Authoring.ShellNormalize
  alias Twelvgaige.Tool.Builtins.Authoring.ShellValidate
  alias Twelvgaige.Tool.Builtins.Authoring.ToolCatalogRead
  alias Twelvgaige.Tool.Builtins.GitCommit
  alias Twelvgaige.Tool.Builtins.HTTPGet
  alias Twelvgaige.Tool.Builtins.HTTPPost
  alias Twelvgaige.Tool.Builtins.Kubernetes.Apply, as: KubectlApply
  alias Twelvgaige.Tool.Builtins.Kubernetes.Describe, as: KubectlDescribe
  alias Twelvgaige.Tool.Builtins.Kubernetes.Delete, as: KubectlDelete
  alias Twelvgaige.Tool.Builtins.Kubernetes.Events, as: KubectlEvents
  alias Twelvgaige.Tool.Builtins.Kubernetes.Exec, as: KubectlExec
  alias Twelvgaige.Tool.Builtins.Kubernetes.Get, as: KubectlGet
  alias Twelvgaige.Tool.Builtins.Kubernetes.Logs, as: KubectlLogs
  alias Twelvgaige.Tool.Builtins.Kubernetes.RolloutRestart, as: KubectlRolloutRestart
  alias Twelvgaige.Tool.Builtins.Kubernetes.Scale, as: KubectlScale
  alias Twelvgaige.Tool.Builtins.ShellRead

  @builtins %{
    "git_commit" => GitCommit,
    "http_get" => HTTPGet,
    "http_post" => HTTPPost,
    "kubectl_apply" => KubectlApply,
    "kubectl_delete" => KubectlDelete,
    "kubectl_describe" => KubectlDescribe,
    "kubectl_events" => KubectlEvents,
    "kubectl_exec" => KubectlExec,
    "kubectl_get" => KubectlGet,
    "kubectl_logs" => KubectlLogs,
    "kubectl_rollout_restart" => KubectlRolloutRestart,
    "kubectl_scale" => KubectlScale,
    "patch_plan" => PatchPlan,
    "shell_diff" => ShellDiff,
    "shell_graph" => ShellGraph,
    "shell_impact" => ShellImpact,
    "shell_inventory" => ShellInventory,
    "shell_lint" => ShellLint,
    "shell_normalize" => ShellNormalize,
    "shell_read" => ShellRead,
    "shell_validate" => ShellValidate,
    "tool_catalog_read" => ToolCatalogRead
  }

  @spec all() :: %{String.t() => module()}
  def all, do: @builtins

  @spec names() :: [String.t()]
  def names, do: @builtins |> Map.keys() |> Enum.sort()

  @spec fetch(String.t() | atom()) :: {:ok, module()} | {:error, Error.t()}
  def fetch(name) when is_atom(name), do: fetch(Atom.to_string(name))

  def fetch(name) when is_binary(name) do
    case Map.fetch(@builtins, name) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error,
         Error.new(:tool_error, :unknown_tool, "unknown tool #{inspect(name)}",
           details: %{tool: name, known_tools: names()}
         )}
    end
  end

  @spec metadata(String.t() | atom()) :: {:ok, map()} | {:error, Error.t()}
  def metadata(name) do
    with {:ok, module} <- fetch(name) do
      {:ok,
       %{
         name: module.name(),
         description: module.description(),
         safety_level: module.safety_level(),
         idempotency: module.idempotency(),
         input_schema: module.input_schema()
       }}
    end
  end
end
