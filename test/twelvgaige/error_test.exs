defmodule Twelvgaige.ErrorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Error

  test "builds a validated structured error" do
    error =
      Error.new(:tool_error, :tool_denied, "tool is not allowed for this shot",
        retryable: false,
        safety_required: true,
        details: %{tool: "kubectl_delete"}
      )

    assert error.class == :tool_error
    assert error.reason == :tool_denied
    assert error.message == "tool is not allowed for this shot"
    refute Error.retryable?(error)
    assert Error.safety_required?(error)
    assert error.details == %{tool: "kubectl_delete"}
  end

  test "uses safe defaults" do
    error = Error.new(:timeout_error, :shot_timeout, "shot timed out")

    refute error.retryable
    refute error.safety_required
    assert error.details == %{}
  end

  test "converts to the CLI JSON error shape" do
    error =
      Error.new(:llm_error, :llm_rate_limited, "provider rate limited the request",
        retryable: true
      )

    assert Error.to_map(error) == %{
             class: "llm_error",
             reason: "llm_rate_limited",
             message: "provider rate limited the request",
             retryable: true,
             safety_required: false,
             details: %{}
           }

    assert Error.to_map(nil) == nil
  end

  test "rejects classes and reasons outside the spec taxonomy" do
    assert_raise ArgumentError, ~r/unknown Twelvgaige error class/, fn ->
      Error.new(:not_real, :tool_denied, "bad class")
    end

    assert_raise ArgumentError, ~r/unknown Twelvgaige error reason/, fn ->
      Error.new(:tool_error, :not_real, "bad reason")
    end
  end
end
