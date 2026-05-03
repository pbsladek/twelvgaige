defmodule Twelvgaige.Shot.RetryPolicy do
  @moduledoc """
  Pure retry decision logic for shot attempts.

  The round runner owns whether another attempt starts. This module only
  answers whether a classified error is retryable under a shot's configured
  retry policy, and what delay should apply before the next attempt.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Workflow.Retry

  @never_retry_reasons MapSet.new([
                         :policy_denied,
                         :tool_denied,
                         :safety_rejected,
                         :safety_timeout
                       ])

  @spec retry?(Retry.t(), Error.t(), pos_integer()) :: boolean()
  def retry?(%Retry{} = retry, %Error{} = error, attempt) when is_integer(attempt) do
    attempt < retry.max_attempts and
      not MapSet.member?(@never_retry_reasons, error.reason) and
      not error.safety_required and
      retryable_reason?(retry, error)
  end

  @spec next_delay_ms(Retry.t(), pos_integer()) :: non_neg_integer()
  def next_delay_ms(%Retry{} = retry, attempt) when is_integer(attempt) and attempt > 0 do
    retry
    |> raw_delay(attempt)
    |> min(retry.max_delay_ms)
    |> round()
  end

  @spec next_retry_at(Retry.t(), pos_integer(), DateTime.t()) :: DateTime.t()
  def next_retry_at(%Retry{} = retry, attempt, %DateTime{} = now \\ Twelvgaige.Clock.utc_now()) do
    DateTime.add(now, next_delay_ms(retry, attempt), :millisecond)
  end

  defp retryable_reason?(%Retry{retryable_errors: []}, %Error{} = error) do
    Error.retryable?(error)
  end

  defp retryable_reason?(%Retry{retryable_errors: retryable_errors}, %Error{} = error) do
    error.reason in retryable_errors
  end

  defp raw_delay(%Retry{backoff: :fixed, base_delay_ms: base}, _attempt), do: base

  defp raw_delay(%Retry{backoff: :linear, base_delay_ms: base}, attempt) do
    base * attempt
  end

  defp raw_delay(%Retry{backoff: :exponential, base_delay_ms: base}, attempt) do
    base * Integer.pow(2, attempt - 1)
  end
end
