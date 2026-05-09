defmodule Twelvgaige.CLI.Commands.Status do
  @moduledoc false

  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers, only: [format_command_error: 2, value: 2, value: 3]

  @spec run(keyword()) :: {:ok, String.t(), non_neg_integer()}
  def run(opts) do
    format = Keyword.fetch!(opts, :format)

    case Twelvgaige.status() do
      {:ok, status} -> {:ok, format_status(status, format), 0}
      {:error, :daemon_unavailable} -> {:ok, "daemon unavailable\n", 5}
      {:error, error} -> {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp format_status(status, :json) do
    status
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_status(status, :human) do
    resources = value(status, :resources, %{})
    used = value(resources, :used, %{})
    limits = value(resources, :limits, %{})
    store = value(status, :store, %{})

    """
    Breech: running
    Version: #{value(status, :version)}
    Daemon ID: #{value(status, :daemon_id)}
    Profile: #{value(status, :profile)}
    IPC: #{value(status, :ipc)}
    Uptime: #{value(status, :uptime_ms)}ms
    Store: #{value(store, :status)}
    Incomplete rounds: #{value(store, :incomplete_rounds, 0) || 0}
    LLM calls: #{used["llm_call"] || 0}/#{limits["llm_call"] || 0}
    Tool exec: #{used["tool_exec"] || 0}/#{limits["tool_exec"] || 0}
    """
  end
end
