defmodule Twelvgaige.Shell.Admission do
  @moduledoc """
  Admission checks for workflows selected for CI, daemon, or scheduled use.

  Admission is deliberately separate from workflow execution. Metadata never
  changes DAG readiness, retries, or safety-shot behavior; callers opt into an
  admission policy before starting unattended or production-oriented rounds.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Digest
  alias Twelvgaige.Shell.Workflow

  @policies [:manual, :approved, :scheduled]

  @type policy :: :manual | :approved | :scheduled
  @type severity :: :warning | :error

  @type finding :: %{
          id: String.t(),
          severity: severity(),
          message: String.t(),
          details: map()
        }

  @type report :: %{
          policy: policy(),
          status: :ok | :failed,
          exit_code: 0 | 1,
          findings: [finding()]
        }

  @spec policies() :: [policy()]
  def policies, do: @policies

  @spec normalize_policy(term()) :: {:ok, policy()} | {:error, Error.t()}
  def normalize_policy(nil), do: {:ok, :manual}
  def normalize_policy(:none), do: {:ok, :manual}
  def normalize_policy("none"), do: {:ok, :manual}

  def normalize_policy(policy) when is_atom(policy) do
    if policy in @policies do
      {:ok, policy}
    else
      invalid_policy(policy)
    end
  end

  def normalize_policy(policy) when is_binary(policy) do
    policy
    |> String.trim()
    |> String.downcase()
    |> case do
      "manual" -> {:ok, :manual}
      "approved" -> {:ok, :approved}
      "scheduled" -> {:ok, :scheduled}
      _other -> invalid_policy(policy)
    end
  end

  def normalize_policy(policy), do: invalid_policy(policy)

  @spec report(Workflow.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def report(%Workflow{} = workflow, opts \\ []) do
    with {:ok, policy} <- normalize_policy(Keyword.get(opts, :policy, :manual)) do
      findings =
        workflow
        |> findings(policy, Keyword.get(opts, :now, Twelvgaige.Clock.utc_now()))
        |> Enum.sort_by(&{severity_rank(&1.severity), &1.id})

      status =
        if Enum.any?(findings, &(&1.severity == :error)) do
          :failed
        else
          :ok
        end

      {:ok,
       %{
         policy: policy,
         status: status,
         exit_code: if(status == :ok, do: 0, else: 1),
         findings: findings
       }}
    end
  end

  @spec check(Workflow.t(), keyword()) :: :ok | {:error, Error.t()}
  def check(%Workflow{} = workflow, opts \\ []) do
    with {:ok, report} <- report(workflow, opts) do
      if report.status == :ok do
        :ok
      else
        {:error, denied_error(workflow, report)}
      end
    end
  end

  @spec to_map(report()) :: map()
  def to_map(report) do
    %{
      policy: Atom.to_string(report.policy),
      status: Atom.to_string(report.status),
      exit_code: report.exit_code,
      findings: Enum.map(report.findings, &finding_to_map/1)
    }
  end

  defp findings(%Workflow{} = workflow, policy, now) do
    []
    |> maybe_retired(workflow, policy)
    |> Kernel.++(policy_findings(workflow, policy))
    |> Kernel.++(approval_findings(workflow, policy, now))
  end

  defp maybe_retired(findings, %Workflow{metadata: %{lifecycle: :retired}}, :manual) do
    [
      finding(
        "lifecycle.retired",
        :warning,
        "workflow is retired and should only be used for replay or audit",
        %{lifecycle: :retired}
      )
      | findings
    ]
  end

  defp maybe_retired(findings, %Workflow{metadata: %{lifecycle: :retired}}, _policy) do
    [
      finding(
        "lifecycle.retired",
        :error,
        "retired workflow is not admitted for new daemon or scheduled runs",
        %{lifecycle: :retired}
      )
      | findings
    ]
  end

  defp maybe_retired(findings, _workflow, _policy), do: findings

  defp policy_findings(_workflow, :manual), do: []

  defp policy_findings(%Workflow{metadata: %{lifecycle: lifecycle}}, :approved)
       when lifecycle in [:approved, :scheduled],
       do: []

  defp policy_findings(%Workflow{metadata: %{lifecycle: lifecycle}}, :approved) do
    [
      finding(
        "lifecycle.approval_required",
        :error,
        "approved admission requires lifecycle approved or scheduled",
        %{lifecycle: lifecycle || :none}
      )
    ]
  end

  defp policy_findings(%Workflow{metadata: %{lifecycle: :scheduled}}, :scheduled), do: []

  defp policy_findings(%Workflow{metadata: %{lifecycle: lifecycle}}, :scheduled) do
    [
      finding(
        "lifecycle.scheduled_required",
        :error,
        "scheduled admission requires lifecycle scheduled",
        %{lifecycle: lifecycle || :none}
      )
    ]
  end

  defp approval_findings(_workflow, :manual, _now), do: []

  defp approval_findings(%Workflow{} = workflow, _policy, now) do
    []
    |> maybe_missing_or_stale_approval(workflow)
    |> Kernel.++(maybe_expired_approval(workflow, now))
  end

  defp maybe_missing_or_stale_approval(findings, %Workflow{} = workflow) do
    cond do
      is_nil(Digest.binding_digest(workflow, :approval)) ->
        [
          finding(
            "approval.digest.missing",
            :error,
            "workflow approval metadata is missing",
            %{current_digest: Digest.workflow_subject_digest(workflow)}
          )
          | findings
        ]

      not Digest.current_binding?(workflow, :approval) ->
        [
          finding(
            "approval.digest.stale",
            :error,
            "workflow approval digest does not match current workflow content",
            %{
              approved_digest: Digest.binding_digest(workflow, :approval),
              current_digest: Digest.workflow_subject_digest(workflow)
            }
          )
          | findings
        ]

      true ->
        findings
    end
  end

  defp maybe_expired_approval(%Workflow{metadata: %{approval: %{} = approval}}, now) do
    case Map.get(approval, "expires_at") do
      nil ->
        []

      expires_at ->
        case DateTime.from_iso8601(expires_at) do
          {:ok, expires_at, _offset} ->
            if DateTime.compare(expires_at, now) == :gt do
              []
            else
              [
                finding(
                  "approval.expired",
                  :error,
                  "workflow approval has expired",
                  %{expires_at: DateTime.to_iso8601(expires_at), now: DateTime.to_iso8601(now)}
                )
              ]
            end

          {:error, reason} ->
            [
              finding(
                "approval.expires_at.invalid",
                :error,
                "workflow approval expires_at is not a valid ISO-8601 timestamp",
                %{expires_at: expires_at, reason: inspect(reason)}
              )
            ]
        end
    end
  end

  defp maybe_expired_approval(_workflow, _now), do: []

  defp denied_error(%Workflow{} = workflow, report) do
    Error.new(:policy_error, :policy_denied, "workflow admission policy denied execution",
      details: %{
        workflow_id: workflow.id,
        policy: report.policy,
        findings: Enum.map(report.findings, &finding_to_map/1)
      }
    )
  end

  defp invalid_policy(policy) do
    supported = Enum.map(@policies, &Atom.to_string/1) ++ ["none"]

    Error.new(:input_error, :invalid_shell, "unsupported admission policy",
      details: %{policy: inspect(policy), supported_policies: supported}
    )
    |> then(&{:error, &1})
  end

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1

  defp finding(id, severity, message, details) do
    %{
      id: id,
      severity: severity,
      message: message,
      details: details
    }
  end

  defp finding_to_map(finding) do
    %{
      id: finding.id,
      severity: Atom.to_string(finding.severity),
      message: finding.message,
      details: stringify_values(finding.details)
    }
  end

  defp stringify_values(map) do
    Map.new(map, fn
      {key, value} when is_atom(value) -> {key, Atom.to_string(value)}
      {key, value} -> {key, value}
    end)
  end
end
