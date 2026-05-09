defmodule Twelvgaige.CLI.Commands.ShellNew do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.Authoring.Scaffold
  alias Twelvgaige.CLI.AuthoringIO
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell.Document

  import Twelvgaige.CLI.CommandHelpers, only: [format_command_error: 2, root_opts: 1]

  @spec new(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def new(id, args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, format} <- new_format(opts),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringIO.ensure_output_within_root(opts[:output], root),
         {:ok, expansion} <- Scaffold.expand(opts[:scaffold], id, scaffold_opts(opts, root)),
         {:ok, workflow_contents} <- Document.encode(expansion.workflow, format) do
      if opts[:write?] do
        write_new(expansion, workflow_contents, format, opts)
      else
        {:ok, workflow_contents, 0}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp write_new(expansion, workflow_contents, format, opts) do
    case opts[:output] do
      nil ->
        Twelvgaige.Error.new(:input_error, :invalid_shell, "--output is required with --write")
        |> AuthoringIO.format_write_error()

      workflow_path ->
        with :ok <- AuthoringIO.ensure_can_write(workflow_path, opts),
             {:ok, agent_writes} <- agent_writes(expansion.agents, workflow_path, format, opts),
             :ok <- AuthoringIO.write_file(workflow_path, workflow_contents),
             :ok <- write_agent_shells(agent_writes) do
          output =
            [
              "created workflow shell: #{workflow_path}"
              | Enum.map(agent_writes, fn {path, _contents} -> "created agent shell: #{path}" end)
            ]
            |> Enum.join("\n")
            |> Kernel.<>("\n")

          {:ok, output, 0}
        else
          {:error, error} -> AuthoringIO.format_write_error(error)
        end
    end
  end

  defp agent_writes([], _workflow_path, _format, _opts), do: {:ok, []}

  defp agent_writes(agents, workflow_path, format, opts) do
    agent_dir = Path.join(Path.dirname(workflow_path), "agents")
    extension = document_extension(format)

    Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, writes} ->
      path = Path.join(agent_dir, "#{Map.fetch!(agent, "id")}#{extension}")

      with :ok <- AuthoringIO.ensure_can_write(path, opts),
           {:ok, contents} <- Document.encode(agent, format) do
        {:cont, {:ok, writes ++ [{path, contents}]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp write_agent_shells(writes) do
    Enum.reduce_while(writes, :ok, fn {path, contents}, :ok ->
      case AuthoringIO.write_file(path, contents) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp parse_opts(args) do
    parse_opts(args,
      scaffold: "single-shot",
      scaffold_paths: [],
      format: nil,
      output: nil,
      write?: false,
      force?: false,
      with_mock_agents?: false,
      root: nil
    )
  end

  defp parse_opts([], opts), do: {:ok, opts}

  defp parse_opts(["--scaffold", scaffold | rest], opts) do
    parse_opts(rest, Keyword.put(opts, :scaffold, scaffold))
  end

  defp parse_opts(["--scaffold-path", path | rest], opts) do
    parse_opts(rest, Keyword.update!(opts, :scaffold_paths, &(&1 ++ [path])))
  end

  defp parse_opts(["--format", format | rest], opts) do
    case parse_document_format(format) do
      {:ok, format} -> parse_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_opts(["--output", output | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :output, output))

  defp parse_opts(["--root", root | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :root, root))

  defp parse_opts(["--with-mock-agents" | rest], opts) do
    parse_opts(rest, Keyword.put(opts, :with_mock_agents?, true))
  end

  defp parse_opts(["--write" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_opts(["--dry-run" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_opts(["--force" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :force?, true))

  defp parse_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp scaffold_opts(opts, root) do
    [
      scaffold_paths: opts[:scaffold_paths],
      root: root[:root],
      with_mock_agents?: opts[:with_mock_agents?]
    ]
  end

  defp new_format(opts) do
    case Keyword.get(opts, :format) do
      nil -> infer_document_format(Keyword.get(opts, :output))
      format -> {:ok, format}
    end
  end

  defp infer_document_format(nil), do: {:ok, :yaml}

  defp infer_document_format(path) do
    case path |> Path.extname() |> String.downcase() do
      ".json" -> {:ok, :json}
      ".toml" -> {:ok, :toml}
      ".yaml" -> {:ok, :yaml}
      ".yml" -> {:ok, :yaml}
      _extension -> {:ok, :yaml}
    end
  end

  defp parse_document_format("json"), do: {:ok, :json}
  defp parse_document_format("yaml"), do: {:ok, :yaml}
  defp parse_document_format("toml"), do: {:ok, :toml}

  defp parse_document_format(_format) do
    {:error,
     Twelvgaige.Error.new(:input_error, :invalid_shell, "format must be json, yaml, or toml")}
  end

  defp document_extension(:json), do: ".json"
  defp document_extension(:toml), do: ".toml"
  defp document_extension(:yaml), do: ".yaml"
end
