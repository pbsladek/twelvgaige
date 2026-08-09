defmodule Twelvgaige.Manager.Executor do
  @moduledoc "Provider-neutral dispatch for supported governed manager children."

  alias Twelvgaige.Manager.ChildRecord
  alias Twelvgaige.Manager.Executor.Codex

  def run(%ChildRecord{task: %{agent: "codex"}} = child, opts), do: Codex.run(child, opts)

  def run(%ChildRecord{task: %{agent: agent}}, _opts),
    do: {:error, {:manager_executor_agent_unsupported, agent}}
end
