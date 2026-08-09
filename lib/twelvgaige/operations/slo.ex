defmodule Twelvgaige.Operations.SLO do
  @moduledoc "Versioned local-host SLOs and error-budget evaluation."

  @version 1

  @profiles %{
    podman_macos_arm64: %{
      availability_percent: 99.5,
      launch_success_percent: 99.0,
      launch_p95_ms: 1_000,
      cancellation_p95_ms: 3_000,
      recovery_success_percent: 99.0,
      recovery_p95_ms: 10_000,
      queue_admission_p95_ms: 5_000,
      retention_run_success_percent: 99.0,
      retention_max_lag_seconds: 86_400
    },
    apple_container_macos_arm64: %{
      availability_percent: 99.5,
      launch_success_percent: 99.0,
      launch_p95_ms: 6_000,
      cancellation_p95_ms: 5_000,
      recovery_success_percent: 99.0,
      recovery_p95_ms: 15_000,
      queue_admission_p95_ms: 5_000,
      retention_run_success_percent: 99.0,
      retention_max_lag_seconds: 86_400
    }
  }

  def version, do: @version
  def profiles, do: @profiles
  def profile(name), do: Map.fetch(@profiles, name)

  def evaluate(profile, observations) do
    with {:ok, targets} <- profile(profile) do
      checks = %{
        availability:
          percentage_check(observations, :availability_percent, targets.availability_percent),
        launch_success:
          percentage_check(observations, :launch_success_percent, targets.launch_success_percent),
        launch_latency: maximum_check(observations, :launch_p95_ms, targets.launch_p95_ms),
        cancellation_latency:
          maximum_check(observations, :cancellation_p95_ms, targets.cancellation_p95_ms),
        recovery_success:
          percentage_check(
            observations,
            :recovery_success_percent,
            targets.recovery_success_percent
          ),
        recovery_latency: maximum_check(observations, :recovery_p95_ms, targets.recovery_p95_ms),
        queue_admission:
          maximum_check(observations, :queue_admission_p95_ms, targets.queue_admission_p95_ms),
        retention_success:
          percentage_check(
            observations,
            :retention_run_success_percent,
            targets.retention_run_success_percent
          ),
        retention_lag:
          maximum_check(
            observations,
            :retention_max_lag_seconds,
            targets.retention_max_lag_seconds
          )
      }

      {:ok,
       %{
         version: @version,
         profile: profile,
         status:
           if(Enum.all?(checks, fn {_name, check} -> check.status == :pass end),
             do: :pass,
             else: :fail
           ),
         checks: checks,
         error_budgets: error_budgets(targets, observations)
       }}
    end
  end

  defp percentage_check(observations, key, target) do
    observed = value(observations, key)
    %{target: target, observed: observed, status: present_compare(observed, target, &>=/2)}
  end

  defp maximum_check(observations, key, target) do
    observed = value(observations, key)
    %{target: target, observed: observed, status: present_compare(observed, target, &<=/2)}
  end

  defp present_compare(nil, _target, _fun), do: :missing

  defp present_compare(observed, target, fun),
    do: if(fun.(observed, target), do: :pass, else: :fail)

  defp error_budgets(targets, observations) do
    for key <- [
          :availability_percent,
          :launch_success_percent,
          :recovery_success_percent,
          :retention_run_success_percent
        ],
        into: %{} do
      target = Map.fetch!(targets, key)
      observed = value(observations, key)
      allowed_failure_percent = 100.0 - target

      remaining =
        if is_number(observed),
          do: allowed_failure_percent - (100.0 - observed),
          else: nil

      {key,
       %{
         allowed_failure_percent: allowed_failure_percent,
         remaining_percentage_points: remaining,
         exhausted: is_number(remaining) and remaining < 0
       }}
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
