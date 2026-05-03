defmodule Twelvgaige.Shot.RetryPolicyTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Workflow.Retry
  alias Twelvgaige.Shot.RetryPolicy

  test "retries retryable errors while attempts remain" do
    retry = %Retry{max_attempts: 3}
    error = Error.new(:llm_error, :llm_timeout, "timeout", retryable: true)

    assert RetryPolicy.retry?(retry, error, 1)
    assert RetryPolicy.retry?(retry, error, 2)
    refute RetryPolicy.retry?(retry, error, 3)
  end

  test "never retries policy-denied or tool-denied errors" do
    retry = %Retry{max_attempts: 3, retryable_errors: [:tool_denied, :resource_queue_timeout]}

    policy_error =
      Error.new(:policy_error, :policy_denied, "denied", retryable: true, safety_required: true)

    tool_error = Error.new(:tool_error, :tool_denied, "denied", retryable: true)

    refute RetryPolicy.retry?(retry, policy_error, 1)
    refute RetryPolicy.retry?(retry, tool_error, 1)
  end

  test "uses configured retryable error allowlist when present" do
    retry = %Retry{max_attempts: 2, retryable_errors: [:output_parse_error]}

    parse_error = Error.new(:output_error, :output_parse_error, "bad json", retryable: true)
    llm_error = Error.new(:llm_error, :llm_timeout, "timeout", retryable: true)

    assert RetryPolicy.retry?(retry, parse_error, 1)
    refute RetryPolicy.retry?(retry, llm_error, 1)
  end

  test "calculates fixed, linear, and exponential delays" do
    assert RetryPolicy.next_delay_ms(
             %Retry{backoff: :fixed, base_delay_ms: 5, max_delay_ms: 20},
             3
           ) ==
             5

    assert RetryPolicy.next_delay_ms(
             %Retry{backoff: :linear, base_delay_ms: 5, max_delay_ms: 20},
             3
           ) ==
             15

    assert RetryPolicy.next_delay_ms(
             %Retry{backoff: :exponential, base_delay_ms: 5, max_delay_ms: 20},
             4
           ) == 20
  end

  test "generated retry delays never exceed max delay" do
    for backoff <- [:fixed, :linear, :exponential],
        base <- [0, 1, 5, 100, 1_000],
        max_delay <- [base, base + 1, base * 3 + 7],
        attempt <- 1..16 do
      retry = %Retry{backoff: backoff, base_delay_ms: base, max_delay_ms: max_delay}

      assert RetryPolicy.next_delay_ms(retry, attempt) <= max_delay
    end
  end
end
