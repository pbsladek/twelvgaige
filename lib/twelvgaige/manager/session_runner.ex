defmodule Twelvgaige.Manager.SessionRunner do
  @moduledoc "Runs one governed delegated session through its attached outer-sandbox transport."

  alias Twelvgaige.DelegatedSession.Controller
  alias Twelvgaige.Handoff
  alias Twelvgaige.Manager.{Budget, ChildRecord}

  @default_poll_ms 50
  @default_event_limit 256

  @spec run(Twelvgaige.DelegatedSession.t(), ChildRecord.t(), map(), keyword()) ::
          {:ok, map()} | {:error, term()} | {:error, term(), map()}
  def run(session, %ChildRecord{} = child, _descriptor, opts) do
    controller_module = Keyword.get(opts, :controller_module, Controller)

    with {:ok, launch_spec} <- sandbox_spec(session, child, opts),
         controller_opts <- controller_options(session, child, launch_spec, opts),
         {:ok, controller} <- controller_module.start_link(controller_opts) do
      try do
        case controller_module.start(controller) do
          {:ok, _started} -> await(controller_module, controller, session, child, opts, [])
          {:error, reason} -> start_failure(controller_module, controller, reason)
        end
      after
        if Process.alive?(controller), do: GenServer.stop(controller, :normal, :infinity)
      end
    end
  end

  defp controller_options(session, child, launch_spec, opts) do
    [
      session: session,
      adapter:
        Keyword.get(
          opts,
          :adapter,
          Twelvgaige.DelegatedSession.Adapter.CodexAppServer
        ),
      adapter_config: adapter_config(session, child, opts),
      sandbox_manager: Keyword.fetch!(opts, :sandbox_manager),
      sandbox_launch_spec: launch_spec,
      sandbox_opts: Keyword.get(opts, :sandbox_opts, []),
      runtime_command:
        Keyword.get(opts, :runtime_command, [
          "/opt/codex/bin/codex",
          "app-server",
          "--stdio",
          "--strict-config"
        ]),
      result_destination: Keyword.get(opts, :result_destination) || workspace_source(launch_spec),
      session_control: Keyword.get(opts, :session_control)
    ]
    |> Keyword.merge(Keyword.get(opts, :controller_opts, []))
  end

  defp await(controller_module, controller, session, child, opts, events) do
    cond do
      deadline_reached?(session.deadline) ->
        terminate(controller_module, controller, :deadline_exceeded, child, events)

      true ->
        limit = Keyword.get(opts, :event_limit, @default_event_limit)

        case controller_module.poll(controller, limit) do
          {:ok, polled} ->
            events = events ++ polled

            case handle_events(controller_module, controller, polled, opts) do
              :continue ->
                Process.sleep(Keyword.get(opts, :poll_ms, @default_poll_ms))
                await(controller_module, controller, session, child, opts, events)

              :complete ->
                finish_success(controller_module, controller, session, child, events)

              {:error, reason} ->
                terminate(controller_module, controller, reason, child, events)
            end

          {:error, reason} ->
            terminate(
              controller_module,
              controller,
              {:provider_event_poll_failed, reason},
              child,
              events
            )
        end
    end
  end

  defp handle_events(controller_module, controller, events, opts) do
    Enum.reduce_while(events, :continue, fn event, _acc ->
      case event.event_type do
        :approval_required ->
          case decide_approval(controller_module, controller, event, opts) do
            :ok -> {:cont, :continue}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        :session_failed ->
          {:halt, {:error, {:provider_session_failed, event.payload}}}

        :turn_completed ->
          {:halt, :complete}

        _other ->
          {:cont, :continue}
      end
    end)
  end

  defp decide_approval(controller_module, controller, event, opts) do
    case Keyword.get(opts, :approval_fun) do
      approval_fun when is_function(approval_fun, 1) ->
        approval_id = event.payload["approvalId"] || event.payload["itemId"]

        with id when is_binary(id) and id != "" <- approval_id,
             {:ok, receipt} <- approval_fun.(event),
             :ok <- controller_module.decide(controller, id, receipt) do
          :ok
        else
          nil -> {:error, :provider_approval_identity_missing}
          {:error, reason} -> {:error, {:provider_approval_failed, reason}}
        end

      _other ->
        {:error, :provider_approval_requires_explicit_decider}
    end
  end

  defp finish_success(controller_module, controller, session, child, events) do
    case controller_module.finalize(controller) do
      {:ok, finalized} ->
        result = %{
          session: finalized,
          runtime_quiescence: finalized.result.runtime_quiescence,
          handoff:
            Handoff.new(%{
              objective_status: :complete,
              summary: "Delegated Codex turn completed.",
              workspace_id: child.workspace_id,
              base_commit: session.base_commit
            }),
          usage: usage(events)
        }

        {:ok, result}

      {:error, reason, evidence} ->
        {:error, reason, Map.put_new(evidence, :usage, usage(events))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp terminate(controller_module, controller, reason, _child, events) do
    cancel_result = controller_module.cancel(controller, reason)

    case controller_module.finalize(controller) do
      {:ok, finalized} ->
        {:error, reason,
         %{
           session: finalized,
           runtime_quiescence: finalized.result.runtime_quiescence,
           cancellation: cancel_result,
           usage: usage(events)
         }}

      {:error, finalize_reason, evidence} ->
        {:error, {:session_termination_failed, reason, finalize_reason},
         evidence
         |> Map.put(:cancellation, cancel_result)
         |> Map.put_new(:usage, usage(events))}

      {:error, finalize_reason} ->
        {:error, {:session_termination_failed, reason, finalize_reason}}
    end
  end

  defp start_failure(controller_module, controller, reason) do
    evidence =
      case controller_module.snapshot(controller) do
        {:ok, snapshot} ->
          %{session: snapshot.session, sandbox_resource_id: snapshot.sandbox_resource_id}

        _other ->
          %{}
      end

    {:error, reason, Map.put(evidence, :usage, Budget.zero())}
  end

  defp adapter_config(session, child, opts) do
    opts
    |> Keyword.get(:adapter_config, %{})
    |> Map.new()
    |> Map.put_new(:objective, child.task.objective)
    |> Map.put_new(:runtime_version, session.runtime_version)
    |> Map.put_new(:cwd, "/workspace")
    |> Map.put_new(:sandbox, "danger-full-access")
    |> Map.put_new(:sandbox_authority, :outer)
    |> Map.put_new(:external_network_access, external_network(child.task.network_mode))
    |> Map.put_new(:approval_policy, Keyword.get(opts, :approval_policy, "never"))
    |> Map.put_new(:approvals_reviewer, Keyword.get(opts, :approvals_reviewer, "user"))
    |> Map.update(:client_opts, [policy_profile: :outer_authoritative], fn
      client_opts when is_list(client_opts) ->
        Keyword.put_new(client_opts, :policy_profile, :outer_authoritative)

      client_opts when is_map(client_opts) ->
        client_opts |> Map.to_list() |> Keyword.put_new(:policy_profile, :outer_authoritative)
    end)
  end

  defp sandbox_spec(session, child, opts) do
    case Keyword.fetch!(opts, :sandbox_spec_resolver).(session, child) do
      {:ok, spec} when is_map(spec) -> {:ok, spec}
      spec when is_map(spec) -> {:ok, spec}
      {:error, _reason} = error -> error
      _invalid -> {:error, :sandbox_launch_spec_invalid}
    end
  end

  defp workspace_source(%{mounts: mounts}) do
    Enum.find_value(mounts, fn mount ->
      destination = Map.get(mount, :destination, Map.get(mount, "destination"))
      if destination == "/workspace", do: Map.get(mount, :source, Map.get(mount, "source"))
    end)
  end

  defp workspace_source(_spec), do: nil

  defp deadline_reached?(%DateTime{} = deadline),
    do: DateTime.compare(Twelvgaige.Clock.utc_now(), deadline) != :lt

  defp deadline_reached?(_deadline), do: true

  defp external_network(:none), do: "disabled"
  defp external_network(:broker_only), do: "restricted"
  defp external_network(:unrestricted), do: "enabled"
  defp external_network(_other), do: "restricted"

  defp usage(events) do
    tool_calls = Enum.count(events, &(&1.event_type == :tool_started))

    Enum.reduce(events, Budget.zero(), fn
      %{event_type: :usage_updated, payload: payload}, acc -> merge_usage(acc, payload)
      _event, acc -> acc
    end)
    |> Map.put(:tool_calls, tool_calls)
  end

  defp merge_usage(acc, payload) do
    tokens = integer(payload, ["totalTokens", "total_tokens", "tokens"])
    cost = integer(payload, ["costMicros", "cost_micros"])

    acc
    |> Map.put(:tokens, max(acc.tokens, tokens || 0))
    |> Map.put(:cost_micros, max(acc.cost_micros, cost || 0))
  end

  defp integer(map, keys) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_integer(value) and value >= 0 -> value
        _other -> nil
      end
    end)
  end
end
