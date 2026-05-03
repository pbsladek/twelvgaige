defmodule Twelvgaige.Tool.Builtins.Kubernetes.Common do
  @moduledoc false

  alias Twelvgaige.Error
  alias Twelvgaige.Redactor
  alias Twelvgaige.Tool.CommandRunner

  @allowed_resources ~w(pods deployments replicasets statefulsets daemonsets services endpoints ingress jobs cronjobs configmaps events nodes namespaces)
  @write_resources ~w(deployments replicasets statefulsets daemonsets jobs cronjobs configmaps services ingress)
  @cluster_scoped_resources ~w(nodes namespaces)
  @default_max_bytes 256 * 1024
  @hard_max_bytes 1_048_576
  @default_timeout_ms 30_000

  @spec common_schema([String.t()]) :: map()
  def common_schema(required) do
    %{
      "type" => "object",
      "required" => Enum.reject(required, &(&1 == "context")),
      "properties" => %{
        "context" => %{"type" => "string"},
        "namespace" => %{"type" => "string"},
        "resource" => %{"type" => "string", "enum" => @allowed_resources},
        "name" => %{"type" => "string"},
        "selector" => %{"type" => "string"},
        "field_selector" => %{"type" => "string"},
        "container" => %{"type" => "string"},
        "confirm" => %{"type" => "boolean"},
        "replicas" => %{"type" => "integer"},
        "tail_lines" => %{"type" => "integer"},
        "since_seconds" => %{"type" => "integer"},
        "limit" => %{"type" => "integer"},
        "max_bytes" => %{"type" => "integer"},
        "allow_cluster_scope" => %{"type" => "boolean"}
      },
      "additionalProperties" => false
    }
  end

  @spec target(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def target(input, opts) do
    with {:ok, context} <- context(input, opts),
         {:ok, resource} <- required_string(input, "resource"),
         :ok <- ensure_known_resource(resource),
         {:ok, namespace} <- namespace(input, resource, opts) do
      target = %{
        context: context,
        namespace: namespace,
        resource: resource,
        cluster_scope?: namespace == nil,
        name: optional_string(input, "name"),
        selector: optional_string(input, "selector"),
        field_selector: optional_string(input, "field_selector")
      }

      with :ok <- ensure_runtime_policy(target, opts) do
        {:ok, target}
      end
    end
  end

  @spec context(map(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def context(input, opts) do
    input_context = optional_string(input, "context")
    trusted_context = trusted_context(opts)

    cond do
      is_binary(trusted_context) and input_context in [nil, trusted_context] ->
        {:ok, trusted_context}

      is_binary(trusted_context) ->
        tool_error(
          :kubernetes_context_denied,
          "Kubernetes context must match trusted runtime policy",
          %{
            field: :context,
            value: input_context,
            trusted_context: trusted_context
          }
        )

      Keyword.get(opts, :require_runtime_context?, false) ->
        tool_error(
          :kubernetes_context_denied,
          "Kubernetes context must come from trusted runtime policy",
          %{field: :context}
        )

      is_binary(input_context) ->
        {:ok, input_context}

      true ->
        tool_error(:tool_input_invalid, "context is required", %{field: "context"})
    end
  end

  @spec write_schema([String.t()], [String.t()]) :: map()
  def write_schema(required, resources \\ @write_resources) do
    schema = common_schema(required)

    schema
    |> put_in(["properties", "resource"], %{"type" => "string", "enum" => resources})
    |> put_in(["properties", "confirm"], %{"type" => "boolean"})
  end

  @spec write_target(map(), keyword(), [String.t()]) :: {:ok, map()} | {:error, Error.t()}
  def write_target(input, opts, resources \\ @write_resources) do
    with {:ok, target} <- target(input, opts),
         :ok <- ensure_write_resource(target.resource, resources),
         :ok <- ensure_namespaced_write(target) do
      {:ok, target}
    end
  end

  @spec require_name(map(), String.t()) :: :ok | {:error, Error.t()}
  def require_name(%{name: name}, _tool_name) when is_binary(name), do: :ok

  def require_name(target, tool_name) do
    tool_error(:tool_input_invalid, "name is required for #{tool_name}", %{
      resource: Map.get(target, :resource)
    })
  end

  @spec require_confirm(map(), String.t()) :: :ok | {:error, Error.t()}
  def require_confirm(input, tool_name) do
    if value(input, "confirm") == true do
      :ok
    else
      Error.new(:policy_error, :policy_denied, "#{tool_name} requires explicit confirm=true",
        safety_required: true,
        details: %{tool: tool_name, required: "confirm=true"}
      )
      |> then(&{:error, &1})
    end
  end

  @spec non_negative_integer(map(), String.t()) :: {:ok, non_neg_integer()} | {:error, Error.t()}
  def non_negative_integer(input, key) do
    case value(input, key) do
      value when is_integer(value) and value >= 0 ->
        {:ok, value}

      _value ->
        tool_error(:tool_input_invalid, "#{key} must be a non-negative integer", %{field: key})
    end
  end

  @spec required_string(map(), String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def required_string(input, key) do
    case value(input, key) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _value ->
        tool_error(:tool_input_invalid, "#{key} is required", %{field: key})
    end
  end

  @spec optional_string(map(), String.t()) :: String.t() | nil
  def optional_string(input, key) do
    case value(input, key) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  @spec positive_integer(map(), String.t(), pos_integer(), pos_integer()) ::
          {:ok, pos_integer()} | {:error, Error.t()}
  def positive_integer(input, key, default, max) do
    value = value(input, key) || default

    cond do
      not is_integer(value) or value <= 0 ->
        tool_error(:tool_input_invalid, "#{key} must be a positive integer", %{field: key})

      value > max ->
        {:ok, max}

      true ->
        {:ok, value}
    end
  end

  @spec max_bytes(map(), keyword()) :: {:ok, pos_integer()} | {:error, Error.t()}
  def max_bytes(input, opts) do
    value =
      value(input, "max_bytes") ||
        Keyword.get(opts, :default_max_bytes, @default_max_bytes)

    hard_max_bytes = Keyword.get(opts, :hard_max_bytes, @hard_max_bytes)

    cond do
      not is_integer(value) or value <= 0 ->
        tool_error(:tool_input_invalid, "max_bytes must be a positive integer", %{
          field: "max_bytes"
        })

      value > hard_max_bytes ->
        {:ok, hard_max_bytes}

      true ->
        {:ok, value}
    end
  end

  @spec run_kubectl([String.t()], map(), keyword()) ::
          {:ok, CommandRunner.result()} | {:error, Error.t()}
  def run_kubectl(args, target, opts) do
    runner = Keyword.get(opts, :command_runner, &CommandRunner.run/3)

    runner_opts =
      opts
      |> command_runner_opts()
      |> Keyword.put(:timeout_ms, Keyword.get(opts, :timeout_ms, @default_timeout_ms))

    case runner.("kubectl", args, runner_opts) do
      {:ok, %{status: 0} = result} ->
        {:ok, normalize_result(result)}

      {:ok, %{status: status} = result} ->
        {:error,
         Error.new(:tool_error, :tool_retryable, "kubectl exited with non-zero status",
           retryable: true,
           details:
             Map.merge(audit_target(target), %{
               exit_status: status,
               stderr: Redactor.redact_text(Map.get(result, :stderr, "")),
               stdout: Redactor.redact_text(Map.get(result, :stdout, ""))
             })
         )}

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Error.new(:tool_error, :tool_retryable, "kubectl command failed",
           retryable: true,
           details: Map.merge(audit_target(target), %{reason: inspect(reason)})
         )}
    end
  end

  @spec base_args(map()) :: [String.t()]
  def base_args(target) do
    args = ["--context", target.context]

    if target.namespace do
      args ++ ["-n", target.namespace]
    else
      args
    end
  end

  @spec selector_args(map()) :: [String.t()]
  def selector_args(target) do
    []
    |> append_opt("--selector", target.selector)
    |> append_opt("--field-selector", target.field_selector)
  end

  @spec limit_items([term()], map()) :: [term()]
  def limit_items(items, input) when is_list(items) do
    case value(input, "limit") do
      limit when is_integer(limit) and limit > 0 -> Enum.take(items, limit)
      _value -> items
    end
  end

  @spec bounded_excerpt(String.t(), pos_integer()) :: {String.t(), boolean()}
  def bounded_excerpt(text, max_bytes) do
    redacted = Redactor.redact_text(text)

    if byte_size(redacted) > max_bytes do
      {binary_part(redacted, 0, max_bytes), true}
    else
      {redacted, false}
    end
  end

  @spec decode_json(String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  def decode_json(output, target) do
    case Jason.decode(output) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, Redactor.redact_json(decoded)}

      {:ok, _decoded} ->
        tool_error(
          :tool_non_retryable,
          "kubectl JSON output was not an object",
          audit_target(target)
        )

      {:error, reason} ->
        tool_error(:tool_retryable, "kubectl returned invalid JSON", %{
          target: audit_target(target),
          reason: Exception.message(reason)
        })
    end
  end

  @spec audit_target(map()) :: map()
  def audit_target(target) do
    %{
      context: target.context,
      namespace: target.namespace,
      resource: target.resource,
      name: target.name,
      selector: target.selector,
      field_selector: target.field_selector
    }
  end

  @spec output_base(map(), String.t(), non_neg_integer()) :: map()
  def output_base(target, verb, duration_ms) do
    target
    |> audit_target()
    |> Map.merge(%{
      verb: verb,
      duration_ms: duration_ms
    })
  end

  @spec tool_error(atom(), String.t(), map()) :: {:error, Error.t()}
  def tool_error(reason, message, details \\ %{}) do
    {:error,
     Error.new(:tool_error, reason, message,
       retryable: reason in [:tool_retryable, :tool_timeout],
       safety_required:
         reason in [
           :kubernetes_cluster_scope_denied,
           :kubernetes_context_denied,
           :kubernetes_resource_denied
         ],
       details: details
     )}
  end

  defp namespace(input, resource, opts) do
    namespace = optional_string(input, "namespace")

    cond do
      resource in @cluster_scoped_resources ->
        if value(input, "allow_cluster_scope") == true and
             Keyword.get(opts, :allow_cluster_scope, false) do
          {:ok, nil}
        else
          tool_error(
            :kubernetes_cluster_scope_denied,
            "cluster-scope Kubernetes access denied",
            %{
              resource: resource
            }
          )
        end

      namespace ->
        {:ok, namespace}

      true ->
        tool_error(:tool_input_invalid, "namespace is required", %{field: "namespace"})
    end
  end

  defp ensure_known_resource(resource) do
    if resource in @allowed_resources do
      :ok
    else
      tool_error(:kubernetes_resource_denied, "Kubernetes resource is not allowlisted", %{
        resource: resource,
        allowed_resources: @allowed_resources
      })
    end
  end

  defp ensure_runtime_policy(target, opts) do
    with :ok <-
           ensure_policy_value(
             target.context,
             Keyword.get(opts, :allowed_contexts),
             :kubernetes_context_denied,
             "Kubernetes context is not allowlisted",
             :context
           ),
         :ok <-
           ensure_policy_value(
             target.namespace,
             Keyword.get(opts, :allowed_namespaces),
             :kubernetes_context_denied,
             "Kubernetes namespace is not allowlisted",
             :namespace
           ),
         :ok <-
           ensure_policy_value(
             target.resource,
             Keyword.get(opts, :allowed_resources),
             :kubernetes_resource_denied,
             "Kubernetes resource is not allowlisted by runtime policy",
             :resource
           ),
         :ok <-
           ensure_policy_pattern(
             target.name,
             Keyword.get(opts, :allowed_name_patterns),
             :kubernetes_resource_denied,
             "Kubernetes object name is not allowlisted by runtime policy",
             :name
           ),
         :ok <-
           ensure_policy_pattern(
             target.selector,
             Keyword.get(opts, :allowed_selector_patterns),
             :kubernetes_resource_denied,
             "Kubernetes selector is not allowlisted by runtime policy",
             :selector
           ),
         :ok <-
           ensure_policy_pattern(
             target.field_selector,
             Keyword.get(opts, :allowed_selector_patterns),
             :kubernetes_resource_denied,
             "Kubernetes field selector is not allowlisted by runtime policy",
             :field_selector
           ) do
      :ok
    end
  end

  defp ensure_policy_value(nil, _allowed_values, _reason, _message, _field), do: :ok
  defp ensure_policy_value(_value, nil, _reason, _message, _field), do: :ok

  defp ensure_policy_value(value, allowed_values, reason, message, field)
       when is_list(allowed_values) do
    allowed_values = Enum.map(allowed_values, &to_string/1)

    if value in allowed_values do
      :ok
    else
      tool_error(reason, message, %{
        field: field,
        value: value,
        allowed_values: allowed_values
      })
    end
  end

  defp ensure_policy_value(value, _allowed_values, reason, message, field) do
    tool_error(reason, "invalid runtime allowlist policy: #{message}", %{
      field: field,
      value: value
    })
  end

  defp ensure_policy_pattern(nil, _patterns, _reason, _message, _field), do: :ok
  defp ensure_policy_pattern(_value, nil, _reason, _message, _field), do: :ok

  defp ensure_policy_pattern(value, patterns, reason, message, field) when is_list(patterns) do
    if Enum.any?(patterns, &pattern_match?(&1, value)) do
      :ok
    else
      tool_error(reason, message, %{
        field: field,
        value: value,
        allowed_patterns: Enum.map(patterns, &inspect/1)
      })
    end
  end

  defp ensure_policy_pattern(value, _patterns, reason, message, field) do
    tool_error(reason, "invalid runtime pattern policy: #{message}", %{
      field: field,
      value: value
    })
  end

  defp pattern_match?(%Regex{} = regex, value), do: Regex.match?(regex, value)

  defp pattern_match?(pattern, value) when is_binary(pattern) do
    case Regex.compile(pattern) do
      {:ok, regex} -> Regex.match?(regex, value)
      {:error, _reason} -> false
    end
  end

  defp pattern_match?(_pattern, _value), do: false

  defp ensure_write_resource(resource, resources) do
    if resource in resources do
      :ok
    else
      tool_error(:kubernetes_resource_denied, "Kubernetes write resource is not allowlisted", %{
        resource: resource,
        allowed_resources: resources
      })
    end
  end

  defp ensure_namespaced_write(%{cluster_scope?: false}), do: :ok

  defp ensure_namespaced_write(target) do
    tool_error(:kubernetes_cluster_scope_denied, "cluster-scope Kubernetes writes are denied", %{
      resource: target.resource
    })
  end

  defp append_opt(args, _flag, nil), do: args
  defp append_opt(args, flag, value), do: args ++ [flag, value]

  defp normalize_result(result) do
    %{
      status: Map.fetch!(result, :status),
      stdout: Map.get(result, :stdout, ""),
      stderr: Map.get(result, :stderr, ""),
      duration_ms: Map.get(result, :duration_ms, 0)
    }
  end

  defp command_runner_opts(opts) do
    opts
    |> Keyword.take([
      :binary_path,
      :binary_paths,
      :require_absolute_binary?,
      :cwd,
      :cd,
      :require_cwd?,
      :scrub_env?,
      :env_allowlist,
      :env,
      :max_output_bytes,
      :max_stdout_bytes,
      :max_stderr_bytes
    ])
    |> put_kubeconfig_env(opts)
  end

  defp trusted_context(opts) do
    Keyword.get(opts, :kubernetes_context) ||
      Keyword.get(opts, :kube_context)
  end

  defp put_kubeconfig_env(runner_opts, opts) do
    case Keyword.get(opts, :kubernetes_kubeconfig) || Keyword.get(opts, :kubeconfig) do
      nil ->
        runner_opts

      "" ->
        runner_opts

      path when is_binary(path) ->
        env =
          runner_opts
          |> Keyword.get(:env, [])
          |> Enum.reject(fn {key, _value} -> to_string(key) == "KUBECONFIG" end)
          |> Kernel.++([{"KUBECONFIG", Path.expand(path)}])

        Keyword.put(runner_opts, :env, env)

      _other ->
        runner_opts
    end
  end

  @spec value(map(), String.t()) :: term()
  def value(map, key) do
    case Enum.find(map, fn {map_key, _value} -> key_string(map_key) == key end) do
      {_map_key, value} -> value
      nil -> nil
    end
  end

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: inspect(key)
end
