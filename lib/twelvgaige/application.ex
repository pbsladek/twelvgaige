defmodule Twelvgaige.Application do
  @moduledoc false

  use Application

  alias Twelvgaige.Store.Config, as: StoreConfig

  @impl true
  def start(_type, _args) do
    with :ok <- Twelvgaige.Platform.ensure_supported() do
      start_supervisor()
    end
  end

  defp start_supervisor do
    store_config = StoreConfig.resolve()
    store_module = StoreConfig.module(store_config)

    children =
      [
        StoreConfig.child_spec(store_config),
        Twelvgaige.API.WebhookReplayCache,
        Twelvgaige.Metrics,
        Twelvgaige.Shell.Cache,
        {Twelvgaige.ResourceLimiter, profile: Twelvgaige.RuntimeProfile.default()},
        Twelvgaige.Round.Supervisor,
        {Task.Supervisor, name: Twelvgaige.Breech.TaskSupervisor},
        {Twelvgaige.Breech, store: store_module}
      ]
      |> maybe_add_operations_control_plane()
      |> maybe_add_scheduler()
      |> maybe_add_manager_control_plane()
      |> maybe_add_http_listener()

    with {:ok, supervisor} <-
           Supervisor.start_link(children, strategy: :one_for_one, name: Twelvgaige.Supervisor) do
      :ok = Twelvgaige.CLI.Burrito.maybe_start_cli()
      {:ok, supervisor}
    end
  end

  defp maybe_add_scheduler(children) do
    jobs = Application.get_env(:twelvgaige, :scheduler_jobs, [])

    if jobs == [] do
      children
    else
      scheduler_opts =
        case Application.get_env(:twelvgaige, :operations_control_plane, false) do
          opts when is_list(opts) ->
            [
              jobs: jobs,
              operations_store: Keyword.get(opts, :store_name, Twelvgaige.Operations.Store)
            ]

          _other ->
            [jobs: jobs]
        end

      children ++ [{Twelvgaige.Scheduler, scheduler_opts}]
    end
  end

  defp maybe_add_operations_control_plane(children) do
    case Application.get_env(:twelvgaige, :operations_control_plane, false) do
      false -> children
      nil -> children
      opts when is_list(opts) -> children ++ [{Twelvgaige.Operations.Supervisor, opts}]
    end
  end

  defp maybe_add_manager_control_plane(children) do
    case Application.get_env(:twelvgaige, :manager_control_plane, false) do
      false ->
        children

      nil ->
        children

      opts when is_list(opts) ->
        opts =
          case Application.get_env(:twelvgaige, :operations_control_plane, false) do
            operations_opts when is_list(operations_opts) ->
              opts
              |> Keyword.put_new(
                :operations_store,
                Keyword.get(operations_opts, :store_name, Twelvgaige.Operations.Store)
              )
              |> Keyword.put_new(
                :workspace_root,
                Twelvgaige.Operations.Paths.workspaces(operations_opts)
              )

            _other ->
              opts
          end

        children ++ [{Twelvgaige.Manager.Supervisor, opts}]
    end
  end

  defp maybe_add_http_listener(children) do
    case Application.get_env(:twelvgaige, :http_listener, false) do
      false -> children
      nil -> children
      opts when is_list(opts) -> children ++ [{Twelvgaige.API.Server, opts}]
    end
  end
end
