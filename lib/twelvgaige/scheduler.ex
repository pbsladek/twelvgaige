defmodule Twelvgaige.Scheduler do
  @moduledoc """
  Optional scheduler for daemon-owned rounds.

  Jobs are explicit data, timers are owned by one GenServer, and execution goes through
  `Twelvgaige.Breech.start_round/3` so scheduled rounds use the same durable
  manifest, audit, resource, and recovery paths as manually-triggered rounds.
  """

  use GenServer

  alias Twelvgaige.Error
  alias Twelvgaige.Scheduler.Cron

  defmodule Job do
    @moduledoc false

    @enforce_keys [:id, :workflow, :input, :schedule]
    defstruct [
      :id,
      :workflow,
      :input,
      :schedule,
      :interval_ms,
      :cron,
      initial_delay_ms: nil,
      opts: []
    ]
  end

  defstruct [:runner, :breech, :now_fun, jobs: %{}, timers: %{}, fired: %{}, errors: %{}]

  @type job :: %Job{}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      runner: Keyword.get(opts, :runner, &Twelvgaige.Breech.start_round/3),
      breech: Keyword.get(opts, :breech, Twelvgaige.Breech),
      now_fun: Keyword.get(opts, :now_fun, &Twelvgaige.Clock.utc_now/0)
    }

    with {:ok, jobs} <- normalize_jobs(Keyword.get(opts, :jobs, [])) do
      schedule_initial_jobs(state, jobs)
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    jobs =
      state.jobs
      |> Map.values()
      |> Enum.map(fn job ->
        %{
          id: job.id,
          schedule: schedule_name(job.schedule),
          interval_ms: job.interval_ms,
          cron: cron_expression(job.cron),
          fired: Map.get(state.fired, job.id, 0),
          last_error: Map.get(state.errors, job.id)
        }
      end)

    {:reply, %{status: "running", jobs: jobs}, state}
  end

  @impl true
  def handle_info({:fire, job_id}, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        state =
          state
          |> update_in([Access.key!(:timers)], &Map.delete(&1, job_id))
          |> fire_job(job)
          |> schedule_next_job(job)

        {:noreply, state}

      :error ->
        {:noreply, update_in(state.timers, &Map.delete(&1, job_id))}
    end
  end

  defp normalize_jobs(jobs) when is_list(jobs) do
    jobs
    |> Enum.reduce_while({:ok, []}, fn job, {:ok, acc} ->
      case normalize_job(job) do
        {:ok, job} -> {:cont, {:ok, [job | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, jobs} -> {:ok, Enum.reverse(jobs)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_jobs(_jobs), do: {:error, scheduler_error("scheduler jobs must be a list")}

  defp normalize_job(%Job{} = job), do: {:ok, job}

  defp normalize_job(job) when is_list(job) do
    job
    |> Map.new()
    |> normalize_job()
  end

  defp normalize_job(%{} = job) do
    id = value_lazy(job, :id, fn -> "schedule_#{System.unique_integer([:positive])}" end)
    workflow = value(job, :workflow, value(job, :workflow_path, nil))
    input = value(job, :input, %{})
    interval_ms = value(job, :interval_ms, value(job, :every_ms, nil))
    cron_expression = value(job, :cron, nil)
    initial_delay_ms = value(job, :initial_delay_ms, nil)
    opts = value(job, :opts, [])

    with :ok <- validate_base_job(id, workflow, input, opts),
         :ok <- validate_initial_delay(id, initial_delay_ms),
         {:ok, schedule, interval_ms, cron} <-
           normalize_schedule(id, interval_ms, cron_expression) do
      {:ok,
       %Job{
         id: id,
         workflow: workflow,
         input: input,
         schedule: schedule,
         interval_ms: interval_ms,
         cron: cron,
         initial_delay_ms: initial_delay_ms,
         opts: opts
       }}
    end
  end

  defp normalize_job(_job),
    do: {:error, scheduler_error("scheduler job must be a map or keyword list")}

  defp schedule_initial_jobs(state, jobs) do
    Enum.reduce_while(jobs, {:ok, state}, fn job, {:ok, acc} ->
      with {:ok, delay_ms} <- initial_delay(acc, job) do
        acc =
          acc
          |> put_in([Access.key!(:jobs), job.id], job)
          |> schedule_job(job, delay_ms)

        {:cont, {:ok, acc}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:stop, reason}
    end
  end

  defp schedule_job(state, job, delay_ms) do
    timer = Process.send_after(self(), {:fire, job.id}, delay_ms)
    put_in(state.timers[job.id], timer)
  end

  defp schedule_next_job(state, %Job{} = job) do
    case next_delay(state, job) do
      {:ok, delay_ms} -> schedule_job(state, job, delay_ms)
      {:error, reason} -> put_in(state.errors[job.id], inspect(reason))
    end
  end

  defp initial_delay(_state, %Job{schedule: {:interval, _ms}, initial_delay_ms: delay_ms})
       when is_integer(delay_ms),
       do: {:ok, delay_ms}

  defp initial_delay(state, %Job{schedule: {:interval, _interval_ms}} = job) do
    if is_nil(job.initial_delay_ms), do: {:ok, 0}, else: next_delay(state, job)
  end

  defp initial_delay(state, %Job{schedule: {:cron, _cron}} = job), do: next_delay(state, job)

  defp next_delay(_state, %Job{schedule: {:interval, interval_ms}}), do: {:ok, interval_ms}

  defp next_delay(state, %Job{schedule: {:cron, cron}}),
    do: Cron.next_delay_ms(cron, state.now_fun.())

  defp fire_job(state, %Job{} = job) do
    opts =
      job.opts
      |> Keyword.put_new(:server, state.breech)
      |> Keyword.put(:scheduler?, true)

    case state.runner.(job.workflow, job.input, opts) do
      {:ok, _round_id} ->
        state
        |> update_in([Access.key!(:fired), job.id], &((&1 || 0) + 1))
        |> update_in([Access.key!(:errors)], &Map.delete(&1, job.id))

      {:error, reason} ->
        put_in(state.errors[job.id], inspect(reason))
    end
  rescue
    error ->
      put_in(state.errors[job.id], Exception.message(error))
  end

  defp scheduler_error(message, details \\ %{}) do
    Error.new(:input_error, :invalid_shell, message, details: details)
  end

  defp validate_base_job(id, workflow, input, opts) do
    cond do
      not is_binary(id) or id == "" ->
        {:error, scheduler_error("scheduler job id must be a non-empty string")}

      is_nil(workflow) ->
        {:error, scheduler_error("scheduler job workflow is required", %{job_id: id})}

      not is_map(input) ->
        {:error, scheduler_error("scheduler job input must be a map", %{job_id: id})}

      not is_list(opts) ->
        {:error, scheduler_error("scheduler job opts must be a keyword list", %{job_id: id})}

      true ->
        :ok
    end
  end

  defp validate_initial_delay(_id, nil), do: :ok

  defp validate_initial_delay(_id, initial_delay_ms)
       when is_integer(initial_delay_ms) and initial_delay_ms >= 0 do
    :ok
  end

  defp validate_initial_delay(id, _initial_delay_ms) do
    {:error,
     scheduler_error("scheduler job initial_delay_ms must be non-negative", %{job_id: id})}
  end

  defp normalize_schedule(id, interval_ms, nil) do
    if is_integer(interval_ms) and interval_ms > 0 do
      {:ok, {:interval, interval_ms}, interval_ms, nil}
    else
      {:error, scheduler_error("scheduler job interval_ms must be positive", %{job_id: id})}
    end
  end

  defp normalize_schedule(id, nil, cron_expression) do
    with {:ok, cron} <- Cron.parse(cron_expression) do
      {:ok, {:cron, cron}, nil, cron}
    else
      {:error, %Error{} = error} ->
        {:error, %{error | details: Map.put(error.details || %{}, :job_id, id)}}
    end
  end

  defp normalize_schedule(id, _interval_ms, _cron_expression) do
    {:error,
     scheduler_error("scheduler job must set either interval_ms or cron, not both", %{job_id: id})}
  end

  defp schedule_name({:interval, _ms}), do: "interval"
  defp schedule_name({:cron, _cron}), do: "cron"

  defp cron_expression(%Cron{expression: expression}), do: expression
  defp cron_expression(nil), do: nil

  defp value(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value_lazy(%{} = map, key, fun) when is_function(fun, 0) do
    Map.get_lazy(map, key, fn -> Map.get_lazy(map, Atom.to_string(key), fun) end)
  end
end
