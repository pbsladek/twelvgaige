defmodule Twelvgaige.Workspace.Git.MutationAudit do
  @moduledoc false

  @schema_version 1

  @enforce_keys [
    :workspace_id,
    :operation_id,
    :lease,
    :control_epoch,
    :scope,
    :sink
  ]
  defstruct [
    :workspace_id,
    :operation_id,
    :request_id,
    :lease,
    :control_epoch,
    :scope,
    :sink
  ]

  @type t :: %__MODULE__{}

  @spec new(map(), (map() -> :ok | {:error, term()})) :: {:ok, t()} | {:error, term()}
  def new(attrs, sink) when is_map(attrs) and is_function(sink, 1) do
    workspace_id = value(attrs, :workspace_id)
    operation_id = value(attrs, :operation_id)
    request_id = value(attrs, :request_id)
    lease = value(attrs, :lease)
    control_epoch = value(attrs, :control_epoch)
    scope = value(attrs, :scope)

    with :ok <- present(workspace_id, :git_mutation_audit_workspace_required),
         :ok <- present(operation_id, :git_mutation_audit_operation_required),
         :ok <- present(lease, :git_mutation_audit_lease_required),
         true <- is_integer(control_epoch) and control_epoch >= 0,
         true <- is_atom(scope) do
      {:ok,
       %__MODULE__{
         workspace_id: workspace_id,
         operation_id: operation_id,
         request_id: request_id,
         lease: lease,
         control_epoch: control_epoch,
         scope: scope,
         sink: sink
       }}
    else
      false -> {:error, :git_mutation_audit_context_invalid}
      {:error, _reason} = error -> error
    end
  end

  def new(_attrs, _sink), do: {:error, :git_mutation_audit_sink_required}

  @spec intent(t(), atom()) :: {:ok, String.t()} | {:error, term()}
  def intent(%__MODULE__{} = audit, command_class) when is_atom(command_class) do
    mutation_id = "gitmut_" <> random_id()

    case emit(audit, mutation_id, command_class, :intent, %{status: "authorized"}) do
      :ok -> {:ok, mutation_id}
      {:error, reason} -> {:error, {:git_mutation_audit_intent_failed, reason}}
    end
  end

  @spec terminal(t(), String.t(), atom(), term()) :: :ok | {:error, term()}
  def terminal(%__MODULE__{} = audit, mutation_id, command_class, result) do
    {phase, evidence} = terminal_evidence(result)

    case emit(audit, mutation_id, command_class, phase, evidence) do
      :ok -> :ok
      {:error, reason} -> {:error, {:git_mutation_audit_terminal_failed, reason}}
    end
  end

  defp emit(audit, mutation_id, command_class, phase, evidence) do
    event = %{
      schema_version: @schema_version,
      event_id: "#{mutation_id}:#{phase}",
      mutation_id: mutation_id,
      workspace_id: audit.workspace_id,
      operation_id: audit.operation_id,
      request_id: audit.request_id,
      lease: audit.lease,
      control_epoch: audit.control_epoch,
      scope: audit.scope,
      command_class: command_class,
      phase: phase,
      evidence: evidence,
      occurred_at: DateTime.utc_now() |> DateTime.truncate(:microsecond)
    }

    case audit.sink.(event) do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :git_mutation_audit_sink_invalid}
    end
  rescue
    _error -> {:error, :git_mutation_audit_sink_crashed}
  catch
    _kind, _reason -> {:error, :git_mutation_audit_sink_stopped}
  end

  defp terminal_evidence({:ok, output}) when is_binary(output),
    do: {:completed, %{status: "completed", output_bytes: byte_size(output)}}

  defp terminal_evidence(:ok), do: {:completed, %{status: "completed", output_bytes: 0}}

  defp terminal_evidence({:error, reason}),
    do: {:failed, %{status: "failed", reason_class: reason_class(reason)}}

  defp terminal_evidence(_result),
    do: {:failed, %{status: "failed", reason_class: "invalid_result"}}

  defp reason_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp reason_class(%{status: status}) when is_integer(status), do: "exit_status_#{status}"
  defp reason_class(_reason), do: "git_command_failed"

  defp random_id,
    do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  defp present(value, _error) when is_binary(value) and value != "", do: :ok
  defp present(_value, error), do: {:error, error}

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
