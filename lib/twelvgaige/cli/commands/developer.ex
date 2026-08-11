defmodule Twelvgaige.CLI.Commands.Developer do
  @moduledoc false

  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}
  alias Twelvgaige.Developer.{Doctor, Init}

  def init(args, deps \\ []), do: command(:init, args, deps)
  def doctor(args, deps \\ []), do: command(:doctor, args, deps)

  defp command(kind, args, deps) do
    with {:ok, opts} <- parse(args, format: :human, fix?: false, force?: false),
         {:ok, result} <- execute(kind, opts, deps) do
      code = if kind == :doctor and result.status != :ready, do: 1, else: 0
      {:ok, format(kind, result, opts[:format]), code}
    else
      {:error, reason} ->
        output_format = if("json" in args, do: :json, else: :human)

        {:ok, CommandHelpers.format_command_error(reason, output_format),
         ExitCode.for_error(reason)}
    end
  end

  defp execute(:init, opts, deps) do
    Keyword.get(deps, :init_fun, &Init.run/1).(opts)
  end

  defp execute(:doctor, opts, deps) do
    Keyword.get(deps, :doctor_fun, &Doctor.run/1).(opts)
  end

  defp parse([], opts), do: {:ok, opts}

  defp parse(["--format", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :format, CommandHelpers.parse_format(value)))

  defp parse(["--profile", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :profile, value))

  defp parse(["--auth-profile", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :auth_profile, value))

  defp parse(["--sandbox", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :sandbox, value))

  defp parse(["--root", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :project_root, value))

  defp parse(["--force" | rest], opts), do: parse(rest, Keyword.put(opts, :force?, true))
  defp parse(["--fix" | rest], opts), do: parse(rest, Keyword.put(opts, :fix?, true))
  defp parse([unknown | _rest], _opts), do: {:error, {:unknown_option, unknown}}

  defp format(_kind, result, :json), do: CommandHelpers.encode_line(result)

  defp format(:init, result, :human) do
    """
    Project initialized: #{result.project_root}
    Profile: #{result.profile}
    Config: #{result.config_path}
    Example task: #{result.task_path}
    #{if(result.auth_configured, do: "Authentication profile configured.", else: "Next: add an auth_profile to the generated profile.")}
    """
  end

  defp format(:doctor, result, :human) do
    checks =
      Enum.map_join(result.checks, "\n", fn check ->
        remedy = if check[:remedy], do: " — #{check.remedy}", else: ""
        "  #{check.status}: #{check.name} (#{inspect(check.detail)})#{remedy}"
      end)

    versions =
      result
      |> Map.get(:versions, %{})
      |> Enum.sort()
      |> Enum.map_join("\n", fn {name, version} -> "  #{name}: #{version}" end)

    capability_names =
      result
      |> Map.get(:capabilities, %{})
      |> Map.get(:provider, %{})
      |> Enum.filter(fn {_name, enabled} -> enabled == true end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> Enum.join(", ")

    version_section = if versions == "", do: "", else: "\nVersions:\n#{versions}"

    capability_section =
      if capability_names == "", do: "", else: "\nProvider capabilities: #{capability_names}"

    "Developer readiness: #{result.status}\n#{checks}#{version_section}#{capability_section}\n"
  end
end
