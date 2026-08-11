defmodule Twelvgaige.CLI.Commands.SessionPlan do
  @moduledoc false

  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}
  alias Twelvgaige.CLI.Commands.SessionStart
  alias Twelvgaige.Manager.SavedPlan
  alias Twelvgaige.Manager.SessionStart, as: ManagerSessionStart

  def run(args, deps \\ []) do
    with {:ok, session_args, plan_opts} <- parse_plan_opts(args),
         {:ok, opts} <- SessionStart.resolve(session_args, deps),
         request = SessionStart.request(opts),
         {:ok, result} <- planner(deps).(request, Keyword.get(deps, :manager_opts, [])),
         {:ok, saved_plan} <- SavedPlan.build(request, result),
         {:ok, result} <- finalize(result, saved_plan, plan_opts) do
      {:ok, format(redact_objective(result), opts[:format]), 0}
    else
      {:error, reason} -> error(reason, args)
    end
  end

  defp planner(deps), do: Keyword.get(deps, :plan_fun, &ManagerSessionStart.plan/2)

  defp parse_plan_opts(args), do: parse_plan_opts(args, [], nil)

  defp parse_plan_opts([], session_args, output),
    do: {:ok, Enum.reverse(session_args), %{output: output}}

  defp parse_plan_opts(["--output", path | rest], session_args, nil),
    do: parse_plan_opts(rest, session_args, path)

  defp parse_plan_opts(["--output", _path | _rest], _session_args, _output),
    do: {:error, plan_write_error(:session_saved_plan_output_duplicate)}

  defp parse_plan_opts([arg | rest], session_args, output),
    do: parse_plan_opts(rest, [arg | session_args], output)

  defp finalize(result, saved_plan, %{output: nil}) do
    {:ok,
     result
     |> Map.put(:plan_digest, saved_plan["plan_digest"])
     |> Map.put(:saved_plan_path, nil)
     |> Map.put(:start_command, nil)}
  end

  defp finalize(result, saved_plan, %{output: output}) do
    path = Path.expand(output)

    case SavedPlan.save(path, saved_plan) do
      :ok ->
        {:ok,
         result
         |> Map.put(:plan_digest, saved_plan["plan_digest"])
         |> Map.put(:saved_plan_path, path)
         |> Map.put(:start_command, "twelvgaige session start --plan #{shell_quote(path)}")}

      {:error, reason} ->
        {:error, plan_write_error(reason)}
    end
  end

  defp redact_objective(result) do
    result
    |> Map.delete(:objective)
    |> Map.delete("objective")
  end

  defp format(result, :json), do: CommandHelpers.encode_line(result)

  defp format(result, :human) do
    repository_state = value(result, :repository_state, %{})
    dirtiness = value(repository_state, :dirtiness, %{})

    """
    Session plan (no state changed in session inventory or repository)
    Request: #{value(result, :request_id)}
    Plan digest: #{value(result, :plan_digest)}
    Plan: #{value(result, :plan_id)}
    Planned session: #{value(result, :session_id)}
    Runtime: #{value(result, :runtime)}
    Profile: #{value(result, :profile) || "none"}
    Repository: #{value(result, :repository)}@#{value(result, :base_commit)}
    Source: #{value(result, :source_mode, "committed")} (staged=#{value(dirtiness, :staged, 0)}, unstaged=#{value(dirtiness, :unstaged, 0)}, untracked=#{value(dirtiness, :untracked, 0)}, ignored=#{value(dirtiness, :ignored, 0)})
    Source token: #{value(result, :source_state_token, "unavailable")}
    Sandbox: #{value(result, :sandbox_profile)}
    Network: #{value(result, :network)}
    Configuration: #{CommandHelpers.format_provenance(value(result, :configuration_provenance, %{}))}
    Write: #{value(result, :write)}
    Paths: #{Enum.join(value(result, :allowed_paths, []), ", ")}
    Approval: #{value(result, :approval_status)}
    Deadline: #{value(result, :deadline)}
    Saved plan: #{value(result, :saved_plan_path) || "not written; add --output <plan-path> for an exact handoff"}
    Start: #{value(result, :start_command) || "save the plan with --output before starting"}
    """
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp plan_write_error(reason) do
    cause =
      case reason do
        atom when is_atom(atom) -> Atom.to_string(atom)
        {atom, _details} when is_atom(atom) -> Atom.to_string(atom)
        _reason -> "unknown"
      end

    message =
      case reason do
        :session_saved_plan_output_duplicate -> "saved session plan output was specified twice"
        :session_saved_plan_destination_exists -> "saved session plan destination already exists"
        _reason -> "saved session plan could not be written"
      end

    Twelvgaige.Error.new(:input_error, :session_saved_plan_write_failed, message,
      details: %{cause: cause}
    )
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp error(reason, args) do
    format = if("json" in args, do: :json, else: :human)
    {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
  end
end
