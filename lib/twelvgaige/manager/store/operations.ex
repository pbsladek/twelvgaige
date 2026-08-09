defmodule Twelvgaige.Manager.Store.Operations do
  @moduledoc "Manager-store adapter backed by the transactional Phase 7 operations database."

  @behaviour Twelvgaige.Manager.Store

  alias Twelvgaige.Operations.Store

  @far_future ~U[9999-12-31 23:59:59Z]
  @terminal_statuses [:completed, :failed, :cancelled, :awaiting_review]

  @impl true
  def put_plan(record, opts \\ []) do
    case Store.put_new(:manager_plan, record.id, record, record_store_opts(opts, record)) do
      :ok ->
        :ok

      :already_present ->
        same_or_conflict(:manager_plan, record.id, record, :manager_plan_conflict, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def put_submission(record, children, opts \\ []) do
    entries = [
      {:manager_plan, record.id, record} | Enum.map(children, &{:manager_child, &1.id, &1})
    ]

    case Store.put_many_new(entries, record_store_opts(opts, record)) do
      :ok ->
        :ok

      {:error, reason} ->
        if submission_present?(record, children, opts),
          do: :already_present,
          else: {:error, normalize_insert_error(reason, :manager_submission_conflict)}
    end
  end

  @impl true
  def get_plan(plan_id, opts \\ []), do: get_value(:manager_plan, plan_id, opts)

  @impl true
  def list_plans(opts \\ []), do: list_values(:manager_plan, opts)

  @impl true
  def update_plan(plan_id, version, attrs, opts \\ []) do
    update_record(:manager_plan, plan_id, version, attrs, opts)
  end

  @impl true
  def put_child(child, opts \\ []) do
    case Store.put_new(:manager_child, child.id, child, record_store_opts(opts, child)) do
      :ok ->
        :ok

      :already_present ->
        same_or_conflict(:manager_child, child.id, child, :manager_child_conflict, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_child(child_id, opts \\ []), do: get_value(:manager_child, child_id, opts)

  @impl true
  def list_children(plan_id, opts \\ []) do
    with {:ok, children} <- list_values(:manager_child, opts) do
      {:ok,
       children |> Enum.filter(&(&1.plan_id == plan_id)) |> Enum.sort_by(&{&1.created_at, &1.id})}
    end
  end

  @impl true
  def update_child(child_id, version, attrs, opts \\ []) do
    update_record(:manager_child, child_id, version, attrs, opts)
  end

  @impl true
  def append_event(plan_id, event, opts \\ []) do
    id = Map.get(event, :id, Map.get(event, "id"))

    case Store.put_new(
           :manager_event,
           plan_id <> ":" <> id,
           {plan_id, event},
           Keyword.merge(store_opts(opts), retention_class: :security)
         ) do
      :ok -> :ok
      :already_present -> :already_present
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_events(plan_id, opts \\ []) do
    with {:ok, events} <- list_values(:manager_event, opts) do
      {:ok,
       events
       |> Enum.filter(fn {stored_plan_id, _event} -> stored_plan_id == plan_id end)
       |> Enum.map(&elem(&1, 1))}
    end
  end

  defp update_record(namespace, id, expected_version, attrs, opts) do
    with {:ok, envelope} <- Store.get(namespace, id, store_opts(opts)),
         true <- envelope.value.version == expected_version,
         updated <-
           envelope.value
           |> struct!(Map.new(attrs))
           |> Map.put(:version, expected_version + 1),
         :ok <-
           Store.compare_and_put(
             namespace,
             id,
             envelope.version,
             updated,
             record_store_opts(opts, updated)
           ) do
      {:ok, updated}
    else
      false -> {:error, :manager_version_conflict}
      {:error, :version_conflict} -> {:error, :manager_version_conflict}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_value(namespace, id, opts) do
    case Store.get(namespace, id, store_opts(opts)) do
      {:ok, record} -> {:ok, record.value}
      {:error, :not_found} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp list_values(namespace, opts) do
    case Store.list(namespace, store_opts(opts)) do
      {:ok, records} -> {:ok, Enum.map(records, & &1.value)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp same_or_conflict(namespace, id, expected, conflict, opts) do
    case get_value(namespace, id, opts) do
      {:ok, ^expected} -> :already_present
      {:ok, _other} -> {:error, conflict}
      {:error, reason} -> {:error, reason}
    end
  end

  defp submission_present?(record, children, opts) do
    get_value(:manager_plan, record.id, opts) == {:ok, record} and
      Enum.all?(children, &(get_value(:manager_child, &1.id, opts) == {:ok, &1}))
  end

  defp normalize_insert_error(%Exqlite.Error{}, fallback), do: fallback
  defp normalize_insert_error(_reason, fallback), do: fallback

  defp store_opts(opts) do
    [server: Keyword.get(opts, :server, Keyword.get(opts, :store_server, Store))]
  end

  defp record_store_opts(opts, %{status: status}) when status in @terminal_statuses,
    do: Keyword.merge(store_opts(opts), retention_class: :raw)

  defp record_store_opts(opts, _record),
    do: Keyword.merge(store_opts(opts), retention_class: :raw, hold_until: @far_future)
end
