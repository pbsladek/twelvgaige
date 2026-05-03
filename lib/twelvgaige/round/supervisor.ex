defmodule Twelvgaige.Round.Supervisor do
  @moduledoc """
  Dynamic supervisor for foreground and future daemon-owned rounds.
  """

  use DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_round(Twelvgaige.Shell.Workflow.t(), map(), keyword()) ::
          DynamicSupervisor.on_start_child()
  def start_round(workflow, input, opts \\ []) do
    child_spec = {Twelvgaige.Round.Server, {workflow, input, opts}}

    DynamicSupervisor.start_child(__MODULE__, child_spec)
  end
end
