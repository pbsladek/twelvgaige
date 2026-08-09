defmodule Twelvgaige.ResourceLimiter do
  @moduledoc """
  Local in-VM resource admission for the laptop runtime profile.

  This limiter is deliberately small: it grants permits immediately by default
  and queues waiters only when callers explicitly opt in with `queue?: true`.
  Permit and waiter owners are monitored so held or queued resources are cleaned
  up if the owner process exits.
  """

  use GenServer

  alias Twelvgaige.RuntimeProfile

  defmodule Permit do
    @moduledoc """
    Token returned by `Twelvgaige.ResourceLimiter.acquire/3`.
    """

    @enforce_keys [:id, :resource_kind, :owner_pid, :acquired_at, :server]
    defstruct [
      :id,
      :resource_kind,
      :round_id,
      :shot_id,
      :attempt,
      :owner_pid,
      :bytes,
      :acquired_at,
      :server
    ]

    @type t :: %__MODULE__{
            id: pos_integer(),
            resource_kind: Twelvgaige.ResourceLimiter.resource_kind(),
            round_id: String.t() | nil,
            shot_id: String.t() | nil,
            attempt: non_neg_integer() | nil,
            owner_pid: pid(),
            bytes: non_neg_integer() | nil,
            acquired_at: integer(),
            server: GenServer.server()
          }
  end

  defmodule Waiter do
    @moduledoc false

    @enforce_keys [:id, :resource_kind, :owner_pid, :queued_at, :server]
    defstruct [
      :id,
      :resource_kind,
      :round_id,
      :shot_id,
      :attempt,
      :owner_pid,
      :queued_at,
      :queue_timeout_ms,
      :server
    ]

    @type t :: %__MODULE__{
            id: pos_integer(),
            resource_kind: Twelvgaige.ResourceLimiter.resource_kind(),
            round_id: String.t() | nil,
            shot_id: String.t() | nil,
            attempt: non_neg_integer() | nil,
            owner_pid: pid(),
            queued_at: integer(),
            queue_timeout_ms: non_neg_integer() | nil,
            server: GenServer.server()
          }
  end

  @type resource_kind ::
          :active_round
          | :active_shot
          | :running_shot_global
          | :running_shot_per_round
          | :llm_call
          | :tool_exec
          | :tool_call
          | {:tool_call, String.t()}
          | :retained_bytes

  @type reason ::
          {:limit_exceeded, atom()}
          | {:unknown_resource_kind, term()}
          | :invalid_bytes
          | :invalid_owner_pid
          | :invalid_queue_timeout
          | :round_id_required
          | :unknown_permit
          | :permit_mismatch

  @default_limits RuntimeProfile.limits(:laptop)

  defstruct profile: :laptop,
            metrics: Twelvgaige.Metrics,
            limits: @default_limits,
            used: %{
              active_round: 0,
              active_shot: 0,
              llm_call: 0,
              tool_exec: 0,
              retained_bytes: 0
            },
            per_round: %{active_shot: %{}},
            permits: %{},
            owner_refs: %{},
            ref_owners: %{},
            owner_permits: %{},
            owner_waiters: %{},
            waiters: %{},
            last_served_round: %{},
            denials: %{}

  @doc """
  Starts the local resource limiter.

  Options:

    * `:name` - registered name, defaults to this module.
    * `:profile` - one of `:minimal`, `:laptop`, `:workstation`, or `:server`.
    * `:limits` - map or keyword overrides for tests.
    * `:metrics` - metrics collector, defaults to `Twelvgaige.Metrics`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name) do
      GenServer.start_link(__MODULE__, opts)
    else
      GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @doc """
  Acquires a permit immediately. When `queue?: true` is passed and a known
  resource is saturated, returns a waiter and later sends one of these messages
  to the waiter owner:

    * `{:resource_granted, waiter_id, permit}`
    * `{:resource_timeout, waiter_id, resource_kind}`

  `queue_timeout_ms` is separate from execution timeout. If omitted, the waiter
  can remain queued until capacity appears, owner death, or explicit cancel.
  """
  @spec acquire(resource_kind(), map() | keyword()) ::
          {:ok, Permit.t()} | {:queued, Waiter.t()} | {:error, reason()}
  @spec acquire(resource_kind(), map(), keyword()) ::
          {:ok, Permit.t()} | {:queued, Waiter.t()} | {:error, reason()}
  def acquire(resource_kind, context \\ %{}, opts \\ [])

  def acquire(resource_kind, opts, []) when is_list(opts) do
    acquire(resource_kind, %{}, opts)
  end

  def acquire(resource_kind, context, opts) when is_map(context) and is_list(opts) do
    server = Keyword.get(opts, :server, __MODULE__)
    owner_pid = Keyword.get(opts, :owner_pid, Keyword.get(opts, :owner, self()))

    GenServer.call(server, {:acquire, resource_kind, context, owner_pid, opts})
  end

  @doc """
  Releases the exact permit token returned by `acquire/3`.
  """
  @spec release(Permit.t()) :: :ok | {:error, reason()}
  def release(%Permit{server: server} = permit) do
    GenServer.call(server, {:release, permit})
  end

  @doc """
  Cancels a queued waiter. Cancellation is idempotent.
  """
  @spec cancel_waiter(Waiter.t() | term()) :: :ok
  def cancel_waiter(%Waiter{server: server} = waiter) do
    GenServer.call(server, {:cancel_waiter, waiter})
  end

  def cancel_waiter(waiter_id) do
    GenServer.call(__MODULE__, {:cancel_waiter, waiter_id})
  end

  @doc """
  Returns current limiter state for focused tests.
  """
  @spec snapshot(GenServer.server()) :: map()
  def snapshot(server \\ __MODULE__) do
    GenServer.call(server, :snapshot)
  end

  @impl true
  def init(opts) do
    profile = Keyword.get(opts, :profile, RuntimeProfile.default())

    with {:ok, profile} <- RuntimeProfile.normalize(profile) do
      {:ok,
       %__MODULE__{
         profile: profile,
         metrics: Keyword.get(opts, :metrics, Twelvgaige.Metrics),
         limits: build_limits(profile, Keyword.get(opts, :limits, %{}))
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:acquire, resource_kind, context, owner_pid, opts}, _from, state) do
    with :ok <- validate_owner(owner_pid),
         {:ok, bytes} <- permit_bytes(resource_kind, context, opts),
         {:ok, queue_timeout_ms} <- queue_timeout_ms(context, opts),
         {:ok, targets} <- targets(resource_kind, context, bytes) do
      acquire_or_queue(
        resource_kind,
        context,
        owner_pid,
        bytes,
        targets,
        queue_timeout_ms,
        opts,
        state
      )
    else
      {:error, reason} ->
        {:reply, {:error, reason}, record_denial(state, resource_kind, reason)}
    end
  end

  @impl true
  def handle_call({:release, %Permit{} = permit}, _from, state) do
    case Map.fetch(state.permits, permit.id) do
      {:ok, %{permit: ^permit} = entry} ->
        state =
          entry
          |> drop_permit(state)
          |> notify_eligible_waiters()

        {:reply, :ok, state}

      {:ok, _entry} ->
        {:reply, {:error, :permit_mismatch}, state}

      :error ->
        {:reply, {:error, :unknown_permit}, state}
    end
  end

  @impl true
  def handle_call({:cancel_waiter, waiter}, _from, state) do
    waiter_id = waiter_id(waiter)
    state = observe_waiter_drop(waiter_id, :cancelled, state)

    state =
      waiter_id
      |> drop_waiter(state)
      |> notify_eligible_waiters()

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:snapshot, _from, state) do
    permits =
      state.permits
      |> Map.values()
      |> Enum.map(& &1.permit)

    snapshot = %{
      profile: state.profile,
      limits: state.limits,
      used: state.used,
      per_round: state.per_round,
      permits: permits,
      queue_depth: queue_depth(state),
      denials: denial_snapshot(state.denials)
    }

    {:reply, snapshot, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, owner_pid, _reason}, state) do
    case Map.fetch(state.ref_owners, ref) do
      {:ok, ^owner_pid} ->
        permit_ids = Map.get(state.owner_permits, owner_pid, MapSet.new())

        state =
          permit_ids
          |> Enum.reduce(state, fn permit_id, acc ->
            case Map.fetch(acc.permits, permit_id) do
              {:ok, entry} -> drop_permit(entry, acc, demonitor?: false)
              :error -> acc
            end
          end)
          |> drop_owner_waiters(owner_pid, demonitor?: false, queue_status: :owner_down)
          |> forget_owner(owner_pid)
          |> notify_eligible_waiters()

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:waiter_timeout, waiter_id}, state) do
    case Map.fetch(state.waiters, waiter_id) do
      {:ok, %{waiter: waiter}} ->
        send(waiter.owner_pid, {:resource_timeout, waiter.id, waiter.resource_kind})

        state = observe_waiter_drop(waiter_id, :timeout, state)

        state =
          waiter_id
          |> drop_waiter(state, cancel_timer?: false)
          |> record_denial(waiter.resource_kind, :queue_timeout)
          |> notify_eligible_waiters()

        {:noreply, state}

      :error ->
        {:noreply, state}
    end
  end

  defp acquire_or_queue(
         resource_kind,
         context,
         owner_pid,
         bytes,
         targets,
         queue_timeout_ms,
         opts,
         state
       ) do
    case ensure_available(targets, state) do
      :ok ->
        grant_permit(resource_kind, context, owner_pid, bytes, targets, state)

      {:error, {:limit_exceeded, _limited_resource} = reason} ->
        if Keyword.get(opts, :queue?, false) and queueable?(resource_kind) do
          queue_waiter(resource_kind, context, owner_pid, targets, queue_timeout_ms, state)
        else
          {:reply, {:error, reason}, record_denial(state, resource_kind, reason)}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, record_denial(state, resource_kind, reason)}
    end
  end

  defp grant_permit(resource_kind, context, owner_pid, bytes, targets, state) do
    {state, owner_pid} = monitor_owner(owner_pid, state)
    permit = build_permit(resource_kind, context, owner_pid, bytes)
    state = put_permit(permit, targets, state)

    {:reply, {:ok, permit}, state}
  end

  defp queue_waiter(resource_kind, context, owner_pid, targets, queue_timeout_ms, state) do
    {state, owner_pid} = monitor_owner(owner_pid, state)
    waiter = build_waiter(resource_kind, context, owner_pid, queue_timeout_ms)
    state = put_waiter(waiter, targets, state)
    state = record_queue_enter(waiter, state)

    {:reply, {:queued, waiter}, state}
  end

  defp build_limits(profile, overrides), do: RuntimeProfile.limits(profile, overrides)

  defp normalize_limit_key(:running_shot_global), do: :active_shot
  defp normalize_limit_key(:running_shot_per_round), do: :active_shot_per_round
  defp normalize_limit_key(:tool_call), do: :tool_exec
  defp normalize_limit_key(key), do: key

  defp validate_owner(owner_pid) when is_pid(owner_pid), do: :ok
  defp validate_owner(_owner_pid), do: {:error, :invalid_owner_pid}

  defp permit_bytes(:retained_bytes, context, opts) do
    bytes =
      case value(context, :bytes, :missing) do
        :missing -> Keyword.get(opts, :bytes, 0)
        value -> value
      end

    if is_integer(bytes) and bytes >= 0 do
      {:ok, bytes}
    else
      {:error, :invalid_bytes}
    end
  end

  defp permit_bytes(_resource_kind, context, opts) do
    bytes =
      case value(context, :bytes, :missing) do
        :missing -> Keyword.get(opts, :bytes)
        value -> value
      end

    if is_nil(bytes) or (is_integer(bytes) and bytes >= 0) do
      {:ok, bytes}
    else
      {:error, :invalid_bytes}
    end
  end

  defp queue_timeout_ms(context, opts) do
    timeout_ms =
      case value(context, :queue_timeout_ms, :missing) do
        :missing -> Keyword.get(opts, :queue_timeout_ms)
        value -> value
      end

    cond do
      is_nil(timeout_ms) -> {:ok, nil}
      is_integer(timeout_ms) and timeout_ms >= 0 -> {:ok, timeout_ms}
      true -> {:error, :invalid_queue_timeout}
    end
  end

  defp targets(:active_round, _context, _bytes) do
    {:ok, [{:global, :active_round, 1}]}
  end

  defp targets(:active_shot, context, _bytes) do
    targets = [{:global, :active_shot, 1}]

    case round_id(context) do
      nil -> {:ok, targets}
      round_id -> {:ok, [{:per_round, :active_shot, round_id, 1} | targets]}
    end
  end

  defp targets(:running_shot_global, _context, _bytes) do
    {:ok, [{:global, :active_shot, 1}]}
  end

  defp targets(:running_shot_per_round, context, _bytes) do
    case round_id(context) do
      nil -> {:error, :round_id_required}
      round_id -> {:ok, [{:per_round, :active_shot, round_id, 1}]}
    end
  end

  defp targets(:llm_call, _context, _bytes) do
    {:ok, [{:global, :llm_call, 1}]}
  end

  defp targets(resource_kind, _context, _bytes) when resource_kind in [:tool_exec, :tool_call] do
    {:ok, [{:global, :tool_exec, 1}]}
  end

  defp targets({:tool_call, tool_name}, _context, _bytes) when is_binary(tool_name) do
    {:ok, [{:global, :tool_exec, 1}]}
  end

  defp targets(:retained_bytes, _context, bytes) do
    {:ok, [{:global, :retained_bytes, bytes}]}
  end

  defp targets(resource_kind, _context, _bytes) do
    {:error, {:unknown_resource_kind, resource_kind}}
  end

  defp ensure_available(targets, state) do
    Enum.reduce_while(targets, :ok, fn
      {:global, key, amount}, :ok ->
        if Map.fetch!(state.used, key) + amount <= Map.fetch!(state.limits, key) do
          {:cont, :ok}
        else
          {:halt, {:error, {:limit_exceeded, key}}}
        end

      {:per_round, :active_shot, round_id, amount}, :ok ->
        current =
          state.per_round
          |> Map.fetch!(:active_shot)
          |> Map.get(round_id, 0)

        if current + amount <= Map.fetch!(state.limits, :active_shot_per_round) do
          {:cont, :ok}
        else
          {:halt, {:error, {:limit_exceeded, :active_shot_per_round}}}
        end
    end)
  end

  defp record_denial(state, resource_kind, reason) do
    key = {metric_resource_kind(resource_kind, reason), denial_reason(reason)}
    update_in(state.denials, &Map.update(&1, key, 1, fn count -> count + 1 end))
  end

  defp metric_resource_kind(_resource_kind, {:limit_exceeded, resource_kind}), do: resource_kind
  defp metric_resource_kind(resource_kind, _reason), do: normalize_limit_key(resource_kind)

  defp denial_reason({:limit_exceeded, _resource_kind}), do: :limit_exceeded
  defp denial_reason({:unknown_resource_kind, _resource_kind}), do: :unknown_resource_kind
  defp denial_reason(:queue_timeout), do: :queue_timeout
  defp denial_reason(reason), do: reason

  defp denial_snapshot(denials) do
    denials
    |> Enum.map(fn {{resource_kind, reason}, count} ->
      %{resource_kind: resource_kind, reason: reason, count: count}
    end)
    |> Enum.sort_by(&{to_string(&1.resource_kind), to_string(&1.reason)})
  end

  defp queue_depth(state) do
    state.waiters
    |> Map.values()
    |> Enum.reduce(empty_queue_depth(), fn %{waiter: waiter}, depths ->
      Map.update!(depths, queue_key(waiter.resource_kind), &(&1 + 1))
    end)
  end

  defp empty_queue_depth do
    %{
      active_round: 0,
      active_shot: 0,
      llm_call: 0,
      tool_exec: 0,
      retained_bytes: 0
    }
  end

  defp queueable?(resource_kind) do
    queue_key(resource_kind) in [:active_round, :active_shot, :llm_call, :tool_exec]
  end

  defp build_waiter(resource_kind, context, owner_pid, queue_timeout_ms) do
    %Waiter{
      id: System.unique_integer([:positive, :monotonic]),
      resource_kind: resource_kind,
      round_id: round_id(context),
      shot_id: value(context, :shot_id),
      attempt: value(context, :attempt),
      owner_pid: owner_pid,
      queued_at: System.monotonic_time(:millisecond),
      queue_timeout_ms: queue_timeout_ms,
      server: self()
    }
  end

  defp put_waiter(%Waiter{} = waiter, targets, state) do
    entry = %{waiter: waiter, targets: targets, timer_ref: waiter_timer(waiter)}

    %{
      state
      | waiters: Map.put(state.waiters, waiter.id, entry),
        owner_waiters:
          Map.update(state.owner_waiters, waiter.owner_pid, MapSet.new([waiter.id]), fn waiters ->
            MapSet.put(waiters, waiter.id)
          end)
    }
  end

  defp record_queue_enter(%Waiter{} = waiter, state) do
    Twelvgaige.Metrics.counter(
      "twelvgaige_resource_queue_total",
      %{profile: state.profile, resource_kind: queue_key(waiter.resource_kind)},
      1,
      metrics: state.metrics
    )

    state
  end

  defp waiter_id(%Waiter{id: waiter_id}), do: waiter_id
  defp waiter_id(waiter_id), do: waiter_id

  defp drop_waiter(waiter_id, state, opts \\ [])
  defp drop_waiter(nil, state, _opts), do: state

  defp drop_waiter(waiter_id, state, opts) do
    case Map.fetch(state.waiters, waiter_id) do
      {:ok, %{waiter: waiter} = entry} ->
        if Keyword.get(opts, :cancel_timer?, true) do
          cancel_waiter_timer(entry)
        end

        state = %{
          state
          | waiters: Map.delete(state.waiters, waiter_id),
            owner_waiters:
              Map.update(
                state.owner_waiters,
                waiter.owner_pid,
                MapSet.new(),
                &MapSet.delete(&1, waiter_id)
              )
        }

        maybe_forget_owner(state, waiter.owner_pid, Keyword.get(opts, :demonitor?, true))

      :error ->
        state
    end
  end

  defp observe_waiter_drop(waiter_id, status, state) do
    case Map.fetch(state.waiters, waiter_id) do
      {:ok, %{waiter: waiter}} ->
        Twelvgaige.Metrics.observe(
          "twelvgaige_resource_queue_seconds",
          max(System.monotonic_time(:millisecond) - waiter.queued_at, 0) / 1000,
          %{
            profile: state.profile,
            resource_kind: queue_key(waiter.resource_kind),
            status: status
          },
          metrics: state.metrics
        )

        state

      :error ->
        state
    end
  end

  defp waiter_timer(%Waiter{queue_timeout_ms: nil}), do: nil

  defp waiter_timer(%Waiter{id: waiter_id, queue_timeout_ms: queue_timeout_ms}) do
    Process.send_after(self(), {:waiter_timeout, waiter_id}, queue_timeout_ms)
  end

  defp cancel_waiter_timer(%{timer_ref: nil}), do: :ok

  defp cancel_waiter_timer(%{timer_ref: timer_ref}) do
    _ = Process.cancel_timer(timer_ref)
    :ok
  end

  defp drop_owner_waiters(state, owner_pid, opts) do
    status = Keyword.get(opts, :queue_status, :cancelled)

    state.owner_waiters
    |> Map.get(owner_pid, MapSet.new())
    |> Enum.reduce(state, fn waiter_id, acc ->
      acc = observe_waiter_drop(waiter_id, status, acc)
      drop_waiter(waiter_id, acc, opts)
    end)
  end

  defp notify_eligible_waiters(state) do
    case next_eligible_waiter(state) do
      nil ->
        state

      {waiter_id, %{waiter: waiter} = entry} ->
        queue_key = queue_key(waiter.resource_kind)
        round_key = waiter_round_key(waiter)
        state = observe_waiter_drop(waiter_id, :granted, state)

        {state, permit} = promote_waiter(waiter_id, entry, state)
        state = Map.update!(state, :last_served_round, &Map.put(&1, queue_key, round_key))

        send(waiter.owner_pid, {:resource_granted, waiter.id, permit})
        notify_eligible_waiters(state)
    end
  end

  defp promote_waiter(waiter_id, %{waiter: waiter, targets: targets} = entry, state) do
    cancel_waiter_timer(entry)

    state = %{
      state
      | waiters: Map.delete(state.waiters, waiter_id),
        owner_waiters:
          Map.update!(state.owner_waiters, waiter.owner_pid, &MapSet.delete(&1, waiter_id))
    }

    context = %{
      round_id: waiter.round_id,
      shot_id: waiter.shot_id,
      attempt: waiter.attempt
    }

    permit = build_permit(waiter.resource_kind, context, waiter.owner_pid, nil)
    {put_permit(permit, targets, state), permit}
  end

  defp next_eligible_waiter(state) do
    state.waiters
    |> Enum.filter(fn {_waiter_id, %{targets: targets}} ->
      ensure_available(targets, state) == :ok
    end)
    |> Enum.group_by(fn {_waiter_id, %{waiter: waiter}} -> queue_key(waiter.resource_kind) end)
    |> Enum.map(fn {queue_key, waiters} -> next_waiter_for_queue(queue_key, waiters, state) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.min_by(fn {_waiter_id, %{waiter: waiter}} -> waiter.queued_at end, fn -> nil end)
  end

  defp next_waiter_for_queue(:active_round, waiters, _state), do: oldest_waiter(waiters)

  defp next_waiter_for_queue(queue_key, waiters, state)
       when queue_key in [:active_shot, :llm_call, :tool_exec] do
    grouped =
      Enum.group_by(waiters, fn {_waiter_id, %{waiter: waiter}} -> waiter_round_key(waiter) end)

    ordered_rounds =
      grouped
      |> Enum.map(fn {round_key, round_waiters} ->
        {round_key, round_waiters |> oldest_waiter() |> queued_at()}
      end)
      |> Enum.sort_by(fn {_round_key, queued_at} -> queued_at end)
      |> Enum.map(&elem(&1, 0))

    case next_round_key(ordered_rounds, Map.get(state.last_served_round, queue_key)) do
      nil -> nil
      round_key -> oldest_waiter(Map.fetch!(grouped, round_key))
    end
  end

  defp next_waiter_for_queue(_queue_key, waiters, _state), do: oldest_waiter(waiters)

  defp oldest_waiter([]), do: nil

  defp oldest_waiter(waiters) do
    Enum.min_by(waiters, fn {_waiter_id, %{waiter: waiter}} -> waiter.queued_at end)
  end

  defp queued_at(nil), do: 0
  defp queued_at({_waiter_id, %{waiter: waiter}}), do: waiter.queued_at

  defp next_round_key([], _last_round_key), do: nil
  defp next_round_key(round_keys, nil), do: hd(round_keys)

  defp next_round_key(round_keys, last_round_key) do
    case Enum.find_index(round_keys, &(&1 == last_round_key)) do
      nil -> hd(round_keys)
      index -> Enum.at(round_keys, index + 1) || hd(round_keys)
    end
  end

  defp waiter_round_key(%Waiter{round_id: round_id}) when is_binary(round_id), do: round_id
  defp waiter_round_key(%Waiter{}), do: :unscoped

  defp queue_key(:active_round), do: :active_round
  defp queue_key(:active_shot), do: :active_shot
  defp queue_key(:running_shot_global), do: :active_shot
  defp queue_key(:running_shot_per_round), do: :active_shot
  defp queue_key(:llm_call), do: :llm_call
  defp queue_key(:tool_exec), do: :tool_exec
  defp queue_key(:tool_call), do: :tool_exec
  defp queue_key({:tool_call, _tool_name}), do: :tool_exec
  defp queue_key(:retained_bytes), do: :retained_bytes
  defp queue_key(resource_kind), do: normalize_limit_key(resource_kind)

  defp monitor_owner(owner_pid, state) do
    case Map.fetch(state.owner_refs, owner_pid) do
      {:ok, _ref} ->
        {state, owner_pid}

      :error ->
        ref = Process.monitor(owner_pid)

        state = %{
          state
          | owner_refs: Map.put(state.owner_refs, owner_pid, ref),
            ref_owners: Map.put(state.ref_owners, ref, owner_pid),
            owner_permits: Map.put_new(state.owner_permits, owner_pid, MapSet.new()),
            owner_waiters: Map.put_new(state.owner_waiters, owner_pid, MapSet.new())
        }

        {state, owner_pid}
    end
  end

  defp build_permit(resource_kind, context, owner_pid, bytes) do
    %Permit{
      id: System.unique_integer([:positive, :monotonic]),
      resource_kind: resource_kind,
      round_id: round_id(context),
      shot_id: value(context, :shot_id),
      attempt: value(context, :attempt),
      owner_pid: owner_pid,
      bytes: bytes,
      acquired_at: System.monotonic_time(:millisecond),
      server: self()
    }
  end

  defp put_permit(%Permit{} = permit, targets, state) do
    entry = %{permit: permit, targets: targets}

    %{
      state
      | used: apply_targets(state.used, targets, 1),
        per_round: apply_per_round_targets(state.per_round, targets, 1),
        permits: Map.put(state.permits, permit.id, entry),
        owner_permits:
          Map.update!(state.owner_permits, permit.owner_pid, &MapSet.put(&1, permit.id))
    }
  end

  defp drop_permit(entry, state, opts \\ []) do
    demonitor? = Keyword.get(opts, :demonitor?, true)
    permit = entry.permit

    state = %{
      state
      | used: apply_targets(state.used, entry.targets, -1),
        per_round: apply_per_round_targets(state.per_round, entry.targets, -1),
        permits: Map.delete(state.permits, permit.id),
        owner_permits:
          Map.update(
            state.owner_permits,
            permit.owner_pid,
            MapSet.new(),
            &MapSet.delete(&1, permit.id)
          )
    }

    maybe_forget_owner(state, permit.owner_pid, demonitor?)
  end

  defp maybe_forget_owner(state, owner_pid, demonitor?) do
    permit_count =
      state.owner_permits
      |> Map.get(owner_pid, MapSet.new())
      |> MapSet.size()

    waiter_count =
      state.owner_waiters
      |> Map.get(owner_pid, MapSet.new())
      |> MapSet.size()

    if permit_count == 0 and waiter_count == 0 do
      if demonitor? do
        state.owner_refs
        |> Map.get(owner_pid)
        |> demonitor()
      end

      forget_owner(state, owner_pid)
    else
      state
    end
  end

  defp forget_owner(state, owner_pid) do
    {ref, owner_refs} = Map.pop(state.owner_refs, owner_pid)

    %{
      state
      | owner_refs: owner_refs,
        ref_owners: if(ref, do: Map.delete(state.ref_owners, ref), else: state.ref_owners),
        owner_permits: Map.delete(state.owner_permits, owner_pid),
        owner_waiters: Map.delete(state.owner_waiters, owner_pid)
    }
  end

  defp demonitor(nil), do: :ok

  defp demonitor(ref) do
    Process.demonitor(ref, [:flush])
    :ok
  end

  defp apply_targets(used, targets, direction) do
    Enum.reduce(targets, used, fn
      {:global, key, amount}, acc -> Map.update!(acc, key, &(&1 + direction * amount))
      {:per_round, _key, _round_id, _amount}, acc -> acc
    end)
  end

  defp apply_per_round_targets(per_round, targets, direction) do
    Enum.reduce(targets, per_round, fn
      {:per_round, key, round_id, amount}, acc ->
        update_in(acc, [key], fn counts ->
          counts
          |> Map.update(round_id, direction * amount, &(&1 + direction * amount))
          |> Enum.reject(fn {_round_id, count} -> count == 0 end)
          |> Map.new()
        end)

      {:global, _key, _amount}, acc ->
        acc
    end)
  end

  defp round_id(context), do: value(context, :round_id)

  defp value(context, key, default \\ nil) do
    cond do
      Map.has_key?(context, key) -> Map.fetch!(context, key)
      Map.has_key?(context, Atom.to_string(key)) -> Map.fetch!(context, Atom.to_string(key))
      true -> default
    end
  end
end
