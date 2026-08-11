defmodule Twelvgaige.CLI.Commands.Support do
  @moduledoc false

  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}
  alias Twelvgaige.Developer.SupportBundle

  def bundle(args, deps \\ []) do
    with {:ok, opts} <- parse(args, defaults()),
         {:ok, report} <- Keyword.get(deps, :bundle_fun, &SupportBundle.run/1).(opts) do
      {:ok, format(report, opts[:format]), 0}
    else
      {:error, reason} ->
        format = if("json" in args, do: :json, else: :human)
        {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
    end
  end

  defp defaults do
    [
      format: :human,
      destination: nil,
      write?: false,
      yes?: false,
      request_id: Twelvgaige.ID.new(:event)
    ]
  end

  defp parse([], opts), do: {:ok, opts}

  defp parse(["--output", value | rest], opts) when value != "",
    do: parse(rest, Keyword.put(opts, :destination, value))

  defp parse(["--format", value | rest], opts) when value in ["human", "json"],
    do: parse(rest, Keyword.put(opts, :format, String.to_existing_atom(value)))

  defp parse(["--root", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :project_root, value))

  defp parse(["--runtime-dir", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :runtime_dir, value))

  defp parse(["--endpoint", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :endpoint_path, value))

  defp parse(["--request-id", value | rest], opts) when value != "",
    do: parse(rest, Keyword.put(opts, :request_id, value))

  defp parse(["--write" | rest], opts), do: parse(rest, Keyword.put(opts, :write?, true))
  defp parse(["--yes" | rest], opts), do: parse(rest, Keyword.put(opts, :yes?, true))
  defp parse([unknown | _rest], _opts), do: {:error, {:unknown_option, unknown}}

  defp format(report, :json), do: CommandHelpers.encode_line(report)

  defp format(report, :human) do
    files = report.files |> Map.keys() |> Enum.sort() |> Enum.join(", ")

    if report.dry_run do
      "Support bundle preview: #{report.destination}\nFiles: #{files}\nRedaction: allowlist-only\nNext: repeat with --write --yes --request-id #{report.request_id}\n"
    else
      replay = if report.replayed, do: " (verified replay)", else: ""
      "Support bundle written#{replay}: #{report.destination}\nFiles: #{files}\n"
    end
  end
end
