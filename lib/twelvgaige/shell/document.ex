defmodule Twelvgaige.Shell.Document do
  @moduledoc """
  Canonical shell documents for normalize and convert commands.

  The document map is intentionally an authoring-format-neutral shell map. It
  can be loaded again by `Twelvgaige.Shell.Loader` after encoding as JSON, TOML,
  or YAML.
  """

  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Agent.Choke, as: AgentChoke
  alias Twelvgaige.Shell.Agent.Memory
  alias Twelvgaige.Shell.Agent.Tools
  alias Twelvgaige.Shell.Metadata
  alias Twelvgaige.Shell.Schema
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shell.Workflow.Choke
  alias Twelvgaige.Shell.Workflow.Policy
  alias Twelvgaige.Shell.Workflow.Retry
  alias Twelvgaige.Shell.Workflow.Shot

  @type format :: :json | :toml | :yaml

  @spec to_map(Twelvgaige.Shell.t()) :: map()
  def to_map(%Workflow{} = shell) do
    %{
      "kind" => "workflow",
      "id" => shell.id,
      "name" => shell.name,
      "version" => shell.version,
      "timeout" => duration(shell.timeout_ms),
      "policy" => policy_map(shell.policy),
      "input_schema" => schema_map(shell.input_schema),
      "metadata" => metadata_map(shell.metadata),
      "shots" => Enum.map(shell.shots, &shot_map/1)
    }
    |> compact()
  end

  def to_map(%Agent{} = shell) do
    %{
      "kind" => "agent",
      "id" => shell.id,
      "name" => shell.name,
      "version" => shell.version,
      "provider" => shell.provider,
      "model" => shell.model,
      "system_prompt" => shell.system_prompt,
      "tools" => agent_tools_map(shell.tools),
      "choke" => agent_choke_map(shell.choke),
      "memory" => memory_map(shell.memory)
    }
    |> compact()
  end

  @spec encode(Twelvgaige.Shell.t() | map(), format()) ::
          {:ok, String.t()} | {:error, Twelvgaige.Error.t()}
  def encode(shell_or_map, format) do
    document =
      if is_map(shell_or_map) and not is_struct(shell_or_map) do
        compact(shell_or_map)
      else
        to_map(shell_or_map)
      end

    case format do
      :json ->
        {:ok, Jason.encode!(document, pretty: true) <> "\n"}

      :toml ->
        case TomlElixir.encode(document) do
          {:ok, contents} -> {:ok, contents <> "\n"}
          {:error, reason} -> encode_error(:toml, reason)
        end

      :yaml ->
        {:ok, encode_yaml(document)}
    end
  end

  defp policy_map(%Policy{} = policy) do
    %{
      "on_shot_failure" => non_default(policy.on_shot_failure, :fail_round),
      "on_condition_error" => non_default(policy.on_condition_error, :fail_round),
      "on_store_error" => non_default(policy.on_store_error, :block_round),
      "on_safety_reject" => non_default(policy.on_safety_reject, :halt_round),
      "on_cancel" => non_default(policy.on_cancel, :cancel_round),
      "safety_scope" => non_default(policy.safety_scope, :dependency),
      "resource_profile" => non_default(policy.resource_profile, :laptop),
      "queue_timeout" => duration(policy.queue_timeout_ms)
    }
    |> stringify_atoms()
    |> compact()
  end

  defp shot_map(%Shot{} = shot) do
    %{
      "id" => shot.id,
      "kind" => Atom.to_string(shot.kind),
      "agent" => shot.agent,
      "description" => shot.description,
      "depends_on" => non_empty(shot.depends_on),
      "condition" => non_default(shot.condition, true),
      "timeout" => duration(shot.timeout_ms),
      "tools" => non_empty(shot.tools),
      "retry" => retry_map(shot.retry),
      "choke" => choke_map(shot.choke),
      "output_schema" => schema_map(shot.output_schema),
      "prompt" => shot.prompt,
      "metadata" => metadata_map(shot.metadata)
    }
    |> compact()
  end

  defp retry_map(%Retry{} = retry) do
    %{
      "max_attempts" => non_default(retry.max_attempts, 1),
      "backoff" => non_default(retry.backoff, :fixed),
      "base_delay" => non_default_duration(retry.base_delay_ms, 0),
      "max_delay" => non_default_duration(retry.max_delay_ms, retry.base_delay_ms),
      "retryable_errors" => non_empty(Enum.map(retry.retryable_errors, &Atom.to_string/1))
    }
    |> stringify_atoms()
    |> compact()
  end

  defp choke_map(%Choke{} = choke) do
    %{
      "token_budget" => choke.token_budget,
      "max_iterations" => non_default(choke.max_iterations, 6),
      "tool_safety" => non_default(choke.tool_safety, :read_only),
      "audit" => non_default(choke.audit, :summary)
    }
    |> stringify_atoms()
    |> compact()
  end

  defp agent_tools_map(%Tools{} = tools) do
    %{
      "allowed" => non_empty(tools.allowed),
      "denied" => non_empty(tools.denied)
    }
    |> compact()
  end

  defp agent_choke_map(%AgentChoke{} = choke) do
    %{
      "token_budget" => choke.token_budget,
      "max_iterations" => non_default(choke.max_iterations, 6),
      "timeout" => duration(choke.timeout_ms)
    }
    |> compact()
  end

  defp memory_map(%Memory{type: :none}), do: nil

  defp metadata_map(%Metadata{} = metadata), do: metadata |> Metadata.to_map() |> non_empty_map()
  defp metadata_map(_metadata), do: nil

  defp schema_map(nil), do: nil
  defp schema_map(%Schema{root: root}), do: root

  defp duration(nil), do: nil
  defp duration(ms) when is_integer(ms), do: "#{ms}ms"
  defp non_default(value, value), do: nil
  defp non_default(value, _default), do: value
  defp non_default_duration(value, value), do: nil
  defp non_default_duration(value, _default), do: duration(value)
  defp non_empty([]), do: nil
  defp non_empty(value), do: value
  defp non_empty_map(map) when map == %{}, do: nil
  defp non_empty_map(map), do: map

  defp stringify_atoms(map) do
    Map.new(map, fn
      {key, nil} -> {key, nil}
      {key, value} when is_atom(value) -> {key, Atom.to_string(value)}
      pair -> pair
    end)
  end

  defp compact(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = compact(value)

      if empty?(value) do
        acc
      else
        Map.put(acc, to_string(key), value)
      end
    end)
  end

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(value), do: value

  defp empty?(nil), do: true
  defp empty?(map) when map == %{}, do: true
  defp empty?(_value), do: false

  defp encode_error(format, reason) do
    {:error,
     Twelvgaige.Error.new(:compile_error, :invalid_shell, "failed to encode shell document",
       details: %{format: Atom.to_string(format), reason: inspect(reason)}
     )}
  end

  defp encode_yaml(value), do: yaml_value(value, 0) <> "\n"

  defp yaml_value(map, indent) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> yaml_pair(key, value, indent) end)
    |> Enum.join("\n")
  end

  defp yaml_pair(key, value, indent) when is_map(value) do
    "#{spaces(indent)}#{yaml_key(key)}:\n#{yaml_value(value, indent + 2)}"
  end

  defp yaml_pair(key, value, indent) when is_list(value) do
    "#{spaces(indent)}#{yaml_key(key)}:\n#{yaml_list(value, indent + 2)}"
  end

  defp yaml_pair(key, value, indent) do
    "#{spaces(indent)}#{yaml_key(key)}: #{yaml_scalar(value)}"
  end

  defp yaml_list([], indent), do: "#{spaces(indent)}[]"

  defp yaml_list(list, indent) do
    list
    |> Enum.map(&yaml_list_item(&1, indent))
    |> Enum.join("\n")
  end

  defp yaml_list_item(value, indent) when is_map(value) do
    pairs = Enum.sort_by(value, fn {key, _value} -> key end)

    case pairs do
      [] ->
        "#{spaces(indent)}- {}"

      [{key, value} | rest] ->
        first = yaml_list_map_first_pair(key, value, indent)

        rest =
          rest
          |> Enum.map(fn {key, value} -> yaml_pair(key, value, indent + 2) end)
          |> Enum.join("\n")

        [first, rest]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")
    end
  end

  defp yaml_list_item(value, indent) when is_list(value) do
    "#{spaces(indent)}-\n#{yaml_list(value, indent + 2)}"
  end

  defp yaml_list_item(value, indent), do: "#{spaces(indent)}- #{yaml_scalar(value)}"

  defp yaml_list_map_first_pair(key, value, indent) when is_map(value) or is_list(value) do
    "#{spaces(indent)}- #{yaml_key(key)}:\n#{yaml_value_or_list(value, indent + 4)}"
  end

  defp yaml_list_map_first_pair(key, value, indent) do
    "#{spaces(indent)}- #{yaml_key(key)}: #{yaml_scalar(value)}"
  end

  defp yaml_value_or_list(value, indent) when is_list(value), do: yaml_list(value, indent)
  defp yaml_value_or_list(value, indent), do: yaml_value(value, indent)

  defp yaml_key(key) do
    if Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_-]*$/, key) do
      key
    else
      Jason.encode!(key)
    end
  end

  defp yaml_scalar(value) when is_binary(value), do: Jason.encode!(value)
  defp yaml_scalar(value) when is_integer(value), do: Integer.to_string(value)
  defp yaml_scalar(value) when is_float(value), do: :erlang.float_to_binary(value, [:compact])
  defp yaml_scalar(true), do: "true"
  defp yaml_scalar(false), do: "false"
  defp spaces(count), do: String.duplicate(" ", count)
end
