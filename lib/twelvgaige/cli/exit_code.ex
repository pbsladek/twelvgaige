defmodule Twelvgaige.CLI.ExitCode do
  @moduledoc """
  Deterministic process exit codes for the Twelvgaige CLI.

  The mapping is part of the CLI contract. Keep it closed and boring so shell
  scripts and CI jobs can act on failures without parsing human output.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Round.Snapshot

  @timeout_reasons [
    :llm_timeout,
    :tool_timeout,
    :safety_timeout,
    :shot_timeout,
    :client_timeout,
    :resource_queue_timeout,
    :session_follow_timeout
  ]

  @not_found_reasons [
    :definition_not_found,
    :unknown_agent,
    :unknown_tool,
    :workspace_not_found,
    :workspace_set_not_found,
    :operation_not_found,
    :session_not_found,
    :review_worktree_not_found
  ]

  @input_reasons [
    :workspace_expected_epoch_required,
    :workspace_expected_epoch_invalid,
    :workspace_cleanup_confirmation_required,
    :workspace_apply_confirmation_required,
    :workspace_reconcile_confirmation_required,
    :review_worktree_cleanup_confirmation_required,
    :workspace_export_output_required,
    :session_export_output_required,
    :workspace_apply_target_invalid,
    :session_request_id_invalid,
    :session_saved_plan_invalid,
    :session_saved_plan_drift,
    :session_saved_plan_write_failed,
    :session_task_required,
    :session_auth_profile_required,
    :session_source_mode_invalid,
    :session_network_invalid,
    :include_ignored_requires_include_untracked,
    :source_include_requires_working_tree
  ]

  @policy_reasons [
    :policy_denied,
    :tool_denied,
    :network_policy_denied,
    :http_redirect_denied,
    :kubernetes_resource_denied,
    :kubernetes_context_denied,
    :kubernetes_cluster_scope_denied
  ]

  @daemon_reasons [:daemon_auth_failed, :daemon_version_mismatch]
  @invalid_input_classes [:compile_error, :input_error, :condition_error]
  @internal_classes [:crash_error, :store_error, :internal_error]

  @doc "Returns the CLI exit code for a round snapshot returned by `round run`."
  @spec for_snapshot(Snapshot.t()) :: 0..8
  def for_snapshot(%Snapshot{status: :complete}), do: 0
  def for_snapshot(%Snapshot{status: :halted}), do: 2

  def for_snapshot(%Snapshot{status: :failed, error: %Error{} = error}) do
    case for_error(error) do
      code when code in [2, 3, 7, 8] -> code
      _code -> 1
    end
  end

  def for_snapshot(%Snapshot{}), do: 1

  @doc "Returns the CLI exit code for a command error."
  @spec for_error(term()) :: 1..8
  def for_error(:daemon_unavailable), do: 5
  def for_error(:daemon_required), do: 5
  def for_error(:not_found), do: 6
  def for_error(:invalid_ipc_address), do: 4
  def for_error(:invalid_ipc_request), do: 4
  def for_error(reason) when reason in @not_found_reasons, do: 6
  def for_error(reason) when reason in @input_reasons, do: 4

  def for_error(%Error{reason: :invalid_shell, message: "unable to read shell file"} = error) do
    if shell_file_missing?(error), do: 6, else: 4
  end

  def for_error(%Error{reason: :safety_rejected}), do: 2
  def for_error(%Error{class: :timeout_error}), do: 3
  def for_error(%Error{reason: reason}) when reason in @timeout_reasons, do: 3
  def for_error(%Error{reason: reason}) when reason in @not_found_reasons, do: 6
  def for_error(%Error{reason: reason}) when reason in @daemon_reasons, do: 5
  def for_error(%Error{reason: reason}) when reason in @policy_reasons, do: 7
  def for_error(%Error{class: class}) when class in @invalid_input_classes, do: 4
  def for_error(%Error{class: class}) when class in @internal_classes, do: 8
  def for_error(%Error{}), do: 1
  def for_error(_error), do: 8

  defp shell_file_missing?(%Error{details: details}) do
    value(details, :reason) in [":enoent", "enoent"]
  end

  defp value(%{} = map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
  defp value(_map, _key), do: nil
end
