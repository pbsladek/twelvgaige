defmodule Twelvgaige.Error do
  @moduledoc """
  Structured error used across Twelvgaige subsystems.

  The taxonomy is intentionally closed over the classes and reasons defined in
  `docs/design/spec.md`. Callers decide retry and safety behavior explicitly per error.
  """

  @classes [
    :compile_error,
    :input_error,
    :condition_error,
    :llm_error,
    :output_error,
    :tool_error,
    :policy_error,
    :timeout_error,
    :crash_error,
    :store_error,
    :internal_error
  ]

  @reasons [
    :invalid_shell,
    :cycle_detected,
    :missing_dependency,
    :unsupported_schema_keyword,
    :definition_not_found,
    :unknown_agent,
    :unknown_tool,
    :missing_safety_dependency,
    :yaml_parser_unavailable,
    :condition_missing_path,
    :unsupported_condition,
    :llm_timeout,
    :llm_rate_limited,
    :llm_quota_exhausted,
    :llm_auth_failed,
    :llm_bad_request,
    :llm_provider_unavailable,
    :llm_context_too_large,
    :llm_incomplete,
    :llm_unknown,
    :input_schema_violation,
    :output_parse_error,
    :output_schema_violation,
    :tool_denied,
    :tool_input_invalid,
    :tool_timeout,
    :tool_retryable,
    :tool_non_retryable,
    :network_policy_denied,
    :http_redirect_denied,
    :http_request_too_large,
    :http_response_too_large,
    :kubernetes_resource_denied,
    :kubernetes_context_denied,
    :kubernetes_cluster_scope_denied,
    :safety_rejected,
    :safety_timeout,
    :daemon_auth_failed,
    :daemon_version_mismatch,
    :policy_denied,
    :round_timeout,
    :shot_timeout,
    :client_timeout,
    :session_cancel_request_failed,
    :session_saved_plan_invalid,
    :session_saved_plan_drift,
    :session_saved_plan_write_failed,
    :operation_not_found,
    :resource_queue_timeout,
    :output_too_large,
    :shot_crash,
    :store_unavailable
  ]

  @type class ::
          :compile_error
          | :input_error
          | :condition_error
          | :llm_error
          | :output_error
          | :tool_error
          | :policy_error
          | :timeout_error
          | :crash_error
          | :store_error
          | :internal_error

  @type reason ::
          :invalid_shell
          | :cycle_detected
          | :missing_dependency
          | :unsupported_schema_keyword
          | :definition_not_found
          | :unknown_agent
          | :unknown_tool
          | :missing_safety_dependency
          | :yaml_parser_unavailable
          | :condition_missing_path
          | :unsupported_condition
          | :llm_timeout
          | :llm_rate_limited
          | :llm_quota_exhausted
          | :llm_auth_failed
          | :llm_bad_request
          | :llm_provider_unavailable
          | :llm_context_too_large
          | :llm_incomplete
          | :llm_unknown
          | :input_schema_violation
          | :output_parse_error
          | :output_schema_violation
          | :tool_denied
          | :tool_input_invalid
          | :tool_timeout
          | :tool_retryable
          | :tool_non_retryable
          | :network_policy_denied
          | :http_redirect_denied
          | :http_request_too_large
          | :http_response_too_large
          | :kubernetes_resource_denied
          | :kubernetes_context_denied
          | :kubernetes_cluster_scope_denied
          | :safety_rejected
          | :safety_timeout
          | :daemon_auth_failed
          | :daemon_version_mismatch
          | :policy_denied
          | :round_timeout
          | :shot_timeout
          | :client_timeout
          | :session_cancel_request_failed
          | :session_saved_plan_invalid
          | :session_saved_plan_drift
          | :session_saved_plan_write_failed
          | :operation_not_found
          | :resource_queue_timeout
          | :output_too_large
          | :shot_crash
          | :store_unavailable

  @type t :: %__MODULE__{
          class: class(),
          reason: reason(),
          message: String.t(),
          retryable: boolean(),
          safety_required: boolean(),
          details: map()
        }

  @enforce_keys [:class, :reason, :message]
  defstruct [
    :class,
    :reason,
    :message,
    retryable: false,
    safety_required: false,
    details: %{}
  ]

  @doc "Returns the known error classes."
  @spec classes() :: [class()]
  def classes, do: @classes

  @doc "Returns the known error reasons."
  @spec reasons() :: [reason()]
  def reasons, do: @reasons

  @doc "Builds a validated Twelvgaige error."
  @spec new(class(), reason(), String.t(), keyword()) :: t()
  def new(class, reason, message, opts \\ []) when is_binary(message) do
    validate_class!(class)
    validate_reason!(reason)

    %__MODULE__{
      class: class,
      reason: reason,
      message: message,
      retryable: Keyword.get(opts, :retryable, false),
      safety_required: Keyword.get(opts, :safety_required, false),
      details: Keyword.get(opts, :details, %{})
    }
  end

  @doc "Returns true when `class` is in the spec taxonomy."
  @spec valid_class?(atom()) :: boolean()
  def valid_class?(class), do: class in @classes

  @doc "Returns true when `reason` is in the spec taxonomy."
  @spec valid_reason?(atom()) :: boolean()
  def valid_reason?(reason), do: reason in @reasons

  @doc "Returns true when the error may be retried by policy."
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{retryable: retryable}), do: retryable

  @doc "Returns true when the error requires safety or manual approval."
  @spec safety_required?(t()) :: boolean()
  def safety_required?(%__MODULE__{safety_required: safety_required}), do: safety_required

  @doc "Converts an error to the stable JSON-safe map shape."
  @spec to_map(t() | map() | nil) :: map() | nil
  def to_map(nil), do: nil

  def to_map(%__MODULE__{} = error) do
    %{
      class: Atom.to_string(error.class),
      reason: Atom.to_string(error.reason),
      message: error.message,
      retryable: error.retryable,
      safety_required: error.safety_required,
      details: error.details || %{}
    }
  end

  def to_map(error) when is_map(error) do
    %{
      class: error |> value(:class) |> stringify(),
      reason: error |> value(:reason) |> stringify(),
      message: value(error, :message),
      retryable: value(error, :retryable, false),
      safety_required: value(error, :safety_required, false),
      details: value(error, :details, %{})
    }
  end

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp stringify(nil), do: nil
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp validate_class!(class) do
    unless valid_class?(class) do
      raise ArgumentError, "unknown Twelvgaige error class: #{inspect(class)}"
    end
  end

  defp validate_reason!(reason) do
    unless valid_reason?(reason) do
      raise ArgumentError, "unknown Twelvgaige error reason: #{inspect(reason)}"
    end
  end
end
