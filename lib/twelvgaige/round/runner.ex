defmodule Twelvgaige.Round.Runner do
  @moduledoc """
  Synchronous entry points for running and resuming rounds through the durable
  `Twelvgaige.Round.Server` state machine.
  """

  alias Twelvgaige.Round.{Server, Snapshot}
  alias Twelvgaige.Shell.Workflow

  @spec run(Workflow.t(), map(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Twelvgaige.Error.t()}
  def run(%Workflow{} = workflow, input, opts \\ []) when is_map(input) do
    Server.run_sync(workflow, input, durable_scheduler_opts(opts))
  end

  @spec recover(Workflow.t(), Snapshot.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Twelvgaige.Error.t()}
  def recover(%Workflow{} = workflow, %Snapshot{} = snapshot, opts \\ []) when is_list(opts) do
    Server.resume_sync(workflow, snapshot, durable_scheduler_opts(opts))
  end

  @spec approve_safety(Workflow.t(), Snapshot.t(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Twelvgaige.Error.t()}
  def approve_safety(%Workflow{} = workflow, %Snapshot{} = snapshot, shot_id, opts \\ [])
      when is_binary(shot_id) and is_list(opts) do
    Server.approve_safety_sync(workflow, snapshot, shot_id, durable_scheduler_opts(opts))
  end

  @spec reject_safety(Workflow.t(), Snapshot.t(), String.t(), keyword()) ::
          {:ok, Snapshot.t()} | {:error, Twelvgaige.Error.t()}
  def reject_safety(%Workflow{} = workflow, %Snapshot{} = snapshot, shot_id, opts \\ [])
      when is_binary(shot_id) and is_list(opts) do
    Server.reject_safety_sync(workflow, snapshot, shot_id, durable_scheduler_opts(opts))
  end

  defp durable_scheduler_opts(opts) do
    opts
    |> Keyword.put(:scheduler?, true)
    |> Keyword.put_new(:supervised?, false)
    |> Keyword.put_new(:stop_after_await?, true)
  end
end
