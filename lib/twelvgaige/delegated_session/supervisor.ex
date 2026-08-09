defmodule Twelvgaige.DelegatedSession.Supervisor do
  @moduledoc "Dynamic supervisor for independently governed delegated sessions."
  use DynamicSupervisor

  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_session(opts, supervisor \\ __MODULE__) do
    spec = %{
      id: {Twelvgaige.DelegatedSession.Controller, Keyword.fetch!(opts, :session).id},
      start: {Twelvgaige.DelegatedSession.Controller, :start_link, [opts]},
      restart: :transient
    }

    DynamicSupervisor.start_child(supervisor, spec)
  end
end
