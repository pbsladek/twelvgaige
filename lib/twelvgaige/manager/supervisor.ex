defmodule Twelvgaige.Manager.Supervisor do
  @moduledoc "Single-user durable manager control-plane supervision tree."

  use Supervisor

  alias Twelvgaige.Manager.Scheduler
  alias Twelvgaige.Manager.Runtime
  alias Twelvgaige.Manager.VerificationExecutor
  alias Twelvgaige.Manager.WorkspaceFinalizer
  alias Twelvgaige.Manager.Store.Operations
  alias Twelvgaige.Manager.Store.Memory
  alias Twelvgaige.Sandbox.{Admission, Manager, Backend}
  alias Twelvgaige.Workspace.Manager, as: WorkspaceManager

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    scheduler_name = Keyword.get(opts, :scheduler_name, Twelvgaige.Manager.Scheduler)
    workspace_name = Keyword.get(opts, :workspace_manager_name, WorkspaceManager)
    workspace_root = workspace_root(opts)
    {store_module, store_server, store_children} = store_config(opts)

    verification_executor =
      Keyword.get(opts, :verification_executor) ||
        VerificationExecutor.from_options(Keyword.get(opts, :verification_sandbox, []))

    scheduler_opts =
      opts
      |> Keyword.fetch!(:scheduler)
      |> Keyword.put(:name, scheduler_name)
      |> Keyword.put(:store, store_module)
      |> Keyword.put(:store_server, store_server)
      |> Keyword.put_new(
        :workspace_finalize_fun,
        &WorkspaceFinalizer.finalize(&1, &2,
          workspace_manager: workspace_name,
          artifact_store: Keyword.get(opts, :artifact_store),
          verification_commands: Keyword.get(opts, :verification_commands, []),
          verification_executor: verification_executor,
          verification_timeout_ms: Keyword.get(opts, :verification_timeout_ms, 900_000),
          verification_environment_names: Keyword.get(opts, :verification_environment_names, [])
        )
      )
      |> Keyword.update(
        :child_factory_opts,
        [workspace_manager: workspace_name],
        &Keyword.put_new(&1, :workspace_manager, workspace_name)
      )

    {runtime_children, scheduler_opts} =
      runtime_config(opts, scheduler_opts, workspace_name, workspace_root)

    workspace_opts = [
      name: workspace_name,
      root: workspace_root,
      operations_store: Keyword.get(opts, :operations_store),
      artifact_store:
        Keyword.get(opts, :artifact_store, Process.whereis(Twelvgaige.Artifact.Store))
    ]

    children =
      store_children ++
        [{WorkspaceManager, workspace_opts}] ++ runtime_children ++ [{Scheduler, scheduler_opts}]

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

  defp runtime_config(opts, scheduler_opts, workspace_name, workspace_root) do
    case Keyword.get(opts, :runtime) do
      nil ->
        {[], scheduler_opts}

      runtime when is_list(runtime) ->
        backend = backend_module(Keyword.fetch!(runtime, :backend))
        admission_name = Keyword.get(runtime, :admission_name, Twelvgaige.Sandbox.Admission)
        sandbox_name = Keyword.get(runtime, :sandbox_manager_name, Twelvgaige.Sandbox.Manager)

        runtime =
          runtime
          |> Keyword.put(:backend, backend)
          |> Keyword.put(:sandbox_manager, sandbox_name)
          |> Keyword.put_new(:allowed_export_roots, [workspace_root])
          |> Keyword.put_new(:session_control, Keyword.get(opts, :session_control))

        admission_opts = [
          name: admission_name,
          limits: Keyword.fetch!(runtime, :admission_limits)
        ]

        sandbox_opts =
          [
            name: sandbox_name,
            admission: admission_name,
            backend: backend,
            credential_broker: Keyword.get(runtime, :credential_broker),
            egress_broker: Keyword.get(runtime, :egress_broker),
            egress_boundary: Keyword.get(runtime, :egress_boundary, Twelvgaige.Egress.Boundary),
            egress_boundary_backend: Keyword.get(runtime, :egress_boundary_backend),
            operations_store: Keyword.get(opts, :operations_store),
            recovery_opts: Keyword.fetch!(runtime, :backend_opts)
          ]

        scheduler_opts =
          scheduler_opts
          |> Keyword.put_new(:executor, Runtime.executor(workspace_name, runtime))
          |> Keyword.put_new(:cancel_fun, &Runtime.cancel(&1, workspace_name, runtime))

        {[{Admission, admission_opts}, {Manager, sandbox_opts}], scheduler_opts}
    end
  end

  defp backend_module(:podman), do: Backend.Podman
  defp backend_module(:apple_container), do: Backend.AppleContainer
  defp backend_module(module) when is_atom(module), do: module
end
