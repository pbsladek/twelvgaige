defmodule Twelvgaige.LLM do
  @moduledoc """
  Provider router for normalized LLM calls.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.LLM.Provider
  alias Twelvgaige.LLM.Providers.Anthropic
  alias Twelvgaige.LLM.Providers.Gemini
  alias Twelvgaige.LLM.Providers.Mock
  alias Twelvgaige.LLM.Providers.Ollama
  alias Twelvgaige.LLM.Providers.OpenAI
  alias Twelvgaige.LLM.ProviderConfig
  alias Twelvgaige.Metrics
  alias Twelvgaige.ResourceLimiter

  @providers %{
    "mock" => Mock,
    "anthropic" => Anthropic,
    "openai" => OpenAI,
    "gemini" => Gemini,
    "ollama" => Ollama,
    mock: Mock,
    anthropic: Anthropic,
    openai: OpenAI,
    gemini: Gemini,
    ollama: Ollama
  }

  @spec complete(String.t() | atom(), String.t(), [map()], keyword()) ::
          {:ok, Twelvgaige.LLM.Response.t()} | {:error, Error.t()}
  def complete(provider, model, messages, opts \\ []) do
    started_mono = monotonic_ms()
    provider_opts = ProviderConfig.resolve(provider, opts)

    result =
      with {:ok, module} <- provider_module(provider),
           :ok <- validate_provider_module(module),
           :ok <- validate_capabilities(module, provider_opts) do
        with_llm_permit(provider, model, provider_opts, fn ->
          module.complete(model, messages, provider_opts)
        end)
      end

    record_llm_metrics(provider, model, result, started_mono, provider_opts)
    result
  end

  @spec capabilities(String.t() | atom(), map()) ::
          {:ok, Twelvgaige.LLM.Capabilities.t()} | {:error, Error.t()}
  def capabilities(provider, config \\ %{}) do
    with {:ok, module} <- provider_module(provider),
         :ok <- validate_provider_module(module) do
      {:ok, module.capabilities(config)}
    end
  end

  @spec known_provider?(String.t() | atom()) :: boolean()
  def known_provider?(provider), do: Map.has_key?(@providers, provider)

  defp provider_module(provider) do
    case Map.fetch(@providers, provider) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error,
         Error.new(:llm_error, :llm_bad_request, "unknown LLM provider #{inspect(provider)}",
           details: %{provider: provider}
         )}
    end
  end

  defp validate_provider_module(module) do
    if Provider.provider?(module) do
      :ok
    else
      {:error,
       Error.new(
         :internal_error,
         :llm_unknown,
         "configured provider does not implement provider behaviour",
         details: %{module: inspect(module)}
       )}
    end
  end

  defp validate_capabilities(module, opts) do
    capabilities = module.capabilities(Keyword.get(opts, :capability_config, %{}))

    cond do
      native_tools_requested?(opts) and not capabilities.supports_tools ->
        capability_error(module, :tools, "native tool calls are not supported by provider")

      native_json_schema_requested?(opts) and not capabilities.supports_json_schema ->
        capability_error(
          module,
          :json_schema,
          "native JSON schema output is not supported by provider"
        )

      true ->
        :ok
    end
  end

  defp native_tools_requested?(opts) do
    case Keyword.get(opts, :tools) do
      tools when is_list(tools) -> tools != []
      nil -> false
      _tools -> true
    end
  end

  defp native_json_schema_requested?(opts) do
    Enum.any?(
      [
        Keyword.get(opts, :json_schema),
        Keyword.get(opts, :native_json_schema),
        Keyword.get(opts, :response_schema),
        Keyword.get(opts, :response_format)
      ],
      &present?/1
    )
  end

  defp present?(nil), do: false
  defp present?([]), do: false
  defp present?(%{} = map), do: map_size(map) > 0
  defp present?(_value), do: true

  defp capability_error(module, capability, message) do
    provider = module.provider_id()

    {:error,
     Error.new(:policy_error, :policy_denied, message,
       retryable: false,
       details: %{provider: provider, capability: capability}
     )}
  end

  defp with_llm_permit(provider, model, opts, fun) do
    case acquire_permit(provider, model, opts) do
      {:ok, nil} ->
        fun.()

      {:ok, permit} ->
        try do
          fun.()
        after
          release_permit(permit)
        end

      {:error, _error} = error ->
        error
    end
  end

  defp acquire_permit(provider, model, opts) do
    limiter = Keyword.get(opts, :limiter)

    if limiter_available?(limiter) do
      context =
        opts
        |> Keyword.get(:limiter_context, Keyword.get(opts, :context, %{}))
        |> normalize_context()
        |> Map.merge(%{provider: stringify(provider), model: model})

      case ResourceLimiter.acquire(:llm_call, context, server: limiter, owner_pid: self()) do
        {:ok, permit} ->
          {:ok, permit}

        {:error, {:limit_exceeded, _limit} = reason} ->
          {:error,
           Error.new(:timeout_error, :resource_queue_timeout, "LLM resource limit exceeded",
             retryable: true,
             details: %{provider: stringify(provider), model: model, reason: inspect(reason)}
           )}

        {:error, reason} ->
          {:error,
           Error.new(:internal_error, :policy_denied, "LLM resource admission failed",
             details: %{provider: stringify(provider), model: model, reason: inspect(reason)}
           )}
      end
    else
      {:ok, nil}
    end
  end

  defp release_permit(%ResourceLimiter.Permit{} = permit) do
    case ResourceLimiter.release(permit) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp limiter_available?(nil), do: false
  defp limiter_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp limiter_available?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp normalize_context(%{} = context), do: context
  defp normalize_context(_context), do: %{}

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)

  defp record_llm_metrics(provider, model, result, started_mono, opts) do
    labels =
      %{
        provider: stringify(provider),
        model: model,
        status: llm_status(result)
      }
      |> maybe_error_class(result)

    Metrics.counter("twelvgaige_llm_calls_total", labels, 1, metrics_opts(opts))

    Metrics.observe(
      "twelvgaige_llm_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics_opts(opts)
    )

    record_token_metrics(result, provider, model, opts)
  end

  defp record_token_metrics({:ok, %{usage: usage}}, provider, model, opts) when is_map(usage) do
    for {token_kind, count} <- usage, is_number(count), count >= 0 do
      Metrics.counter(
        "twelvgaige_llm_tokens_total",
        %{provider: stringify(provider), model: model, token_kind: token_kind},
        count,
        metrics_opts(opts)
      )
    end

    :ok
  end

  defp record_token_metrics(_result, _provider, _model, _opts), do: :ok

  defp maybe_error_class(labels, {:error, %Error{} = error}),
    do: Map.put(labels, :error_class, error.class)

  defp maybe_error_class(labels, _result), do: labels

  defp llm_status({:ok, _response}), do: :complete
  defp llm_status({:error, _error}), do: :failed
  defp llm_status(_result), do: :unknown

  defp metrics_opts(opts), do: [metrics: Keyword.get(opts, :metrics, Metrics)]

  defp duration_seconds(started_mono), do: max(monotonic_ms() - started_mono, 0) / 1000

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
