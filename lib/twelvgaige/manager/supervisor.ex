defmodule Twelvgaige.Manager.Supervisor do
  @moduledoc "Single-user durable manager control-plane supervision tree."

  use Supervisor

  alias Twelvgaige.Manager.Scheduler
  alias Twelvgaige.Manager.Store.Operations
  alias Twelvgaige.Manager.Store.Memory
  alias Twelvgaige.Workspace.Manager, as: WorkspaceManager

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    scheduler_name = Keyword.get(opts, :scheduler_name, Twelvgaige.Manager.Scheduler)
    workspace_name = Keyword.get(opts, :workspace_manager_name, WorkspaceManager)
    {store_module, store_server, store_children} = store_config(opts)

    scheduler_opts =
      opts
      |> Keyword.fetch!(:scheduler)
      |> Keyword.put(:name, scheduler_name)
      |> Keyword.put(:store, store_module)
      |> Keyword.put(:store_server, store_server)
      |> Keyword.update(
        :child_factory_opts,
        [workspace_manager: workspace_name],
        &Keyword.put_new(&1, :workspace_manager, workspace_name)
      )

    workspace_opts = [
      name: workspace_name,
      root: workspace_root(opts),
      operations_store: Keyword.get(opts, :operations_store)
    ]

    children = store_children ++ [{WorkspaceManager, workspace_opts}, {Scheduler, scheduler_opts}]

    # If the durable store fails, restart the scheduler after it so no scheduler
    # continues against a dead or newly replaced authority.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp store_config(opts) do
    case Keyword.get(opts, :operations_store) do
      nil ->
        store_name = Keyword.get(opts, :store_name, Memory)
        store_path = opts |> Keyword.fetch!(:store_path) |> Path.expand()
        {Memory, store_name, [{Memory, name: store_name, persistence_path: store_path}]}

      operations_store ->
        {Operations, operations_store, []}
    end
  end

  defp workspace_root(opts) do
    cond do
      root = Keyword.get(opts, :workspace_root) ->
        Path.expand(root)

      path = Keyword.get(opts, :store_path) ->
        Path.join(Path.dirname(Path.expand(path)), "workspaces")

      true ->
        Twelvgaige.Operations.Paths.workspaces(opts)
    end
  end
end
