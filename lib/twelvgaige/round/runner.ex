defmodule Twelvgaige.Round.Runner do
  @moduledoc """
  Foreground Phase 1 round runner.

  This is the narrow synchronous execution path used before the Breech daemon
  and the full `Round.Server` state machine exist.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Loadout
  alias Twelvgaige.Metrics
  alias Twelvgaige.Pattern.Compiler
  alias Twelvgaige.ResourceLimiter
  alias Twelvgaige.RuntimeProfile
  alias Twelvgaige.Round.InputValidator
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Round.State, as: RoundState
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shot
  alias Twelvgaige.Shot.Attempt
  alias Twelvgaige.Shot.AttemptJournal
  alias Twelvgaige.Shot.Executor, as: ShotExecutor
  alias Twelvgaige.Shot.RetryPolicy

  @spec run(Workflow.t(), map(), keyword()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def run(%Workflow{} = workflow, input, opts \\ []) when is_map(input) do
    started_mono = monotonic_ms()

    result =
      with :ok <- InputValidator.validate(workflow, input),
           {:ok, profile} <- RuntimeProfile.effective(workflow.policy, opts),
           {:ok, compiled} <- Compiler.compile(workflow, compiler_opts(opts)) do
        opts = Keyword.put(opts, :profile, profile)

        state =
          RoundState.new(
            id: Keyword.get_lazy(opts, :round_id, fn -> Twelvgaige.ID.new(:round) end),
            shell_id: workflow.id,
            shell_version: workflow.version,
            pattern: compiled,
            policy: %{
              resource_profile: profile,
              safety_scope: workflow.policy.safety_scope,
              on_safety_reject: workflow.policy.on_safety_reject,
              queue_timeout_ms: workflow.policy.queue_timeout_ms
            },
            status: :firing,
            input: input,
            started_at: Twelvgaige.Clock.utc_now(),
            shots: Enum.map(workflow.shots, &shot_state_from_shell/1)
          )

        execute_until_terminal(state, opts)
      end

    record_round_metrics(result, workflow.id, started_mono, opts)
    result
  end

  @spec recover(Workflow.t(), Snapshot.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()}
  def recover(%Workflow{} = workflow, %Snapshot{} = snapshot, opts \\ []) when is_list(opts) do
    with {:ok, profile} <- RuntimeProfile.from_snapshot(snapshot, opts),
         {:ok, compiled} <- Compiler.compile(workflow, compiler_opts(opts)),
         {:ok, state} <- resumable_state(snapshot, compiled) do
      opts = Keyword.put(opts, :profile, profile)
      execute_until_terminal(state, opts)
    end
  end

  @spec approve_safety(Workflow.t(), Snapshot.t(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()}
  def approve_safety(%Workflow{} = workflow, %Snapshot{} = snapshot, shot_id, opts \\ [])
      when is_binary(shot_id) and is_list(opts) do
    resume_safety(workflow, snapshot, shot_id, :approved, opts)
  end

  @spec reject_safety(Workflow.t(), Snapshot.t(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Error.t()}
  def reject_safety(%Workflow{} = workflow, %Snapshot{} = snapshot, shot_id, opts \\ [])
      when is_binary(shot_id) and is_list(opts) do
    resume_safety(workflow, snapshot, shot_id, :rejected, opts)
  end

  defp resume_safety(workflow, snapshot, shot_id, decision, opts) do
    with {:ok, profile} <- RuntimeProfile.from_snapshot(snapshot, opts),
         {:ok, compiled} <- Compiler.compile(workflow, compiler_opts(opts)),
         {:ok, request} <- awaiting_safety_request(snapshot, shot_id),
         {:ok, state} <- resumable_state(snapshot, compiled),
         opts = Keyword.put(opts, :profile, profile),
         {:ok, state_or_snapshot} <-
           apply_external_safety_decision(state, request, decision, opts) do
      case state_or_snapshot do
        %Snapshot{} = snapshot -> {:ok, snapshot}
        %RoundState{} = state -> execute_until_terminal(state, opts)
      end
    end
  end

  defp execute_until_terminal(%RoundState{} = state, opts) do
    cond do
      RoundState.terminal?(state) ->
        {:ok, RoundState.to_snapshot(state)}

      failed = failed_shot(state) ->
        fail_round(state, failed.error || Error.new(:internal_error, :shot_crash, "shot failed"))

      RoundState.all_shots_successful?(state) ->
        complete_round(state)

      true ->
        case Compiler.readiness(state.pattern, state.shot_states, %{input: state.input}) do
          {:ok, %{skipped: skipped_shots}} when skipped_shots != [] ->
            state
            |> skip_shots(skipped_shots)
            |> execute_until_terminal(opts)

          {:ok, %{ready: []}} ->
            if awaiting_safety?(state) do
              {:ok, RoundState.to_snapshot(state)}
            else
              fail_round(state, :internal_error, :shot_crash, "round made no progress")
            end

          {:ok, %{ready: ready_shots}} ->
            state
            |> run_ready_shots(ready_shots, opts)
            |> case do
              {:ok, next_state} -> execute_until_terminal(next_state, opts)
              {:snapshot, snapshot} -> {:ok, snapshot}
              {:error, _error} = error -> error
            end

          {:error, _error} = error ->
            error
        end
    end
  end

  defp skip_shots(%RoundState{} = state, shots) do
    now = Twelvgaige.Clock.utc_now()

    Enum.reduce(shots, state, fn shot, acc ->
      skipped =
        acc.shot_states
        |> Map.fetch!(shot.id)
        |> Map.merge(%{
          status: :skipped,
          output: %{"skipped" => true},
          completed_at: now
        })

      RoundState.put_shot(acc, skipped)
    end)
  end

  defp run_ready_shots(state, ready_shots, opts) do
    if parallel_ready_shots?(ready_shots, opts) do
      run_ready_shots_parallel(state, ready_shots, opts)
    else
      run_ready_shots_sequential(state, ready_shots, opts)
    end
  end

  defp run_ready_shots_sequential(state, ready_shots, opts) do
    Enum.reduce_while(ready_shots, {:ok, state}, fn shot, {:ok, acc} ->
      case run_shot(acc, shot, opts) do
        {:ok, next_state} -> {:cont, {:ok, next_state}}
        {:snapshot, snapshot} -> {:halt, {:snapshot, snapshot}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp run_ready_shots_parallel(state, ready_shots, opts) do
    ready_shots
    |> Task.async_stream(
      fn shot -> run_parallel_shot(state, shot, opts) end,
      max_concurrency: max_parallel_shots(opts),
      ordered: true,
      timeout: :infinity
    )
    |> Enum.reduce_while({:ok, state}, fn
      {:ok, {:ok, shot_state}}, {:ok, acc} ->
        {:cont, {:ok, RoundState.put_shot(acc, shot_state)}}

      {:ok, {:snapshot, snapshot}}, {:ok, _acc} ->
        {:halt, {:snapshot, snapshot}}

      {:ok, {:error, _error} = error}, {:ok, _acc} ->
        {:halt, error}

      {:exit, reason}, {:ok, _acc} ->
        {:halt, {:error, parallel_shot_crash_error(reason)}}
    end)
  end

  defp run_parallel_shot(state, shot, opts) do
    case run_shot(state, shot, opts) do
      {:ok, next_state} -> {:ok, Map.fetch!(next_state.shot_states, shot.id)}
      other -> other
    end
  end

  defp parallel_ready_shots?(ready_shots, opts) do
    Keyword.get(opts, :parallel_shots?, true) and
      Keyword.get(opts, :store) == nil and
      length(ready_shots) > 1 and
      max_parallel_shots(opts) > 1 and
      Enum.all?(ready_shots, &(&1.kind != :safety))
  end

  defp max_parallel_shots(opts) do
    case Keyword.get(opts, :max_parallel_shots, 4) do
      value when is_integer(value) and value > 0 -> value
      _invalid -> 1
    end
  end

  defp parallel_shot_crash_error(reason) do
    Error.new(:crash_error, :shot_crash, "parallel shot task exited",
      retryable: true,
      details: %{reason: inspect(reason)}
    )
  end

  defp run_shot(state, %{kind: :safety} = shot, opts) do
    request = safety_request(state, shot)

    case safety_decision(request, opts) do
      {:approved, reason, actor} ->
        record_safety_decision(:approved, opts)

        shot_state =
          state.shot_states
          |> Map.fetch!(shot.id)
          |> Map.merge(%{
            status: :complete,
            attempt: 0,
            output: safety_output("approved", reason, actor),
            completed_at: Twelvgaige.Clock.utc_now()
          })

        state =
          state
          |> RoundState.put_shot(shot_state)
          |> Map.merge(%{
            status: :firing,
            awaiting_safety: drop_awaiting_safety(state.awaiting_safety, shot.id)
          })

        {:ok, state}

      {:rejected, reason, actor} ->
        record_safety_decision(:rejected, opts)

        error =
          Error.new(:policy_error, :safety_rejected, "safety shot #{shot.id} was rejected",
            safety_required: true,
            details: %{shot_id: shot.id, reason: reason, actor: actor}
          )

        shot_state =
          state.shot_states
          |> Map.fetch!(shot.id)
          |> Map.merge(%{
            status: :failed,
            attempt: 0,
            output: safety_output("rejected", reason, actor),
            error: error,
            completed_at: Twelvgaige.Clock.utc_now()
          })

        state =
          state
          |> RoundState.put_shot(shot_state)
          |> Map.merge(%{
            status: rejected_round_status(state),
            completed_at: Twelvgaige.Clock.utc_now(),
            awaiting_safety: drop_awaiting_safety(state.awaiting_safety, shot.id)
          })

        {:snapshot, state |> RoundState.to_snapshot() |> Map.put(:error, error)}

      :await ->
        shot_state =
          state.shot_states
          |> Map.fetch!(shot.id)
          |> Map.merge(%{
            status: :awaiting_safety,
            attempt: 0,
            output: safety_output("awaiting", nil, nil),
            started_at: Twelvgaige.Clock.utc_now()
          })

        state =
          state
          |> RoundState.put_shot(shot_state)
          |> Map.merge(%{
            status: :awaiting_safety,
            awaiting_safety: put_awaiting_safety(state.awaiting_safety, request)
          })

        if safety_scope(state) == :round do
          {:snapshot, RoundState.to_snapshot(state)}
        else
          {:ok, state}
        end
    end
  end

  defp run_shot(state, shot, opts) do
    current = Map.fetch!(state.shot_states, shot.id)
    attempt = current.attempt + 1

    run_attempt(state, shot, current, attempt, opts)
  end

  defp run_attempt(state, shot, current, attempt, opts) do
    result =
      case acquire_shot_permit(state, shot, attempt, opts) do
        {:ok, permit} ->
          try do
            do_run_attempt(state, shot, current, attempt, opts)
          after
            release_shot_permit(permit)
          end

        {:error, %Error{} = error} ->
          handle_attempt_error(state, shot, current, attempt, error)
      end

    continue_attempt_result(result, shot, opts)
  end

  defp do_run_attempt(state, shot, current, attempt, opts) do
    running =
      %{current | status: :running, attempt: attempt, started_at: Twelvgaige.Clock.utc_now()}

    state = RoundState.put_shot(state, running)

    attempt_input =
      Attempt.new(
        round_id: state.id,
        shot_id: shot.id,
        attempt: attempt,
        definition: shot,
        loadout: Loadout.for_shot(shot, opts),
        input: state.input,
        dependency_outputs: dependency_outputs(state, shot)
      )

    with :ok <- record_attempt_started(attempt_input, opts) do
      run_attempt_execution(state, shot, running, attempt, attempt_input, opts)
    end
  end

  defp run_attempt_execution(state, shot, running, attempt, attempt_input, opts) do
    started_mono = monotonic_ms()

    result =
      ShotExecutor.run(
        attempt_input,
        shot_executor_opts(opts, attempt, Map.get(state.policy, :resource_profile))
      )

    record_shot_metrics(shot, result, started_mono, opts)

    case result do
      {:ok, result} ->
        with :ok <- record_attempt_finished(attempt_input, :completed, {:ok, result}, opts) do
          completed = %{
            running
            | status: :complete,
              completed_at: Twelvgaige.Clock.utc_now(),
              output: %{
                "content" => result.content,
                "structured" => result.output,
                "tool_calls" => result.tool_calls,
                "usage" => result.usage
              }
          }

          {:ok, RoundState.put_shot(state, completed)}
        end

      {:error, error} ->
        with :ok <- record_attempt_finished(attempt_input, :failed, {:error, error}, opts) do
          handle_attempt_error(state, shot, running, attempt, error)
        end
    end
  end

  defp handle_attempt_error(state, shot, running, attempt, error) do
    running = %{running | status: :running, attempt: attempt}

    if RetryPolicy.retry?(shot.retry, error, attempt) do
      retrying =
        %{
          running
          | status: :retrying,
            error: error,
            next_retry_at: RetryPolicy.next_retry_at(shot.retry, attempt),
            history: retry_history(running, error)
        }

      {:retry, RoundState.put_shot(state, retrying), retrying, attempt + 1}
    else
      failed =
        %{
          running
          | status: :failed,
            error: error,
            completed_at: Twelvgaige.Clock.utc_now(),
            history: retry_history(running, error)
        }

      {:ok, RoundState.put_shot(state, failed)}
    end
  end

  defp continue_attempt_result({:retry, state, retrying, next_attempt}, shot, opts) do
    maybe_sleep_before_retry(shot.retry, retrying.attempt, opts)
    run_attempt(state, shot, retrying, next_attempt, opts)
  end

  defp continue_attempt_result(result, _shot, _opts), do: result

  defp acquire_shot_permit(state, shot, attempt, opts) do
    limiter = Keyword.get(opts, :limiter, ResourceLimiter)

    if limiter_available?(limiter) do
      context = shot_resource_context(state, shot, attempt, opts)

      acquire_shot_permit(limiter, context)
    else
      {:ok, nil}
    end
  end

  defp acquire_shot_permit(limiter, context) do
    case ResourceLimiter.acquire(:active_shot, context,
           server: limiter,
           owner_pid: self(),
           queue?: true
         ) do
      {:ok, permit} ->
        {:ok, permit}

      {:queued, waiter} ->
        wait_for_shot_permit(limiter, context, waiter)

      {:error, {:limit_exceeded, _limit} = reason} ->
        {:error, resource_admission_error(reason, context)}

      {:error, reason} ->
        {:error, resource_admission_error(reason, context)}
    end
  end

  defp wait_for_shot_permit(limiter, context, %ResourceLimiter.Waiter{} = waiter) do
    receive do
      {:resource_available, waiter_id, resource_kind}
      when waiter_id == waiter.id and resource_kind == waiter.resource_kind ->
        acquire_shot_permit(limiter, context)

      {:resource_timeout, waiter_id, resource_kind}
      when waiter_id == waiter.id and resource_kind == waiter.resource_kind ->
        {:error, resource_queue_timeout_error(context)}
    end
  end

  defp release_shot_permit(nil), do: :ok

  defp release_shot_permit(%ResourceLimiter.Permit{} = permit) do
    case ResourceLimiter.release(permit) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp limiter_available?(nil), do: false
  defp limiter_available?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp limiter_available?(name) when is_atom(name), do: Process.whereis(name) != nil

  defp shot_resource_context(state, shot, attempt, opts) do
    context = %{
      round_id: state.id,
      shot_id: shot.id,
      attempt: attempt
    }

    case queue_timeout_ms(state, opts) do
      nil -> context
      timeout_ms -> Map.put(context, :queue_timeout_ms, timeout_ms)
    end
  end

  defp queue_timeout_ms(state, opts) do
    Keyword.get(opts, :queue_timeout_ms) || Map.get(state.policy || %{}, :queue_timeout_ms)
  end

  defp resource_admission_error({:limit_exceeded, _limit} = reason, context) do
    Error.new(:timeout_error, :resource_queue_timeout, "shot resource limit exceeded",
      retryable: true,
      details: Map.merge(context, %{reason: inspect(reason)})
    )
  end

  defp resource_admission_error(reason, context) do
    Error.new(:internal_error, :policy_denied, "shot resource admission failed",
      details: Map.merge(context, %{reason: inspect(reason)})
    )
  end

  defp resource_queue_timeout_error(context) do
    Error.new(:timeout_error, :resource_queue_timeout, "shot resource queue timed out",
      retryable: true,
      details: context
    )
  end

  defp record_attempt_started(%Attempt{} = attempt, opts) do
    case Keyword.get(opts, :store) do
      nil ->
        :ok

      store ->
        journal = AttemptJournal.new(attempt)

        case store.record_attempt_started(journal, [AttemptJournal.audit_event(journal)]) do
          status when status in [:ok, :already_recorded] ->
            :ok

          {:error, reason} ->
            {:error,
             Error.new(:store_error, :store_unavailable, "failed to record shot attempt start",
               retryable: true,
               details: %{
                 round_id: attempt.round_id,
                 shot_id: attempt.shot_id,
                 attempt: attempt.attempt,
                 reason: inspect(reason)
               }
             )}
        end
    end
  rescue
    error ->
      {:error,
       Error.new(:store_error, :store_unavailable, "failed to record shot attempt start",
         retryable: true,
         details: %{
           round_id: attempt.round_id,
           shot_id: attempt.shot_id,
           attempt: attempt.attempt,
           reason: Exception.message(error)
         }
       )}
  end

  defp record_attempt_finished(%Attempt{} = attempt, status, outcome, opts) do
    case Keyword.get(opts, :store) do
      nil ->
        :ok

      store ->
        journal = AttemptJournal.finish(attempt, status, outcome)

        case store.record_attempt_finished(journal, [AttemptJournal.audit_event(journal)]) do
          status when status in [:ok, :already_recorded] ->
            :ok

          {:error, reason} ->
            {:error,
             Error.new(:store_error, :store_unavailable, "failed to record shot attempt result",
               retryable: true,
               details: %{
                 round_id: attempt.round_id,
                 shot_id: attempt.shot_id,
                 attempt: attempt.attempt,
                 reason: inspect(reason)
               }
             )}
        end
    end
  rescue
    error ->
      {:error,
       Error.new(:store_error, :store_unavailable, "failed to record shot attempt result",
         retryable: true,
         details: %{
           round_id: attempt.round_id,
           shot_id: attempt.shot_id,
           attempt: attempt.attempt,
           reason: Exception.message(error)
         }
       )}
  end

  defp complete_round(state) do
    state =
      %{state | status: :complete, completed_at: Twelvgaige.Clock.utc_now()}

    {:ok, RoundState.to_snapshot(state)}
  end

  defp fail_round(state, class, reason, message) do
    fail_round(state, Error.new(class, reason, message))
  end

  defp fail_round(state, %Error{} = error) do
    snapshot =
      state
      |> Map.merge(%{status: :failed, completed_at: Twelvgaige.Clock.utc_now()})
      |> RoundState.to_snapshot()
      |> Map.put(:error, error)

    {:ok, snapshot}
  end

  defp shot_state_from_shell(shot) do
    Shot.State.new(
      id: shot.id,
      kind: shot.kind,
      depends_on: shot.depends_on,
      condition: shot.condition
    )
  end

  defp dependency_outputs(state, shot) do
    Map.new(shot.depends_on, fn dependency ->
      shot_state = Map.fetch!(state.shot_states, dependency)
      {dependency, shot_state.output}
    end)
  end

  defp failed_shot(state) do
    state.shot_states
    |> Map.values()
    |> Enum.find(&(&1.status == :failed))
  end

  defp awaiting_safety?(state), do: state.awaiting_safety != []

  defp safety_scope(state), do: Map.get(state.policy, :safety_scope, :dependency)

  defp rejected_round_status(state) do
    case Map.get(state.policy, :on_safety_reject, :halt_round) do
      :fail_round -> :failed
      _halt_round -> :halted
    end
  end

  defp safety_request(state, shot) do
    %{
      "round_id" => state.id,
      "shot_id" => shot.id,
      "status" => "awaiting",
      "scope" => Atom.to_string(safety_scope(state)),
      "reason" => shot.description,
      "requested_at" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }
  end

  defp safety_decision(request, opts) do
    cond do
      Keyword.get(opts, :approve_all_safety?, false) ->
        {:approved, "approved by foreground option", "system"}

      decisions = Keyword.get(opts, :safety_decisions) ->
        decisions
        |> lookup_safety_decision(request["shot_id"])
        |> normalize_safety_decision()

      handler = Keyword.get(opts, :safety_handler) ->
        handler
        |> call_safety_handler(request)
        |> normalize_safety_decision()

      true ->
        :await
    end
  end

  defp lookup_safety_decision(decisions, shot_id) when is_map(decisions) do
    Enum.find_value(decisions, fn {key, value} ->
      if to_string(key) == shot_id, do: value
    end)
  end

  defp lookup_safety_decision(decisions, shot_id) when is_list(decisions) do
    Enum.find_value(decisions, fn
      {key, value} when is_atom(key) or is_binary(key) ->
        if to_string(key) == shot_id, do: value

      _other ->
        nil
    end)
  end

  defp lookup_safety_decision(_decisions, _shot_id), do: nil

  defp call_safety_handler(handler, request) when is_function(handler, 1), do: handler.(request)

  defp call_safety_handler(handler, request) when is_function(handler, 2),
    do: handler.(request["shot_id"], request)

  defp call_safety_handler(_handler, _request), do: nil

  defp normalize_safety_decision(value)
       when value in [:approve, :approved, "approve", "approved"] do
    {:approved, nil, "system"}
  end

  defp normalize_safety_decision(value)
       when value in [:reject, :rejected, "reject", "rejected"] do
    {:rejected, nil, "system"}
  end

  defp normalize_safety_decision({decision, reason}) when decision in [:approve, :approved] do
    {:approved, reason, "system"}
  end

  defp normalize_safety_decision({decision, reason}) when decision in [:reject, :rejected] do
    {:rejected, reason, "system"}
  end

  defp normalize_safety_decision(%{} = decision) do
    normalized =
      decision
      |> Enum.map(fn {key, value} -> {to_string(key), value} end)
      |> Map.new()

    case normalize_safety_decision(Map.get(normalized, "decision")) do
      {:approved, _reason, _actor} ->
        {:approved, Map.get(normalized, "reason"), Map.get(normalized, "actor", "system")}

      {:rejected, _reason, _actor} ->
        {:rejected, Map.get(normalized, "reason"), Map.get(normalized, "actor", "system")}

      :await ->
        :await
    end
  end

  defp normalize_safety_decision(_value), do: :await

  defp safety_output(decision, reason, actor) do
    %{
      "decision" => decision,
      "reason" => reason,
      "actor" => actor,
      "decided_at" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }
  end

  defp awaiting_safety_request(%Snapshot{status: :awaiting_safety} = snapshot, shot_id) do
    case Enum.find(snapshot.awaiting_safety, &(Map.get(&1, "shot_id") == shot_id)) do
      nil ->
        {:error,
         Error.new(:policy_error, :policy_denied, "safety shot is not awaiting approval",
           details: %{round_id: snapshot.id, shot_id: shot_id}
         )}

      request ->
        {:ok, request}
    end
  end

  defp awaiting_safety_request(%Snapshot{} = snapshot, shot_id) do
    {:error,
     Error.new(:policy_error, :policy_denied, "round is not awaiting safety approval",
       details: %{round_id: snapshot.id, shot_id: shot_id, status: snapshot.status}
     )}
  end

  defp resumable_state(snapshot, compiled) do
    {:ok, RoundState.from_snapshot(snapshot, pattern: compiled)}
  rescue
    error ->
      {:error,
       Error.new(:internal_error, :shot_crash, "failed to rebuild round state",
         details: %{reason: Exception.message(error)}
       )}
  end

  defp apply_external_safety_decision(state, request, decision, opts) do
    shot_id = request["shot_id"]

    case Map.fetch(state.shot_states, shot_id) do
      {:ok, %{kind: :safety} = shot_state} ->
        apply_external_safety_decision(state, shot_state, request, decision, opts)

      {:ok, _shot_state} ->
        {:error,
         Error.new(:policy_error, :policy_denied, "target shot is not a safety shot",
           details: %{round_id: state.id, shot_id: shot_id}
         )}

      :error ->
        {:error,
         Error.new(:policy_error, :policy_denied, "unknown safety shot",
           details: %{round_id: state.id, shot_id: shot_id}
         )}
    end
  end

  defp apply_external_safety_decision(state, shot_state, request, :approved, opts) do
    record_safety_decision(:approved, opts)

    reason = Keyword.get(opts, :reason)
    actor = Keyword.get(opts, :actor, "human")

    shot_state =
      %{
        shot_state
        | status: :complete,
          output: safety_output("approved", reason, actor),
          completed_at: Twelvgaige.Clock.utc_now()
      }

    state =
      state
      |> RoundState.put_shot(shot_state)
      |> Map.merge(%{
        status: :firing,
        awaiting_safety: drop_awaiting_safety(state.awaiting_safety, request["shot_id"])
      })

    {:ok, state}
  end

  defp apply_external_safety_decision(state, shot_state, request, :rejected, opts) do
    record_safety_decision(:rejected, opts)

    reason = Keyword.get(opts, :reason)
    actor = Keyword.get(opts, :actor, "human")

    error =
      Error.new(:policy_error, :safety_rejected, "safety shot #{request["shot_id"]} was rejected",
        safety_required: true,
        details: %{shot_id: request["shot_id"], reason: reason, actor: actor}
      )

    shot_state =
      %{
        shot_state
        | status: :failed,
          output: safety_output("rejected", reason, actor),
          error: error,
          completed_at: Twelvgaige.Clock.utc_now()
      }

    snapshot =
      state
      |> RoundState.put_shot(shot_state)
      |> Map.merge(%{
        status: rejected_round_status(state),
        completed_at: Twelvgaige.Clock.utc_now(),
        awaiting_safety: drop_awaiting_safety(state.awaiting_safety, request["shot_id"])
      })
      |> RoundState.to_snapshot()
      |> Map.put(:error, error)

    {:ok, snapshot}
  end

  defp put_awaiting_safety(awaiting, request) do
    awaiting
    |> drop_awaiting_safety(request["shot_id"])
    |> Kernel.++([request])
  end

  defp drop_awaiting_safety(awaiting, shot_id) do
    Enum.reject(awaiting, &(Map.get(&1, "shot_id") == shot_id))
  end

  defp shot_executor_opts(opts, attempt, profile) do
    opts =
      profile
      |> RuntimeProfile.shot_opts(opts)

    case Keyword.get(opts, :attempt_responses) do
      responses when is_list(responses) ->
        opts
        |> Keyword.delete(:response)
        |> Keyword.delete(:responses)
        |> Keyword.put(:response, Enum.at(responses, attempt - 1, ""))

      _other ->
        opts
    end
  end

  defp record_round_metrics({:ok, %Snapshot{} = snapshot}, workflow_id, started_mono, opts) do
    labels = %{workflow_id: workflow_id, status: snapshot.status}

    Metrics.counter("twelvgaige_rounds_total", labels, 1, metrics_opts(opts))

    Metrics.observe(
      "twelvgaige_round_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics_opts(opts)
    )
  end

  defp record_round_metrics({:error, %Error{} = error}, workflow_id, started_mono, opts) do
    labels = %{workflow_id: workflow_id, status: :failed, error_class: error.class}

    Metrics.counter("twelvgaige_rounds_total", labels, 1, metrics_opts(opts))

    Metrics.observe(
      "twelvgaige_round_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics_opts(opts)
    )
  end

  defp record_round_metrics(_result, _workflow_id, _started_mono, _opts), do: :ok

  defp record_shot_metrics(shot, result, started_mono, opts) do
    labels =
      %{
        kind: Map.get(shot, :kind, :slug),
        status: shot_status(result)
      }
      |> maybe_error_class(result)

    Metrics.counter("twelvgaige_shot_attempts_total", labels, 1, metrics_opts(opts))

    Metrics.observe(
      "twelvgaige_shot_duration_seconds",
      duration_seconds(started_mono),
      labels,
      metrics_opts(opts)
    )
  end

  defp maybe_error_class(labels, {:error, %Error{} = error}),
    do: Map.put(labels, :error_class, error.class)

  defp maybe_error_class(labels, _result), do: labels

  defp shot_status({:ok, _result}), do: :complete
  defp shot_status({:error, _error}), do: :failed

  defp record_safety_decision(decision, opts) do
    Metrics.counter(
      "twelvgaige_safety_decisions_total",
      %{decision: decision},
      1,
      metrics_opts(opts)
    )
  end

  defp metrics_opts(opts), do: [metrics: Keyword.get(opts, :metrics, Metrics)]

  defp duration_seconds(started_mono), do: max(monotonic_ms() - started_mono, 0) / 1000

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp maybe_sleep_before_retry(retry, attempt, opts) do
    delay_ms = RetryPolicy.next_delay_ms(retry, attempt)

    if delay_ms > 0 and Keyword.get(opts, :retry_sleep?, true) do
      Process.sleep(delay_ms)
    end

    :ok
  end

  defp retry_history(shot_state, error) do
    entry = %{
      attempt: shot_state.attempt,
      status: "failed",
      error: Error.to_map(error),
      at: DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }

    shot_state.history ++ [entry]
  end

  defp compiler_opts(opts) do
    Keyword.take(opts, [
      :agents,
      :agent_ids,
      :known_tools,
      :tool_catalog,
      :validate_tools?,
      :allow_unsafe_tools_without_safety?
    ])
  end
end
