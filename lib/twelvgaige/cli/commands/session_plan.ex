defmodule Twelvgaige.CLI.Commands.SessionPlan do
  @moduledoc false

  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}
  alias Twelvgaige.CLI.Commands.SessionStart
  alias Twelvgaige.Manager.SessionStart, as: ManagerSessionStart

  def run(args, deps \\ []) do
    with {:ok, opts} <- SessionStart.resolve(args, deps),
         request = SessionStart.request(opts),
         {:ok, result} <- planner(deps).(request, Keyword.get(deps, :manager_opts, [])) do
      {:ok, format(result, opts[:format]), 0}
    else
      {:error, reason} -> error(reason, args)
    end
  end

  defp planner(deps), do: Keyword.get(deps, :plan_fun, &ManagerSessionStart.plan/2)
  defp format(result, :json), do: CommandHelpers.encode_line(result)

  defp format(result, :human) do
    """
    Session plan (no state changed)
    Runtime: #{result.runtime}
    Repository: #{result.repository}@#{result.base_commit}
    Sandbox: #{result.sandbox_profile}
    Network: #{result.network}
    Write: #{result.write}
    Paths: #{Enum.join(result.allowed_paths, ", ")}
    Approval: #{result.approval_status}
    Deadline: #{result.deadline}
    """
  end

  defp error(reason, args) do
    format = if("json" in args, do: :json, else: :human)
    {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
  end
end
