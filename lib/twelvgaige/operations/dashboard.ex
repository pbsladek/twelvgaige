defmodule Twelvgaige.Operations.Dashboard do
  @moduledoc "Single-user cost, token, rate, queue, sandbox, and nested-agent dashboard."

  alias Twelvgaige.Operations.{ProviderLimiter, SessionControl}

  def snapshot(opts \\ []) do
    with {:ok, sessions} <- SessionControl.list(session_options(opts)),
         {:ok, health} <- SessionControl.backend_health(session_options(opts)) do
      rate = provider_status(opts)
      automation = scheduler_status(opts)
      manager = manager_status(opts)

      %{
        generated_at: Keyword.get(opts, :now, DateTime.utc_now()),
        cost: sum_usage(sessions, [:cost_micros, :estimated_cost_micros]),
        tokens: %{
          input: sum_usage(sessions, [:input_tokens]),
          output: sum_usage(sessions, [:output_tokens]),
          total: sum_usage(sessions, [:total_tokens, :tokens])
        },
        rates: rate,
        queues: queue_view(sessions, manager),
        sandboxes: %{health: health, active: Enum.count(sessions, &active_sandbox?/1)},
        nested_agents: %{
          total: Enum.sum(Enum.map(sessions, &length(&1.nested_agents || []))),
          by_session:
            sessions
            |> Enum.filter(&((&1.nested_agents || []) != []))
            |> Map.new(&{&1.id, length(&1.nested_agents)})
        },
        sessions: session_summary(sessions),
        audit_checkpoint: audit_checkpoint_status(opts),
        automation: automation,
        manager: manager
      }
    end
  end

  defp provider_status(opts) do
    case Keyword.get(opts, :provider_limiter) do
      nil -> %{status: :not_configured, providers: []}
      server -> Map.put(ProviderLimiter.status(server: server), :status, :available)
    end
  end

  defp scheduler_status(opts) do
    case Keyword.get(opts, :scheduler) do
      nil -> %{status: :not_configured, jobs: []}
      server -> Twelvgaige.Scheduler.status(server)
    end
  catch
    :exit, _reason -> %{status: :unavailable, jobs: []}
  end

  defp manager_status(opts) do
    case Keyword.get(opts, :manager_store) do
      nil ->
        %{status: :not_configured, plans: []}

      {module, server} ->
        case module.list_plans(server: server) do
          {:ok, plans} -> %{status: :available, plans: Enum.map(plans, &plan_view/1)}
          {:error, reason} -> %{status: :unavailable, reason: reason, plans: []}
        end
    end
  end

  defp audit_checkpoint_status(opts) do
    case Keyword.get(opts, :audit_anchor) do
      nil -> %{status: :not_configured}
      server -> Twelvgaige.Operations.AuditAnchor.status(server: server)
    end
  catch
    :exit, reason -> %{status: :unavailable, reason: inspect(reason)}
  end

  defp queue_view(sessions, manager) do
    manager_plans = Map.get(manager, :plans, [])

    %{
      delegated_sessions: Enum.count(sessions, &(&1.status in [:preparing, :starting])),
      manager_children:
        Enum.sum(Enum.map(manager_plans, &(Map.get(&1, :queued_children, 0) || 0)))
    }
  end

  defp session_summary(sessions) do
    %{
      total: length(sessions),
      by_status: Enum.frequencies_by(sessions, & &1.status),
      active: Enum.count(sessions, &(&1.status in [:preparing, :starting, :running, :cancelling]))
    }
  end

  defp sum_usage(sessions, keys) do
    Enum.sum(
      Enum.map(sessions, fn session ->
        Enum.find_value(keys, 0, fn key -> Map.get(session.usage || %{}, key) end) || 0
      end)
    )
  end

  defp active_sandbox?(session),
    do: is_binary(session.sandbox_resource_id) and session.status not in [:finalized, :revoked]

  defp plan_view(plan) do
    %{
      id: plan.id,
      status: plan.status,
      queued_children: Map.get(plan, :queued_children, 0),
      allocated_budget: Map.get(plan, :allocated_budget),
      used_budget: Map.get(plan, :used_budget)
    }
  end

  defp session_options(opts) do
    [server: Keyword.get(opts, :session_control, SessionControl)]
    |> maybe_put(:uid, Keyword.get(opts, :uid))
    |> maybe_put(:backend_opts, Keyword.get(opts, :backend_opts))
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
