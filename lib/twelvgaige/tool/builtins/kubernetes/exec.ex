defmodule Twelvgaige.Tool.Builtins.Kubernetes.Exec do
  @moduledoc """
  Execute a structured argv inside a named Kubernetes pod.

  This tool is intentionally opt-in at runtime because remote exec can bypass
  the narrower Kubernetes tool model. It never accepts shell command strings;
  callers must provide argv as a list of strings.
  """

  @behaviour Twelvgaige.Tool

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor
  alias Twelvgaige.Tool.Builtins.Kubernetes.Common
  alias Twelvgaige.Tool.Idempotency

  @blocked_shells ~w(sh bash zsh fish dash ash ksh cmd cmd.exe powershell powershell.exe pwsh pwsh.exe)

  @impl true
  def name, do: "kubectl_exec"

  @impl true
  def description, do: "Execute an explicitly approved argv in a named Kubernetes pod."

  @impl true
  def input_schema do
    %{
      "type" => "object",
      "required" => ["namespace", "name", "command", "confirm"],
      "properties" => %{
        "context" => %{"type" => "string"},
        "namespace" => %{"type" => "string"},
        "name" => %{"type" => "string"},
        "container" => %{"type" => "string"},
        "command" => %{"type" => "array", "items" => %{"type" => "string"}},
        "confirm" => %{"type" => "boolean"},
        "max_bytes" => %{"type" => "integer"}
      },
      "additionalProperties" => false
    }
  end

  @impl true
  def safety_level, do: :irreversible

  @impl true
  def idempotency do
    Idempotency.non_idempotent(
      reconciliation_strategy: :manual,
      side_effect_phase: :unknown
    )
  end

  @impl true
  def execute(input, opts) do
    input = Map.put_new(input, "resource", "pods")

    with :ok <- Common.require_confirm(input, name()),
         :ok <- require_runtime_opt_in(opts),
         {:ok, target} <- Common.target(input, opts),
         :ok <- Common.require_name(target, name()),
         {:ok, command} <- command(input),
         :ok <- ensure_shell_policy(command, opts),
         {:ok, max_bytes} <- Common.max_bytes(input, opts),
         {:ok, result} <- Common.run_kubectl(args(target, input, command), target, opts),
         {excerpt, truncated} <- Common.bounded_excerpt(result.stdout, max_bytes) do
      {:ok,
       Common.output_base(target, "exec", result.duration_ms)
       |> Map.merge(%{
         container: Common.optional_string(input, "container"),
         command: redact_command(command),
         text_excerpt: excerpt,
         truncated: truncated,
         output_bytes: byte_size(excerpt),
         exit_status: result.status
       })
       |> stringify_keys()}
    end
  end

  defp require_runtime_opt_in(opts) do
    if Keyword.get(opts, :allow_kubectl_exec, false) do
      :ok
    else
      {:error,
       Error.new(:policy_error, :policy_denied, "kubectl_exec is disabled by runtime policy",
         safety_required: true,
         details: %{tool: name(), required: "allow_kubectl_exec: true"}
       )}
    end
  end

  defp command(input) do
    case Common.value(input, "command") do
      command when is_list(command) ->
        if Enum.all?(command, &(is_binary(&1) and String.trim(&1) != "")) and command != [] do
          {:ok, command}
        else
          Common.tool_error(:tool_input_invalid, "command must be a non-empty argv list", %{
            field: "command"
          })
        end

      _value ->
        Common.tool_error(:tool_input_invalid, "command must be a non-empty argv list", %{
          field: "command"
        })
    end
  end

  defp ensure_shell_policy([binary | _args], opts) do
    normalized =
      binary
      |> Path.basename()
      |> String.downcase()

    cond do
      normalized not in @blocked_shells ->
        :ok

      Keyword.get(opts, :allow_shell, false) ->
        :ok

      true ->
        {:error,
         Error.new(:policy_error, :policy_denied, "kubectl_exec shell interpreters are disabled",
           safety_required: true,
           details: %{tool: name(), command: normalized, required: "allow_shell: true"}
         )}
    end
  end

  defp args(target, input, command) do
    Common.base_args(target) ++
      ["exec", target.name] ++
      container_arg(Common.optional_string(input, "container")) ++
      ["--"] ++
      command
  end

  defp container_arg(nil), do: []
  defp container_arg(container), do: ["--container", container]

  defp redact_command(command), do: Enum.map(command, &Redactor.redact_text/1)

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
