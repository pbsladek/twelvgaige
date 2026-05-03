defmodule Twelvgaige.Shell.Cache do
  @moduledoc """
  In-memory owner for configured workflow and agent shell definitions.

  The cache is deliberately separate from round process lookup. It gives the
  daemon a stable definition source for configured shell IDs while foreground
  execution can keep using explicit file paths.
  """

  use GenServer

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Loader
  alias Twelvgaige.Shell.Validation, as: V
  alias Twelvgaige.Shell.Workflow

  defstruct paths: [], workflows: %{}, agents: %{}

  @type t :: %__MODULE__{
          paths: [Path.t()],
          workflows: %{String.t() => Workflow.t()},
          agents: %{String.t() => Agent.t()}
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec get_workflow(String.t(), keyword()) :: {:ok, Workflow.t()} | {:error, Error.t()}
  def get_workflow(id, opts \\ []) when is_binary(id) do
    call(opts, {:get_workflow, id})
  end

  @spec get_agent(String.t(), keyword()) :: {:ok, Agent.t()} | {:error, Error.t()}
  def get_agent(id, opts \\ []) when is_binary(id) do
    call(opts, {:get_agent, id})
  end

  @spec workflow_with_agents(String.t(), keyword()) ::
          {:ok, Workflow.t(), [Agent.t()]} | {:error, Error.t()}
  def workflow_with_agents(id, opts \\ []) when is_binary(id) do
    call(opts, {:workflow_with_agents, id})
  end

  @spec list_workflows(keyword()) :: {:ok, [Workflow.t()]} | {:error, Error.t()}
  def list_workflows(opts \\ []), do: call(opts, :list_workflows)

  @spec list_agents(keyword()) :: {:ok, [Agent.t()]} | {:error, Error.t()}
  def list_agents(opts \\ []), do: call(opts, :list_agents)

  @spec reload(keyword()) :: {:ok, map()} | {:error, Error.t()}
  def reload(opts \\ []), do: call(opts, {:reload, Keyword.get(opts, :paths, :configured)})

  @impl true
  def init(opts) do
    paths = configured_paths(opts)

    with {:ok, state} <- load_paths(paths) do
      {:ok, state}
    else
      {:error, %Error{} = error} -> {:stop, error}
    end
  end

  @impl true
  def handle_call({:get_workflow, id}, _from, state) do
    {:reply, fetch_shell(state.workflows, id, :workflow), state}
  end

  def handle_call({:get_agent, id}, _from, state) do
    {:reply, fetch_shell(state.agents, id, :agent), state}
  end

  def handle_call({:workflow_with_agents, id}, _from, state) do
    reply =
      case fetch_shell(state.workflows, id, :workflow) do
        {:ok, workflow} -> {:ok, workflow, sorted_values(state.agents)}
        {:error, _error} = error -> error
      end

    {:reply, reply, state}
  end

  def handle_call(:list_workflows, _from, state) do
    {:reply, {:ok, sorted_values(state.workflows)}, state}
  end

  def handle_call(:list_agents, _from, state) do
    {:reply, {:ok, sorted_values(state.agents)}, state}
  end

  def handle_call({:reload, :configured}, _from, state) do
    reload_paths(state.paths, state)
  end

  def handle_call({:reload, paths}, _from, state) do
    reload_paths(List.wrap(paths), state)
  end

  defp call(opts, message) do
    opts
    |> Keyword.get(:server, __MODULE__)
    |> resolve_server()
    |> case do
      nil ->
        {:error,
         definition_error("shell cache is unavailable", %{
           cache: inspect(Keyword.get(opts, :server, __MODULE__))
         })}

      server ->
        GenServer.call(server, message)
    end
  catch
    :exit, reason ->
      {:error, definition_error("shell cache is unavailable", %{reason: inspect(reason)})}
  end

  defp resolve_server(pid) when is_pid(pid) do
    if Process.alive?(pid), do: pid
  end

  defp resolve_server(name) when is_atom(name), do: Process.whereis(name)
  defp resolve_server({:via, _module, _term} = via), do: via
  defp resolve_server(_server), do: nil

  defp configured_paths(opts) do
    opts
    |> Keyword.get(:paths, Application.get_env(:twelvgaige, :shell_paths, []))
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&Path.expand/1)
  end

  defp reload_paths(paths, previous_state) do
    case load_paths(paths) do
      {:ok, state} ->
        {:reply, {:ok, summary(state)}, state}

      {:error, %Error{} = error} ->
        {:reply, {:error, error}, previous_state}
    end
  end

  defp load_paths(paths) do
    with {:ok, shell_paths} <- shell_paths(paths) do
      shell_paths
      |> Enum.reduce_while({:ok, %__MODULE__{paths: paths}}, fn path, {:ok, state} ->
        case load_shell(path, state) do
          {:ok, state} -> {:cont, {:ok, state}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end)
    end
  end

  defp shell_paths(paths) do
    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, acc} ->
      case shell_paths_for(path) do
        {:ok, paths} -> {:cont, {:ok, acc ++ paths}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, paths} -> {:ok, paths |> Enum.uniq() |> Enum.sort()}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp shell_paths_for(path) do
    cond do
      File.dir?(path) ->
        {:ok,
         Loader.supported_extensions()
         |> Enum.map(&Path.join(path, "**/*#{&1}"))
         |> Enum.flat_map(&Path.wildcard/1)}

      File.regular?(path) ->
        {:ok, [path]}

      true ->
        V.error(:invalid_shell, "configured shell path does not exist", [], %{file_path: path})
    end
  end

  defp load_shell(path, state) do
    case Loader.load(path) do
      {:ok, %Workflow{} = workflow} ->
        put_shell(state, :workflow, workflow, path)

      {:ok, %Agent{} = agent} ->
        put_shell(state, :agent, agent, path)

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp put_shell(state, :workflow, %Workflow{} = workflow, path) do
    put_by_id(state, :workflows, workflow.id, workflow, path, "duplicate workflow shell id")
  end

  defp put_shell(state, :agent, %Agent{} = agent, path) do
    put_by_id(state, :agents, agent.id, agent, path, "duplicate agent shell id")
  end

  defp put_by_id(state, field, id, shell, path, message) do
    shells = Map.fetch!(state, field)

    case Map.fetch(shells, id) do
      {:ok, ^shell} ->
        {:ok, state}

      {:ok, _other_shell} ->
        V.error(:invalid_shell, message, [], %{shell_id: id, file_path: path})

      :error ->
        {:ok, Map.put(state, field, Map.put(shells, id, shell))}
    end
  end

  defp fetch_shell(shells, id, kind) do
    case Map.fetch(shells, id) do
      {:ok, shell} ->
        {:ok, shell}

      :error ->
        {:error,
         definition_error("#{kind} shell not found", %{
           shell_id: id,
           shell_kind: Atom.to_string(kind),
           known_shells: Map.keys(shells) |> Enum.sort()
         })}
    end
  end

  defp sorted_values(shells), do: shells |> Map.values() |> Enum.sort_by(& &1.id)

  defp summary(state) do
    %{
      paths: state.paths,
      workflows: Map.keys(state.workflows) |> Enum.sort(),
      agents: Map.keys(state.agents) |> Enum.sort()
    }
  end

  defp definition_error(message, details) do
    Error.new(:compile_error, :definition_not_found, message, details: details)
  end
end
