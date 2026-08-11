defmodule Twelvgaige.CLI.CommandHelpers do
  @moduledoc false

  @spec global_options() :: map()
  def global_options do
    Process.get(:twelvgaige_cli_global, %{color: :auto, quiet?: false, verbose?: false})
  end

  def quiet?, do: global_options().quiet?
  def verbose?, do: global_options().verbose?
  def color_mode, do: global_options().color

  @spec encode_line(term()) :: String.t()
  def encode_line(payload), do: Jason.encode!(payload) <> "\n"

  @spec format_command_error(term(), :human | :json) :: String.t()
  def format_command_error(%Twelvgaige.Error{} = error, format), do: format_error(error, format)

  def format_command_error(:daemon_unavailable, :json) do
    encode_line(%{
      error: %{
        reason: "daemon_unavailable",
        message: "daemon unavailable",
        remediation: ["twelvgaige daemon serve"]
      }
    })
  end

  def format_command_error(:daemon_unavailable, :human),
    do: "daemon unavailable\nNext: twelvgaige daemon serve\n"

  def format_command_error(:not_found, :json) do
    encode_line(%{error: %{reason: "round_not_found", message: "round not found"}})
  end

  def format_command_error(:not_found, :human), do: "error: round not found\n"

  def format_command_error(error, :json) do
    reason = reason(error)

    encode_line(%{
      error: %{
        reason: Atom.to_string(reason),
        message: message(error),
        remediation: remediation(reason)
      }
    })
  end

  def format_command_error(error, :human) do
    reason = reason(error)
    next = Enum.map_join(remediation(reason), "\n", &"Next: #{&1}")
    suffix = if next == "", do: "", else: "\n" <> next
    "error: #{message(error)}#{suffix}\n"
  end

  @spec format_error(Twelvgaige.Error.t(), :human | :json) :: String.t()
  def format_error(error, :json) do
    payload =
      error
      |> Twelvgaige.Error.to_map()
      |> Map.put(:remediation, error_remediation(error))

    encode_line(%{error: payload})
  end

  def format_error(error, :human) do
    next = Enum.map_join(error_remediation(error), "\n", &"Next: #{&1}")
    suffix = if next == "", do: "", else: "\n" <> next
    "error: #{error.message}#{suffix}\n"
  end

  @spec format_warnings(term()) :: String.t()
  def format_warnings(warnings) do
    warnings
    |> List.wrap()
    |> case do
      [] -> "  none"
      warnings -> Enum.map_join(warnings, "\n", &"  - #{&1}")
    end
  end

  @spec format_provenance(term()) :: String.t()
  def format_provenance(provenance) when is_map(provenance) and map_size(provenance) > 0 do
    provenance
    |> Enum.map(fn {key, source} -> {to_string(key), to_string(source)} end)
    |> Enum.sort()
    |> Enum.map_join(", ", fn {key, source} -> "#{key}=#{source}" end)
  end

  def format_provenance(_provenance), do: "unavailable"

  @spec parse_format(String.t()) :: :human | :json
  def parse_format("json"), do: :json
  def parse_format("human"), do: :human
  def parse_format(_other), do: :human

  @spec parse_human_json_format(String.t()) ::
          {:ok, :human | :json} | {:error, Twelvgaige.Error.t()}
  def parse_human_json_format("human"), do: {:ok, :human}
  def parse_human_json_format("json"), do: {:ok, :json}

  def parse_human_json_format(_format) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "format must be human or json")}
  end

  @spec root_opts(keyword()) :: keyword()
  def root_opts(opts) do
    case Keyword.get(opts, :root) do
      nil -> []
      root -> [root: root]
    end
  end

  @spec parse_non_negative_integer(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> :error
    end
  end

  @spec parse_positive_integer(String.t()) :: {:ok, pos_integer()} | :error
  def parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> :error
    end
  end

  @spec value(term(), atom() | String.t(), term()) :: term()
  def value(map, key, default \\ nil)

  def value(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  def value(_map, _key, default), do: default

  defp reason({reason, _details}) when is_atom(reason), do: reason
  defp reason({reason, _one, _two}) when is_atom(reason), do: reason
  defp reason(reason) when is_atom(reason), do: reason
  defp reason(_error), do: :unknown

  defp message(error), do: inspect(error)

  defp error_remediation(%Twelvgaige.Error{reason: :client_timeout, details: details}) do
    case value(details, :lookup_command) do
      command when is_binary(command) and command != "" -> [command]
      _missing -> ["twelvgaige operation show <request-id>"]
    end
  end

  defp error_remediation(%Twelvgaige.Error{
         reason: :session_cancel_request_failed,
         details: details
       }) do
    case value(details, :lookup_command) do
      command when is_binary(command) and command != "" -> [command]
      _missing -> ["twelvgaige session show <session-id>"]
    end
  end

  defp error_remediation(%Twelvgaige.Error{reason: reason}), do: remediation(reason)

  defp remediation(:workspace_not_found), do: ["twelvgaige workspace list"]
  defp remediation(:session_not_found), do: ["twelvgaige session list"]
  defp remediation(:workspace_set_not_found), do: ["twelvgaige workspace set list"]

  defp remediation(:operation_not_found),
    do: ["retry the original command with the same request ID"]

  defp remediation(:workspace_expected_epoch_required),
    do: ["twelvgaige workspace status <workspace-id>"]

  defp remediation(:workspace_control_epoch_conflict),
    do: ["twelvgaige workspace status <workspace-id>"]

  defp remediation(:workspace_cleanup_confirmation_required),
    do: ["run the cleanup preview, then repeat its exact --expected-epoch with --write --yes"]

  defp remediation(:workspace_apply_confirmation_required),
    do: [
      "run apply without --write first, then repeat its exact --expected-epoch with --write --yes"
    ]

  defp remediation(:workspace_apply_target_drifted_or_dirty),
    do: ["git status --short", "twelvgaige repo inspect"]

  defp remediation(:review_worktree_has_uncaptured_changes),
    do: ["review or export the edits in the managed review worktree before cleanup"]

  defp remediation(:workspace_reconcile_confirmation_required),
    do: ["run workspace reconcile without --write and follow its evidence-preserving commands"]

  defp remediation(:workspace_storage_unavailable),
    do: ["twelvgaige workspace retention status", "twelvgaige workspace list"]

  defp remediation(:committed_source_requires_clean_repository),
    do: ["twelvgaige repo inspect", "select --source staged or --source working-tree explicitly"]

  defp remediation(:include_ignored_requires_include_untracked),
    do: ["add --include-untracked or remove --include-ignored"]

  defp remediation(:source_include_requires_working_tree),
    do: ["add --source working-tree or remove the include flags"]

  defp remediation(:session_saved_plan_invalid),
    do: ["create a new plan with twelvgaige session plan <task-file> --output <plan.json>"]

  defp remediation(:session_saved_plan_drift),
    do: ["inspect the changed field, then create and review a new session plan"]

  defp remediation(:session_saved_plan_write_failed),
    do: ["choose a new owner-writable path that does not already exist"]

  defp remediation(:daemon_auth_failed),
    do: ["twelvgaige daemon paths", "twelvgaige daemon token rotate"]

  defp remediation(_reason), do: []
end
