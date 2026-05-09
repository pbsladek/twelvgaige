defmodule Twelvgaige.Shot.Executor do
  @moduledoc """
  Executes one shot attempt.

  This module is intentionally pure at the orchestration boundary: callers pass
  in an immutable `Shot.Attempt`, and the executor returns either one structured
  success payload or one classified `%Twelvgaige.Error{}`. It may call providers
  and tools internally, but it does not advance round state.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.LLM
  alias Twelvgaige.Output.Parser, as: OutputParser
  alias Twelvgaige.Redactor
  alias Twelvgaige.Shot.Attempt
  alias Twelvgaige.Tool
  alias Twelvgaige.Tool.Call

  @default_max_iterations 6
  @default_max_tool_calls_per_shot 1
  @default_tool_output_bytes 256 * 1024
  @default_tool_output_bytes_per_shot 1024 * 1024
  @default_tool_result_message_bytes 64 * 1024
  @default_message_bytes 2 * 1024 * 1024

  @type success :: %{
          content: String.t(),
          output: term(),
          tool_calls: [map()],
          usage: map(),
          messages: [map()]
        }

  @spec run(Attempt.t(), keyword()) :: {:ok, success()} | {:error, Error.t()}
  def run(%Attempt{} = attempt, opts \\ []) do
    messages = build_initial_messages(attempt)

    with :ok <- ensure_message_budget(attempt, messages, opts) do
      run_loop(attempt, messages, opts, 0, [], %{})
    end
  end

  defp run_loop(attempt, messages, opts, iteration, tool_results, usage) do
    max_iterations = max_iterations(attempt, opts)

    if iteration >= max_iterations do
      max_iterations_error(attempt, max_iterations)
    else
      with :ok <- ensure_message_budget(attempt, messages, opts),
           {:ok, response} <- complete(attempt, messages, opts, iteration),
           :ok <- ensure_token_budget(attempt, response.usage, opts) do
        usage = merge_usage(usage, response.usage)

        case response.tool_calls do
          [] ->
            with {:ok, output} <- OutputParser.parse(response.content, output_schema(attempt)) do
              {:ok,
               %{
                 content: response.content,
                 output: output,
                 tool_calls: tool_results,
                 usage: usage,
                 messages: messages
               }}
            end

          calls ->
            with :ok <- ensure_tool_call_budget(tool_results, calls, opts),
                 {:ok, normalized_calls} <- normalize_tool_calls(calls),
                 {:ok, call_results} <- execute_tool_calls(normalized_calls, attempt, opts),
                 :ok <- ensure_tool_output_budget(tool_results, call_results, opts) do
              next_messages =
                messages ++
                  [assistant_message(response)] ++
                  Enum.map(call_results, &tool_result_message(&1, opts))

              with :ok <- ensure_message_budget(attempt, next_messages, opts) do
                run_loop(
                  attempt,
                  next_messages,
                  opts,
                  iteration + 1,
                  tool_results ++ call_results,
                  usage
                )
              end
            end
        end
      end
    end
  end

  defp complete(attempt, messages, opts, iteration) do
    loadout = attempt.loadout || %{}
    provider = Map.get(loadout, :provider, Map.get(loadout, "provider", :mock))
    model = Map.get(loadout, :model, Map.get(loadout, "model", "mock-model"))

    LLM.complete(provider, model, messages, llm_opts(opts, attempt, iteration))
  end

  defp llm_opts(opts, attempt, iteration) do
    error_opts =
      opts
      |> Keyword.take([:error, :mock_handler])
      |> Keyword.put(:mock_iteration, iteration)

    limiter_opts = [
      limiter: Keyword.get(opts, :limiter, Twelvgaige.ResourceLimiter),
      metrics: Keyword.get(opts, :metrics, Twelvgaige.Metrics),
      limiter_context: %{
        round_id: attempt.round_id,
        shot_id: attempt.shot_id,
        attempt: attempt.attempt
      }
    ]

    response_opts =
      cond do
        responses = Keyword.get(opts, :responses) ->
          case Enum.at(responses, iteration) do
            nil -> []
            response -> [response: response]
          end

        iteration == 0 and Keyword.has_key?(opts, :response) ->
          [response: Keyword.fetch!(opts, :response)]

        true ->
          []
      end

    error_opts ++ limiter_opts ++ response_opts
  end

  defp normalize_tool_calls(calls) do
    calls
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {call, index}, {:ok, acc} ->
      case Call.normalize(call, index) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, calls} -> {:ok, Enum.reverse(calls)}
      {:error, _error} = error -> error
    end
  end

  defp ensure_tool_call_budget(existing_results, new_calls, opts) do
    max_tool_calls = Keyword.get(opts, :max_tool_calls_per_shot, @default_max_tool_calls_per_shot)
    total = length(existing_results) + length(new_calls)

    if total <= max_tool_calls do
      :ok
    else
      {:error,
       Error.new(:policy_error, :policy_denied, "shot exceeded tool call limit",
         safety_required: true,
         details: %{max_tool_calls_per_shot: max_tool_calls, attempted_tool_calls: total}
       )}
    end
  end

  defp execute_tool_calls(calls, attempt, opts) do
    Enum.reduce_while(calls, {:ok, []}, fn call, {:ok, acc} ->
      case execute_tool_call(call, attempt, opts) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _error} = error -> error
    end
  end

  defp execute_tool_call(%Call{} = call, attempt, opts) do
    tool_opts = tool_opts(call.name, opts)

    executor_opts = [
      allowed_tools: allowed_tools(attempt),
      max_safety: tool_safety(attempt),
      store: Keyword.get(opts, :store),
      limiter: Keyword.get(opts, :limiter, Twelvgaige.ResourceLimiter),
      context: %{
        round_id: attempt.round_id,
        shot_id: attempt.shot_id,
        attempt: attempt.attempt,
        tool_call_id: call.id
      },
      timeout_ms: Keyword.get(opts, :tool_timeout_ms, 30_000),
      max_output_bytes: Keyword.get(opts, :tool_max_output_bytes, @default_tool_output_bytes),
      metrics: Keyword.get(opts, :metrics, Twelvgaige.Metrics),
      tool_opts: tool_opts
    ]

    with {:ok, output} <- Tool.Executor.execute(call.name, call.input, executor_opts) do
      {:ok,
       %{
         "id" => call.id,
         "name" => call.name,
         "status" => "complete",
         "input" => call.input,
         "output" => output
       }}
    end
  end

  defp ensure_tool_output_budget(existing_results, new_results, opts) do
    max_bytes =
      Keyword.get(
        opts,
        :tool_max_output_bytes_per_shot,
        @default_tool_output_bytes_per_shot
      )

    used_bytes = tool_output_bytes(existing_results ++ new_results)

    if used_bytes <= max_bytes do
      :ok
    else
      {:error,
       Error.new(:output_error, :output_too_large, "shot tool output exceeded byte limit",
         retryable: false,
         details: %{max_output_bytes_per_shot: max_bytes, output_bytes: used_bytes}
       )}
    end
  end

  defp tool_output_bytes(results) do
    results
    |> Enum.map(&Map.get(&1, "output"))
    |> Jason.encode!()
    |> byte_size()
  rescue
    _error -> 0
  end

  defp allowed_tools(%Attempt{definition: %{tools: tools}}) when is_list(tools), do: tools
  defp allowed_tools(_attempt), do: []

  defp tool_safety(%Attempt{definition: %{choke: %{tool_safety: tool_safety}}}), do: tool_safety
  defp tool_safety(_attempt), do: :read_only

  defp output_schema(%Attempt{definition: %{output_schema: output_schema}}), do: output_schema
  defp output_schema(_attempt), do: nil

  defp tool_opts(tool_name, opts) do
    shared = Keyword.get(opts, :tool_opts, [])

    by_name =
      opts
      |> Keyword.get(:tool_opts_by_name, %{})
      |> lookup_tool_opts(tool_name)

    shared ++ by_name
  end

  defp lookup_tool_opts(%{} = map, tool_name) do
    case Enum.find(map, fn {key, _value} -> key_string(key) == tool_name end) do
      {_key, value} -> value
      nil -> []
    end
  end

  defp lookup_tool_opts(list, tool_name) when is_list(list) do
    case Enum.find(list, fn {key, _value} -> key_string(key) == tool_name end) do
      {_key, value} -> value
      nil -> []
    end
  end

  defp lookup_tool_opts(_opts, _tool_name), do: []

  defp key_string(key) when is_binary(key), do: key
  defp key_string(key) when is_atom(key), do: Atom.to_string(key)
  defp key_string(key), do: inspect(key)

  defp build_initial_messages(%Attempt{} = attempt) do
    loadout = attempt.loadout || %{}

    system_prompt =
      Map.get(loadout, :system_prompt, Map.get(loadout, "system_prompt")) ||
        "You are running a Twelvgaige shot."

    [
      %{role: "system", content: system_prompt, source: :system},
      %{
        role: "user",
        content: user_content(attempt),
        source: :round_context
      }
    ]
  end

  defp user_content(%Attempt{} = attempt) do
    definition = attempt.definition
    prompt = Map.get(definition, :prompt) || Map.get(definition, :description) || attempt.shot_id

    context = %{
      "round_input" => attempt.input,
      "dependency_outputs" => attempt.dependency_outputs
    }

    "#{prompt}\n\nContext:\n#{Jason.encode!(context)}"
  end

  defp assistant_message(response) do
    %{
      role: "assistant",
      content: response.content,
      source: :round_context
    }
  end

  defp tool_result_message(result, opts) do
    %{
      role: "tool",
      name: result["name"],
      tool_call_id: result["id"],
      content: tool_result_content(result["output"], opts),
      source: :tool_execution
    }
  end

  defp tool_result_content(output, opts) do
    max_bytes =
      Keyword.get(opts, :tool_result_message_max_bytes, @default_tool_result_message_bytes)

    output
    |> Redactor.redact_json()
    |> Jason.encode!()
    |> cap_tool_result_content(max_bytes)
  end

  defp cap_tool_result_content(encoded, max_bytes)
       when is_integer(max_bytes) and max_bytes > 0 and byte_size(encoded) > max_bytes do
    original_bytes = byte_size(encoded)
    preview_bytes = max(max_bytes - 96, 0)
    preview = binary_part(encoded, 0, min(original_bytes, preview_bytes))

    %{
      "truncated" => true,
      "original_bytes" => original_bytes,
      "max_bytes" => max_bytes,
      "preview" => preview
    }
    |> Jason.encode!()
    |> enforce_content_cap(max_bytes)
  end

  defp cap_tool_result_content(encoded, _max_bytes), do: encoded

  defp enforce_content_cap(encoded, max_bytes) when byte_size(encoded) <= max_bytes, do: encoded

  defp enforce_content_cap(_encoded, max_bytes) do
    fallback = ~s({"truncated":true})

    if byte_size(fallback) <= max_bytes do
      fallback
    else
      binary_part(fallback, 0, max(max_bytes, 0))
    end
  end

  defp max_iterations(%Attempt{definition: %{choke: %{max_iterations: max_iterations}}}, _opts)
       when is_integer(max_iterations) and max_iterations > 0 do
    max_iterations
  end

  defp max_iterations(_attempt, opts) do
    Keyword.get(opts, :max_iterations, @default_max_iterations)
  end

  defp max_iterations_error(attempt, max_iterations) do
    {:error,
     Error.new(:output_error, :output_parse_error, "shot exceeded max ReAct iterations",
       retryable: false,
       details: %{
         round_id: attempt.round_id,
         shot_id: attempt.shot_id,
         attempt: attempt.attempt,
         max_iterations: max_iterations
       }
     )}
  end

  defp merge_usage(left, right) when map_size(left) == 0, do: right
  defp merge_usage(left, right) when map_size(right) == 0, do: left

  defp merge_usage(left, right) do
    Map.merge(left, right, fn
      _key, left_value, right_value when is_number(left_value) and is_number(right_value) ->
        left_value + right_value

      _key, _left_value, right_value ->
        right_value
    end)
  end

  defp ensure_message_budget(attempt, messages, opts) do
    max_bytes = message_byte_budget(attempt, opts)
    used_bytes = messages_byte_size(messages)

    if used_bytes <= max_bytes do
      :ok
    else
      {:error,
       Error.new(:llm_error, :llm_context_too_large, "LLM message budget exceeded",
         retryable: false,
         details: %{
           round_id: attempt.round_id,
           shot_id: attempt.shot_id,
           attempt: attempt.attempt,
           max_message_bytes: max_bytes,
           message_bytes: used_bytes
         }
       )}
    end
  end

  defp ensure_token_budget(attempt, usage, opts) do
    case {token_budget(attempt, opts), total_tokens(usage)} do
      {nil, _tokens} ->
        :ok

      {_budget, nil} ->
        :ok

      {budget, tokens} when tokens <= budget ->
        :ok

      {budget, tokens} ->
        {:error,
         Error.new(:llm_error, :llm_context_too_large, "LLM token budget exceeded",
           retryable: false,
           details: %{
             round_id: attempt.round_id,
             shot_id: attempt.shot_id,
             attempt: attempt.attempt,
             token_budget: budget,
             total_tokens: tokens
           }
         )}
    end
  end

  defp message_byte_budget(attempt, opts) do
    opts
    |> Keyword.get(:max_llm_message_bytes, choke_value(attempt, :message_bytes))
    |> case do
      value when is_integer(value) and value > 0 -> value
      _value -> @default_message_bytes
    end
  end

  defp token_budget(attempt, opts) do
    opts
    |> Keyword.get(:token_budget, choke_value(attempt, :token_budget))
    |> case do
      value when is_integer(value) and value > 0 -> value
      _value -> nil
    end
  end

  defp messages_byte_size(messages) do
    messages
    |> Jason.encode!()
    |> byte_size()
  end

  defp total_tokens(%{} = usage) do
    case Map.get(usage, :total_tokens, Map.get(usage, "total_tokens")) do
      value when is_integer(value) and value >= 0 -> value
      value when is_float(value) and value >= 0 -> trunc(value)
      _value -> nil
    end
  end

  defp choke_value(%Attempt{definition: %{choke: choke}}, key) do
    Map.get(choke, key, Map.get(choke, Atom.to_string(key)))
  end

  defp choke_value(_attempt, _key), do: nil
end
