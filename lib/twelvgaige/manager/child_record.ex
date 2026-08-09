defmodule Twelvgaige.Manager.ChildRecord do
  @moduledoc "Durable parent/child identity, lifecycle, budget usage, and typed result record."

  alias Twelvgaige.Manager.Budget

  @statuses [
    :blocked,
    :queued,
    :admitted,
    :running,
    :completed,
    :failed,
    :cancelled,
    :awaiting_review
  ]
  @terminal [:completed, :failed, :cancelled, :awaiting_review]

  @enforce_keys [
    :id,
    :plan_id,
    :task_id,
    :attempt,
    :round_id,
    :shot_id,
    :parent_session_id,
    :task,
    :budget,
    :created_at
  ]
  defstruct [
    :id,
    :plan_id,
    :task_id,
    :attempt,
    :round_id,
    :shot_id,
    :parent_session_id,
    :delegated_session_id,
    :workspace_id,
    :resource_permit,
    :task,
    :budget,
    :deadline,
    :principal,
    :handoff,
    :verification,
    :error,
    :started_at,
    :finished_at,
    :created_at,
    status: :queued,
    usage: Budget.zero(),
    version: 0,
    schema_version: 1,
    encoding_version: 1
  ]

  def new(compiled_plan, task, attrs \\ %{}) do
    plan = compiled_plan.plan
    attempt = value(attrs, :attempt, task.attempt)
    status = value(attrs, :status, if(task.depends_on == [], do: :queued, else: :blocked))
    if status not in @statuses, do: raise(ArgumentError, "invalid manager child status")

    %__MODULE__{
      id: value(attrs, :id, deterministic_id(plan.id, task.id, attempt)),
      plan_id: plan.id,
      task_id: task.id,
      attempt: attempt,
      round_id: plan.round_id,
      shot_id: plan.shot_id,
      parent_session_id: plan.manager_session_id,
      delegated_session_id: value(attrs, :delegated_session_id, nil),
      workspace_id: value(attrs, :workspace_id, nil),
      resource_permit: value(attrs, :resource_permit, nil),
      task: task,
      budget: task.budget,
      deadline: task.deadline,
      principal: value(attrs, :principal, nil),
      status: status,
      created_at: value(attrs, :created_at, DateTime.utc_now())
    }
  end

  def terminal?(%__MODULE__{status: status}), do: status in @terminal

  def deterministic_id(plan_id, task_id, attempt) do
    suffix =
      :crypto.hash(:sha256, :erlang.term_to_binary({plan_id, task_id, attempt}))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 20)

    Twelvgaige.ID.prefix_slug(:manager_child) <> "_" <> suffix
  end

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
