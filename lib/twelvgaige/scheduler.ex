defmodule Twelvgaige.Scheduler do
  @moduledoc """
  Optional scheduler for daemon-owned rounds.

  Jobs are explicit data, timers are owned by one GenServer, and execution goes through
  `Twelvgaige.Breech.start_round/3` so scheduled rounds use the same durable
  manifest, audit, resource, and recovery paths as manually-triggered rounds.
  """

  use GenServer

  alias Twelvgaige.Error
  alias Twelvgaige.Operations.Store, as: OperationsStore
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
      :misfire_policy,
      :overlap_policy,
      initial_delay_ms: nil,
      opts: []
    ]
  end

  defstruct [
    :runner,
    :breech,
    :now_fun,
    :store,
    :overlap_fun,
    jobs: %{},
    timers: %{},
    fired: %{},
    errors: %{},
    durable: %{},
    skipped: %{},
    max_catch_up: 10
  ]

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
      now_fun: Keyword.get(opts, :now_fun, &Twelvgaige.Clock.utc_now/0),
      store: Keyword.get(opts, :operations_store),
      overlap_fun: Keyword.get(opts, :overlap_fun, fn _job_id, _round_id -> false end),
      max_catch_up: Keyword.get(opts, :max_catch_up, 10)
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
          misfire_policy: job.misfire_policy,
          overlap_policy: job.overlap_policy,
          next_fire_at: get_in(state.durable, [job.id, :next_fire_at]),
          last_occurrence_id: get_in(state.durable, [job.id, :last_occurrence_id]),
          last_round_id: get_in(state.durable, [job.id, :last_round_id]),
          fired: Map.get(state.fired, job.id, 0),
          skipped: Map.get(state.skipped, job.id, 0),
          last_error: Map.get(state.errors, job.id)
        }
      end)

    {:reply, %{status: "running", jobs: jobs}, state}
  end

  @impl true
  def handle_info({:fire, job_id, scheduled_at}, state) do
    case Map.fetch(state.jobs, job_id) do
      {:ok, job} ->
        state =
          state
          |> update_in([Access.key!(:timers)], &Map.delete(&1, job_id))
          |> fire_occurrence(job, scheduled_at)

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
    misfire_policy = value(job, :misfire_policy, :fire_once)
    overlap_policy = value(job, :overlap_policy, :skip)
    opts = value(job, :opts, [])

    with :ok <- validate_base_job(id, workflow, input, opts),
         :ok <- validate_initial_delay(id, initial_delay_ms),
         :ok <- validate_policies(id, misfire_policy, overlap_policy),
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
         misfire_policy: misfire_policy,
         overlap_policy: overlap_policy,
         initial_delay_ms: initial_delay_ms,
         opts: opts
       }}
    end
  end

  defp normalize_job(_job),
    do: {:error, scheduler_error("scheduler job must be a map or keyword list")}

  defp schedule_initial_jobs(state, jobs) do
    Enum.reduce_while(jobs, {:ok, state}, fn job, {:ok, acc} ->
      acc = put_in(acc.jobs[job.id], job)

      with {:ok, acc} <- restore_job_state(acc, job),
           {:ok, scheduled_at, delay_ms, acc} <- initial_occurrence(acc, job) do
        acc = schedule_job(acc, job, scheduled_at, delay_ms)

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

  defp schedule_job(state, job, scheduled_at, delay_ms) do
    timer = Process.send_after(self(), {:fire, job.id, scheduled_at}, delay_ms)

    state
    |> put_in([Access.key!(:timers), job.id], timer)
    |> persist_job(job.id, %{next_fire_at: scheduled_at})
  end

  defp schedule_next_job(state, %Job{} = job, scheduled_at) do
    case next_occurrence(state, job, scheduled_at) do
      {:ok, next_at} ->
        {state, next_at} = maybe_advance_misfire(state, job, next_at)
        delay_ms = max(0, DateTime.diff(next_at, state.now_fun.(), :millisecond))
        schedule_job(state, job, next_at, delay_ms)

      {:error, reason} ->
        put_in(state.errors[job.id], inspect(reason))
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

  defp restore_job_state(%{store: nil} = state, _job), do: {:ok, state}

  defp restore_job_state(state, job) do
    expected_digest = job_digest(job)

    case OperationsStore.get(:automation_job, job.id, server: state.store) do
      {:ok, %{value: %{schedule_digest: ^expected_digest} = durable}} ->
        {:ok, put_in(state.durable[job.id], durable)}

      {:ok, _stale} ->
        {:ok, persist_job(state, job.id, %{schedule_digest: job_digest(job)})}

      {:error, :not_found} ->
        {:ok, persist_job(state, job.id, %{schedule_digest: job_digest(job)})}

      {:error, reason} ->
        {:error, {:scheduler_store_unavailable, reason}}
    end
  end

  defp initial_occurrence(state, job) do
    now = state.now_fun.()

    case get_in(state.durable, [job.id, :next_fire_at]) do
      %DateTime{} = scheduled_at ->
        initial_misfire(state, job, scheduled_at, now)

      nil ->
        with {:ok, delay_ms} <- initial_delay(state, job) do
          {:ok, DateTime.add(now, delay_ms, :millisecond), delay_ms, state}
        end
    end
  end

  defp initial_misfire(state, job, scheduled_at, now) do
    if DateTime.compare(scheduled_at, now) == :gt do
      {:ok, scheduled_at, DateTime.diff(scheduled_at, now, :millisecond), state}
    else
      case job.misfire_policy do
        :skip ->
          next_at = advance_until_future(state, job, scheduled_at)

          state =
            state
            |> update_in([Access.key!(:skipped), job.id], &((&1 || 0) + 1))
            |> persist_job(job.id, %{last_misfire: :skipped})

          {:ok, next_at, max(0, DateTime.diff(next_at, now, :millisecond)), state}

        policy when policy in [:fire_once, :catch_up] ->
          {:ok, scheduled_at, 0, state}
      end
    end
  end

  defp next_occurrence(_state, %Job{schedule: {:interval, interval_ms}}, scheduled_at),
    do: {:ok, DateTime.add(scheduled_at, interval_ms, :millisecond)}

  defp next_occurrence(_state, %Job{schedule: {:cron, cron}}, scheduled_at) do
    with {:ok, delay_ms} <- Cron.next_delay_ms(cron, DateTime.add(scheduled_at, 1, :millisecond)) do
      {:ok, DateTime.add(DateTime.add(scheduled_at, 1, :millisecond), delay_ms, :millisecond)}
    end
  end

  defp maybe_advance_misfire(state, job, next_at) do
    now = state.now_fun.()

    if DateTime.compare(next_at, now) == :gt do
      {persist_job(state, job.id, %{catch_up_count: 0}), next_at}
    else
      case job.misfire_policy do
        :catch_up ->
          count = get_in(state.durable, [job.id, :catch_up_count]) || 0

          if count < state.max_catch_up do
            {persist_job(state, job.id, %{catch_up_count: count + 1}), next_at}
          else
            {persist_job(state, job.id, %{catch_up_count: 0, last_misfire: :catch_up_bounded}),
             advance_until_future(state, job, next_at)}
          end

        _policy ->
          {state, advance_until_future(state, job, next_at)}
      end
    end
  end

  defp advance_until_future(state, job, scheduled_at) do
    now = state.now_fun.()
    do_advance_until_future(state, job, scheduled_at, now, 0)
  end

  defp do_advance_until_future(state, job, scheduled_at, now, count) do
    cond do
      DateTime.compare(scheduled_at, now) == :gt ->
        scheduled_at

      count >= 100_000 ->
        raise "scheduler misfire backlog is unbounded for #{job.id}"

      true ->
        case next_occurrence(state, job, scheduled_at) do
          {:ok, next_at} -> do_advance_until_future(state, job, next_at, now, count + 1)
          {:error, reason} -> raise "cannot advance scheduler occurrence: #{inspect(reason)}"
        end
    end
  end

  defp claim_occurrence(%{store: nil}, _occurrence_id, _job, _scheduled_at), do: :claimed

  defp claim_occurrence(state, occurrence_id, job, scheduled_at) do
    OperationsStore.claim_once(
      :automation_occurrence,
      occurrence_id,
      %{job_id: job.id, scheduled_at: scheduled_at},
      server: state.store
    )
  end

  defp persist_job(state, job_id, attrs) do
    durable = state.durable |> Map.get(job_id, %{}) |> Map.merge(attrs)

    if state.store do
      :ok =
        OperationsStore.put(:automation_job, job_id, durable,
          server: state.store,
          retention_class: :permanent
        )
    end

    put_in(state.durable[job_id], durable)
  end

  defp occurrence_id(job_id, scheduled_at),
    do: job_id <> ":" <> Integer.to_string(DateTime.to_unix(scheduled_at, :millisecond))

  defp job_digest(job) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary(
        {job.workflow, job.input, job.schedule, job.opts, job.misfire_policy, job.overlap_policy}
      )
    )
    |> Base.encode16(case: :lower)
  end

  defp fire_occurrence(state, %Job{} = job, scheduled_at) do
    durable = Map.get(state.durable, job.id, %{})
    last_round_id = Map.get(durable, :last_round_id)

    if state.overlap_fun.(job.id, last_round_id) do
      handle_overlap(state, job, scheduled_at)
    else
      execute_occurrence(state, job, scheduled_at)
    end
  end

  defp execute_occurrence(state, %Job{} = job, scheduled_at) do
    occurrence_id = occurrence_id(job.id, scheduled_at)

    case claim_occurrence(state, occurrence_id, job, scheduled_at) do
      :duplicate ->
        state
        |> update_in([Access.key!(:skipped), job.id], &((&1 || 0) + 1))
        |> schedule_next_job(job, scheduled_at)

      :claimed ->
        state
        |> run_claimed(job, occurrence_id, scheduled_at)
        |> schedule_next_job(job, scheduled_at)

      {:error, reason} ->
        put_in(state.errors[job.id], inspect(reason))
    end
  end

  defp run_claimed(state, %Job{} = job, occurrence_id, scheduled_at) do
    opts =
      job.opts
      |> Keyword.put_new(:server, state.breech)
      |> Keyword.put_new(:admission_policy, :scheduled)
      |> Keyword.put(:scheduler?, true)

    case state.runner.(job.workflow, job.input, opts) do
      {:ok, round_id} ->
        state
        |> update_in([Access.key!(:fired), job.id], &((&1 || 0) + 1))
        |> update_in([Access.key!(:errors)], &Map.delete(&1, job.id))
        |> persist_job(job.id, %{
          last_occurrence_id: occurrence_id,
          last_scheduled_at: scheduled_at,
          last_fired_at: state.now_fun.(),
          last_round_id: round_id
        })

      {:error, reason} ->
        put_in(state.errors[job.id], inspect(reason))
    end
  rescue
    error ->
      put_in(state.errors[job.id], Exception.message(error))
  end

  defp handle_overlap(state, %Job{overlap_policy: :allow} = job, scheduled_at),
    do: execute_occurrence(state, job, scheduled_at)

  defp handle_overlap(state, %Job{overlap_policy: :skip} = job, scheduled_at) do
    state
    |> update_in([Access.key!(:skipped), job.id], &((&1 || 0) + 1))
    |> persist_job(job.id, %{last_overlap: :skipped, last_scheduled_at: scheduled_at})
    |> schedule_next_job(job, scheduled_at)
  end

  defp handle_overlap(state, %Job{overlap_policy: :queue} = job, scheduled_at) do
    timer = Process.send_after(self(), {:fire, job.id, scheduled_at}, 1_000)
    put_in(state.timers[job.id], timer)
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

  defp validate_policies(_id, misfire, overlap)
       when misfire in [:skip, :fire_once, :catch_up] and overlap in [:skip, :queue, :allow],
       do: :ok

  defp validate_policies(id, _misfire, _overlap) do
    {:error,
     scheduler_error("scheduler job has an invalid misfire or overlap policy", %{job_id: id})}
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
        {:error, %{error | details: Map.put(error.details, :job_id, id)}}
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
