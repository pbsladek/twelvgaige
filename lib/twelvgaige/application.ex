defmodule Twelvgaige.Application do
  @moduledoc false

  use Application

  alias Twelvgaige.Store.Config, as: StoreConfig

  @impl true
  def start(_type, _args) do
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
      |> maybe_add_scheduler()
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
      children ++ [{Twelvgaige.Scheduler, jobs: jobs}]
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
