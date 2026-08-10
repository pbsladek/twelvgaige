defmodule Twelvgaige.CLI.Commands.TaskValidate do
  @moduledoc false

  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}
  alias Twelvgaige.CLI.Commands.SessionStart

  def run(path, args, deps \\ []) do
    with {:ok, opts} <- SessionStart.resolve(["--task-file", path | args], deps) do
      request = SessionStart.request(opts)

      result = %{
        status: :valid,
        task_file: Path.expand(path),
        profile: opts[:resolved_profile],
        effective: Map.drop(request, ["task"]),
        objective_bytes: byte_size(request["task"])
      }

      {:ok, format(result, opts[:format]), 0}
    else
      {:error, reason} ->
        format = if("json" in args, do: :json, else: :human)
        {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
    end
  end

  defp format(result, :json), do: CommandHelpers.encode_line(result)

  defp format(result, :human) do
    "Task is valid: #{result.task_file}\nProfile: #{result.profile || "none"}\nObjective bytes: #{result.objective_bytes}\n"
  end
end
