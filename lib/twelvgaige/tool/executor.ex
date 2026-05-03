defmodule Twelvgaige.Tool.Executor do
  @moduledoc """
  Permission-checked, resource-bounded tool execution.

  The executor is the policy boundary for tools. Built-ins only implement their
  narrow operation; this module enforces the shot allowlist, safety threshold,
  schema validation, resource admission, timeout, and generic output limit.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Metrics
  alias Twelvgaige.ResourceLimiter
  alias Twelvgaige.Tool.Catalog
  alias Twelvgaige.Tool.InputValidator
  alias Twelvgaige.Tool.IntentJournal
  alias Twelvgaige.Tool.Safety

  @default_timeout_ms 30_000
  @default_max_output_bytes 1_048_576

  @spec execute(String.t() | atom(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def execute(tool_name, input, opts \\ [])

  def execute(tool_name, input, opts) when is_map(input) and is_list(opts) do
    started_mono = monotonic_ms()
    result = do_execute(tool_name, input, opts)
    record_tool_metrics(tool_name, result, started_mono, opts)
    result
  end

  def execute(_tool_name, _input, _opts) do
    {:error,
     Error.new(:tool_error, :tool_input_invalid, "tool input must be a map",
       details: %{expected: "map"}
     )}
  end

  defp do_execute(tool_name, input, opts) do
    with {:ok, tool} <- fetch_tool(tool_name, opts),
         :ok <- ensure_allowed(tool.name(), Keyword.get(opts, :allowed_tools, [])),
         :ok <- ensure_safety(tool, Keyword.get(opts, :max_safety, :read_only)),
         :ok <- InputValidator.validate(input, tool.input_schema()),
         :ok <- record_tool_intent(tool, input, opts),
         {:ok, permit} <- acquire_permit(tool, opts) do
      try do
        result =
          tool
          |> run_tool(input, opts)
          |> enforce_output_limit(Keyword.get(opts, :max_output_bytes, @default_max_output_bytes))

        with :ok <- record_tool_result(tool, input, result, opts) do
          result
        end
      after
        release_permit(permit)
      end
    end
  end

  defp fetch_tool(tool_name, opts) do
    catalog = Keyword.get(opts, :catalog, Catalog)
    catalog.fetch(tool_name)
  end

  defp ensure_allowed(_tool_name, :all), do: :ok

  defp ensure_allowed(tool_name, allowed_tools) when is_list(allowed_tools) do
    allowed_tools = Enum.map(allowed_tools, &to_string/1)

    if tool_name in allowed_tools do
      :ok
    else
      {:error,
       Error.new(:tool_error, :tool_denied, "tool #{inspect(tool_name)} is not allowlisted",
         safety_required: true,
         details: %{tool: tool_name, allowed_tools: allowed_tools}
       )}
    end
  end

  defp ensure_allowed(tool_name, _allowed_tools) do
    {:error,
     Error.new(:tool_error, :tool_denied, "tool #{inspect(tool_name)} is not allowlisted",
       safety_required: true,
       details: %{tool: tool_name}
     )}
  end

  defp ensure_safety(tool, max_safety) do
    actual = tool.safety_level()

    cond do
      not Safety.valid?(max_safety) ->
        {:error,
         Error.new(:policy_error, :policy_denied, "invalid tool safety threshold",
           safety_required: true,
           details: %{max_safety: max_safety}
         )}

      Safety.allows?(max_safety, actual) ->
        :ok

      true ->
        {:error,
         Error.new(
           :policy_error,
           :policy_denied,
           "tool #{inspect(tool.name())} requires #{actual} safety",
           safety_required: true,
           details: %{tool: tool.name(), max_safety: max_safety, tool_safety: actual}
         )}
    end
  end

  defp record_tool_intent(tool, input, opts) do
    case Keyword.get(opts, :store) do
      nil ->
        :ok

      store ->
        journal = IntentJournal.new(tool, input, opts)

        case store.record_tool_intent(journal, [IntentJournal.audit_event(journal)]) do
          status when status in [:ok, :already_recorded] ->
            :ok

          {:error, reason} ->
            {:error,
             Error.new(:store_error, :store_unavailable, "failed to record tool intent",
               retryable: true,
               details: %{tool: tool.name(), reason: inspect(reason)}
             )}
        end
    end
  rescue
    error ->
      {:error,
       Error.new(:store_error, :store_unavailable, "failed to record tool intent",
         retryable: true,
         details: %{tool: safe_tool_name(tool), reason: Exception.message(error)}
       )}
  end

  defp record_tool_result(tool, input, result, opts) do
    case Keyword.get(opts, :store) do
      nil ->
        :ok

      store ->
        journal = IntentJournal.result(tool, input, result, opts)

        case store.record_tool_result(journal, [IntentJournal.audit_event(journal)]) do
          status when status in [:ok, :already_recorded] ->
            :ok

          {:error, reason} ->
            {:error,
             Error.new(:store_error, :store_unavailable, "failed to record tool result",
               retryable: true,
               details: %{tool: tool.name(), reason: inspect(reason)}
             )}
        end
    end
  rescue
    error ->
      {:error,
       Error.new(:store_error, :store_unavailable, "failed to record tool result",
         retryable: true,
         details: %{tool: safe_tool_name(tool), reason: Exception.message(error)}
       )}
  end

  defp acquire_permit(tool, opts) do
    limiter = Keyword.get(opts, :limiter, ResourceLimiter)

    if limiter_available?(limiter) do
      context =
        opts
        |> Keyword.get(:context, %{})
        |> Map.put(:tool_name, tool.name())

      case ResourceLimiter.acquire({:tool_call, tool.name()}, context,
             server: limiter,
             owner_pid: self()
           ) do
        {:ok, permit} ->
          {:ok, permit}

        {:error, {:limit_exceeded, _limit} = reason} ->
          {:error,
           Error.new(:timeout_error, :resource_queue_timeout, "tool resource limit exceeded",
             retryable: true,
             details: %{reason: inspect(reason), tool: tool.name()}
           )}

        {:error, reason} ->
          {:error,
           Error.new(:internal_error, :policy_denied, "tool resource admission failed",
             details: %{reason: inspect(reason), tool: tool.name()}
           )}
      end
    else
      {:ok, nil}
    end
  end

  defp limiter_available?(nil), do: false
  defp limiter_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp limiter_available?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp run_tool(tool, input, opts) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    tool_opts = Keyword.get(opts, :tool_opts, [])
    owner = self()
    ref = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(owner, {ref, tool.execute(input, tool_opts)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor_ref, [:flush])
        normalize_tool_result(result, tool)

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        {:error,
         Error.new(:crash_error, :shot_crash, "tool process crashed",
           retryable: true,
           details: %{tool: tool.name(), reason: inspect(reason)}
         )}
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        flush_down(monitor_ref)

        {:error,
         Error.new(:timeout_error, :tool_timeout, "tool timed out",
           retryable: true,
           details: %{tool: tool.name(), timeout_ms: timeout_ms}
         )}
    end
  end

  defp normalize_tool_result({:ok, result}, _tool) when is_map(result), do: {:ok, result}

  defp normalize_tool_result({:ok, result}, tool) do
    {:error,
     Error.new(:tool_error, :tool_non_retryable, "tool returned a non-map result",
       details: %{tool: tool.name(), returned: inspect(result)}
     )}
  end

  defp normalize_tool_result({:error, %Error{} = error}, _tool), do: {:error, error}
  defp normalize_tool_result({:error, reason}, tool), do: {:error, tool_error(reason, tool)}

  defp normalize_tool_result(result, tool) do
    {:error,
     Error.new(:tool_error, :tool_non_retryable, "tool returned invalid result",
       details: %{tool: tool.name(), returned: inspect(result)}
     )}
  end

  defp flush_down(monitor_ref) do
    receive do
      {:DOWN, ^monitor_ref, :process, _pid, _reason} -> :ok
    after
      0 -> :ok
    end
  end

  defp enforce_output_limit({:error, _error} = error, _max_output_bytes), do: error

  defp enforce_output_limit({:ok, output}, max_output_bytes) do
    case Jason.encode(output) do
      {:ok, encoded} when byte_size(encoded) <= max_output_bytes ->
        {:ok, output}

      {:ok, encoded} ->
        {:error,
         Error.new(:output_error, :output_too_large, "tool output exceeded byte limit",
           retryable: false,
           details: %{bytes: byte_size(encoded), max_output_bytes: max_output_bytes}
         )}

      {:error, reason} ->
        {:error,
         Error.new(:tool_error, :tool_non_retryable, "tool output was not JSON encodable",
           details: %{reason: inspect(reason)}
         )}
    end
  end

  defp release_permit(nil), do: :ok

  defp release_permit(%ResourceLimiter.Permit{} = permit) do
    case ResourceLimiter.release(permit) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp safe_tool_name(tool) do
    tool.name()
  rescue
    _error -> inspect(tool)
  end

  defp tool_error(:retryable, tool) do
    Error.new(:tool_error, :tool_retryable, "tool returned retryable failure",
      retryable: true,
      details: %{tool: tool.name()}
    )
  end

  defp tool_error(:non_retryable, tool) do
    Error.new(:tool_error, :tool_non_retryable, "tool returned non-retryable failure",
      details: %{tool: tool.name()}
    )
  end

  defp tool_error(reason, tool) do
    Error.new(:tool_error, :tool_non_retryable, "tool returned failure",
      details: %{tool: tool.name(), reason: inspect(reason)}
    )
  end

  defp record_tool_metrics(tool_name, result, started_mono, opts) do
    labels =
      %{
        tool_name: to_string(tool_name),
        status: tool_status(result)
      }
      |> maybe_error_class(result)

    Metrics.counter("twelvgaige_tool_calls_total", labels, 1, metrics_opts(opts))

    Metrics.observe(
      "twelvgaige_tool_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics_opts(opts)
    )

    record_tool_output_bytes(result, labels, opts)
  end

  defp record_tool_output_bytes({:ok, output}, labels, opts) do
    bytes =
      case Jason.encode(output) do
        {:ok, encoded} -> byte_size(encoded)
        {:error, _reason} -> 0
      end

    Metrics.observe("twelvgaige_tool_output_bytes", bytes, labels, metrics_opts(opts))
  end

  defp record_tool_output_bytes(_result, _labels, _opts), do: :ok

  defp maybe_error_class(labels, {:error, %Error{} = error}),
    do: Map.put(labels, :error_class, error.class)

  defp maybe_error_class(labels, _result), do: labels

  defp tool_status({:ok, _output}), do: :complete
  defp tool_status({:error, _error}), do: :failed
  defp tool_status(_result), do: :unknown

  defp metrics_opts(opts), do: [metrics: Keyword.get(opts, :metrics, Metrics)]

  defp duration_seconds(started_mono), do: max(monotonic_ms() - started_mono, 0) / 1000

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
