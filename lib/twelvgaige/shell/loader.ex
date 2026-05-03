defmodule Twelvgaige.Shell.Loader do
  @moduledoc """
  Loader seam for shell files.
  """

  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Format.JSON, as: JSONFormat
  alias Twelvgaige.Shell.Format.TOML, as: TOMLFormat
  alias Twelvgaige.Shell.Format.YAML, as: YAMLFormat
  alias Twelvgaige.Shell.Validation, as: V

  @formats [YAMLFormat, JSONFormat, TOMLFormat]

  @spec supported_extensions() :: [String.t()]
  def supported_extensions do
    @formats
    |> Enum.flat_map(& &1.extensions())
    |> Enum.uniq()
  end

  @spec supported_extension?(String.t()) :: boolean()
  def supported_extension?(extension) when is_binary(extension) do
    String.downcase(extension) in supported_extensions()
  end

  def supported_extension?(_extension), do: false

  @spec shell_path?(String.t()) :: boolean()
  def shell_path?(path) when is_binary(path) do
    path |> Path.extname() |> supported_extension?()
  end

  def shell_path?(_path), do: false

  @spec load(Path.t(), keyword()) :: {:ok, Twelvgaige.Shell.t()} | {:error, Twelvgaige.Error.t()}
  def load(path, opts \\ [])

  def load(path, _opts) when is_binary(path) do
    with {:ok, format} <- format_for_path(path),
         {:ok, contents} <- read_file(path),
         {:ok, shell_map} <- format.parse(contents, path),
         {:ok, kind} <- shell_kind(shell_map) do
      build_shell(kind, shell_map)
    end
  end

  def load(_path, _opts) do
    V.error(:invalid_shell, "shell path must be a string", [], %{expected: "path"})
  end

  @spec load_agents_for_workflow(Path.t(), keyword()) :: {:ok, [Agent.t()]} | {:error, term()}
  def load_agents_for_workflow(workflow_path, opts \\ [])

  def load_agents_for_workflow(workflow_path, opts) when is_binary(workflow_path) do
    workflow_path
    |> agent_shell_paths_for_workflow(opts)
    |> load_agent_shells()
  end

  def load_agents_for_workflow(_workflow_path, _opts), do: {:ok, []}

  @spec agent_shell_paths_for_workflow(Path.t(), keyword()) :: [Path.t()]
  def agent_shell_paths_for_workflow(workflow_path, opts \\ [])

  def agent_shell_paths_for_workflow(workflow_path, opts) when is_binary(workflow_path) do
    explicit =
      opts
      |> Keyword.get(:agent_shells, Keyword.get(opts, :agent_shell_paths, []))
      |> List.wrap()

    discovered =
      if discover_agents?(opts) do
        workflow_path
        |> agent_discovery_dirs()
        |> Enum.flat_map(&shell_paths_in_dir/1)
      else
        []
      end

    (explicit ++ discovered)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
  end

  def agent_shell_paths_for_workflow(_workflow_path, _opts), do: []

  defp discover_agents?(opts) do
    cond do
      Keyword.get(opts, :discover_agents?) == false ->
        false

      Keyword.get(opts, :trusted_root?, true) == false or
          Keyword.get(opts, :untrusted_root?, false) ->
        Keyword.get(opts, :allow_untrusted_agent_discovery?, false) == true

      true ->
        Keyword.get(opts, :discover_agents?, true)
    end
  end

  defp agent_discovery_dirs(workflow_path) do
    [
      Path.join(Path.dirname(workflow_path), "agents"),
      priv_examples_agents_dir()
    ]
  end

  defp priv_examples_agents_dir do
    case :code.priv_dir(:twelvgaige) do
      priv when is_list(priv) -> Path.join(List.to_string(priv), "examples/agents")
      {:error, _reason} -> Path.expand("priv/examples/agents")
    end
  end

  defp shell_paths_in_dir(dir) do
    if File.dir?(dir) do
      supported_extensions()
      |> Enum.map(&Path.join(dir, "*#{&1}"))
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.sort()
    else
      []
    end
  end

  defp load_agent_shells(paths) do
    paths
    |> Enum.reduce_while({:ok, %{}}, fn path, {:ok, agents_by_id} ->
      with {:ok, %Agent{} = agent} <- load_agent_shell(path),
           {:ok, agents_by_id} <- put_agent(agents_by_id, agent, path) do
        {:cont, {:ok, agents_by_id}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, agents_by_id} -> {:ok, agents_by_id |> Map.values() |> Enum.sort_by(& &1.id)}
      {:error, _reason} = error -> error
    end
  end

  defp load_agent_shell(path) do
    case load(path) do
      {:ok, %Agent{} = agent} ->
        {:ok, agent}

      {:ok, _other_shell} ->
        V.error(:invalid_shell, "agent shell path did not load an agent", [], %{file_path: path})

      {:error, _reason} = error ->
        error
    end
  end

  defp put_agent(agents_by_id, %Agent{} = agent, path) do
    case Map.fetch(agents_by_id, agent.id) do
      {:ok, ^agent} ->
        {:ok, agents_by_id}

      {:ok, _other_agent} ->
        V.error(:invalid_shell, "duplicate agent shell id", [], %{
          agent_id: agent.id,
          file_path: path
        })

      :error ->
        {:ok, Map.put(agents_by_id, agent.id, agent)}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        V.error(:invalid_shell, "unable to read shell file", [], %{
          file_path: path,
          reason: inspect(reason)
        })
    end
  end

  defp format_for_path(path) do
    extension = path |> Path.extname() |> String.downcase()

    Enum.find(@formats, &(extension in &1.extensions()))
    |> case do
      nil ->
        V.error(:invalid_shell, "unsupported shell file extension", [], %{
          file_path: path,
          extension: extension,
          supported_extensions: supported_extensions()
        })

      format ->
        {:ok, format}
    end
  end

  defp shell_kind(shell_map) do
    case V.fetch(shell_map, :kind) do
      {:ok, kind} when kind in ["workflow", :workflow] ->
        {:ok, :workflow}

      {:ok, kind} when kind in ["agent", :agent] ->
        {:ok, :agent}

      {:ok, _kind} ->
        V.error(:invalid_shell, "shell kind must be workflow or agent", ["kind"])

      :error ->
        V.error(:invalid_shell, "missing required field \"kind\"", ["kind"], %{field: "kind"})
    end
  end

  defp build_shell(:workflow, shell_map), do: Twelvgaige.Shell.Workflow.from_map(shell_map)
  defp build_shell(:agent, shell_map), do: Twelvgaige.Shell.Agent.from_map(shell_map)
end
