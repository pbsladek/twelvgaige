defmodule Twelvgaige.CLI.Commands.ShellCache do
  @moduledoc false

  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell

  import Twelvgaige.CLI.CommandHelpers, only: [format_command_error: 2, value: 3]

  @spec validate(String.t(), keyword()) :: {:ok, String.t(), non_neg_integer()}
  def validate(path, opts) do
    format = Keyword.fetch!(opts, :format)

    case Twelvgaige.validate_shell(path) do
      {:ok, shell} -> {:ok, format_shell(shell, format), 0}
      {:error, error} -> {:ok, format_error(error, format), 4}
    end
  end

  @spec reload([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def reload(args) do
    with {:ok, opts} <- parse_reload_opts(args) do
      reload_opts =
        case Keyword.fetch!(opts, :paths) do
          [] -> []
          paths -> [paths: paths]
        end

      case Twelvgaige.reload_shells(reload_opts) do
        {:ok, summary} ->
          {:ok, format_reload(summary, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec list([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def list(args) do
    with {:ok, opts} <- parse_list_opts(args),
         {:ok, shells} <- cached_shells(opts[:kind]) do
      {:ok, format_list(shells, opts[:format]), 0}
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec show(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def show(shell_id, args) do
    with {:ok, opts} <- parse_show_opts(args) do
      case Twelvgaige.get_shell(shell_id, kind: opts[:kind]) do
        {:ok, shell} ->
          {:ok, format_detail(shell, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_reload_opts(args), do: parse_reload_opts(args, format: :human, paths: [])
  defp parse_reload_opts([], opts), do: {:ok, opts}

  defp parse_reload_opts(["--format", format | rest], opts) do
    parse_reload_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_reload_opts([path | rest], opts) do
    if String.starts_with?(path, "--") do
      {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{path}")}
    else
      parse_reload_opts(rest, Keyword.update!(opts, :paths, &(&1 ++ [path])))
    end
  end

  defp parse_list_opts(args), do: parse_list_opts(args, format: :human, kind: :all)
  defp parse_list_opts([], opts), do: {:ok, opts}

  defp parse_list_opts(["--format", format | rest], opts) do
    parse_list_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_list_opts(["--kind", kind | rest], opts) do
    case parse_kind(kind, [:workflow, :agent, :all]) do
      {:ok, kind} -> parse_list_opts(rest, Keyword.put(opts, :kind, kind))
      {:error, _error} = error -> error
    end
  end

  defp parse_list_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_show_opts(args), do: parse_show_opts(args, format: :human, kind: :any)
  defp parse_show_opts([], opts), do: {:ok, opts}

  defp parse_show_opts(["--format", format | rest], opts) do
    parse_show_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_show_opts(["--kind", kind | rest], opts) do
    case parse_kind(kind, [:workflow, :agent]) do
      {:ok, kind} -> parse_show_opts(rest, Keyword.put(opts, :kind, kind))
      {:error, _error} = error -> error
    end
  end

  defp parse_show_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_kind(kind, allowed) do
    parsed =
      case kind do
        "workflow" -> :workflow
        "agent" -> :agent
        "all" -> :all
        _other -> :invalid
      end

    if parsed in allowed do
      {:ok, parsed}
    else
      allowed = allowed |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")

      {:error,
       Twelvgaige.Error.new(:input_error, :invalid_shell, "--kind must be one of #{allowed}")}
    end
  end

  defp parse_format("json"), do: :json
  defp parse_format("human"), do: :human
  defp parse_format(_other), do: :human

  defp cached_shells(:workflow), do: Twelvgaige.list_shells()
  defp cached_shells(:agent), do: Twelvgaige.list_agents()

  defp cached_shells(:all) do
    with {:ok, workflows} <- Twelvgaige.list_shells(),
         {:ok, agents} <- Twelvgaige.list_agents() do
      {:ok, Enum.sort_by(workflows ++ agents, &{shell_kind(&1), &1.id})}
    end
  end

  defp format_shell(%Shell.Workflow{} = shell, :human) do
    "valid workflow shell: #{shell.id} #{shell.version}\n"
  end

  defp format_shell(%Shell.Agent{} = shell, :human) do
    "valid agent shell: #{shell.id} #{shell.version || "unversioned"}\n"
  end

  defp format_shell(shell, :json) do
    shell
    |> shell_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_detail(%Shell.Workflow{} = shell, :human) do
    shots =
      shell.shots
      |> Enum.map(&"  - #{&1.id} [#{&1.kind}]")
      |> Enum.join("\n")

    """
    Workflow shell: #{shell.id} #{shell.version}
    Name: #{shell.name || ""}
    Shots:
    #{shots}
    """
  end

  defp format_detail(%Shell.Agent{} = shell, :human) do
    """
    Agent shell: #{shell.id} #{shell.version || "unversioned"}
    Name: #{shell.name || ""}
    Provider: #{shell.provider}
    Model: #{shell.model}
    """
  end

  defp format_detail(shell, :json), do: format_shell(shell, :json)

  defp format_list([], :human), do: "No shells.\n"

  defp format_list(shells, :human) do
    shells
    |> Enum.map(fn shell ->
      "#{shell_kind(shell)}  #{shell.id}  #{shell.version || "unversioned"}"
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_list(shells, :json) do
    shells
    |> Enum.map(&shell_map/1)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_reload(summary, :json) do
    summary
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_reload(summary, :human) do
    paths = value(summary, :paths, [])
    workflows = value(summary, :workflows, [])
    agents = value(summary, :agents, [])

    """
    Shell cache reloaded
    Paths: #{length(paths)}
    Workflows: #{format_id_list(workflows)}
    Agents: #{format_id_list(agents)}
    """
  end

  defp shell_map(%Shell.Workflow{} = shell) do
    %{
      kind: "workflow",
      id: shell.id,
      name: shell.name,
      version: shell.version,
      shots: Enum.map(shell.shots, & &1.id)
    }
  end

  defp shell_map(%Shell.Agent{} = shell) do
    %{
      kind: "agent",
      id: shell.id,
      name: shell.name,
      version: shell.version,
      provider: shell.provider,
      model: shell.model
    }
  end

  defp shell_kind(%Shell.Workflow{}), do: "workflow"
  defp shell_kind(%Shell.Agent{}), do: "agent"

  defp format_id_list([]), do: "none"
  defp format_id_list(ids), do: Enum.join(ids, ", ")

  defp format_error(error, :json) do
    %{error: Twelvgaige.Error.to_map(error)}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_error(error, :human), do: "error: #{error.message}\n"
end
