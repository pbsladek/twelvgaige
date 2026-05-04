defmodule Twelvgaige.Shell.LintTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Lint
  alias Twelvgaige.Shell.Digest
  alias Twelvgaige.Shell.Workflow

  test "reports workflow-only shot maintainability findings" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_test",
        version: "1.0.0",
        shots: [
          %{id: "step1", kind: :slug, agent: "agent"},
          %{id: "apply", kind: :slug, agent: "agent", tools: ["kubectl_apply"]}
        ]
      })

    report = Lint.run(workflow, path: "workflow.yaml", strict?: true)

    assert report.path == "workflow.yaml"
    assert report.status == :failed
    assert report.exit_code == 1

    assert [
             %{
               id: "shot.safety.write_without_gate",
               severity: :error,
               location: %{shot_id: "apply"}
             },
             %{id: "metadata.owner.missing", severity: :warning, location: %{shot_id: nil}},
             %{id: "shot.id.generic", severity: :warning, location: %{shot_id: "step1"}},
             %{
               id: "shot.output_schema.missing",
               severity: :warning,
               location: %{shot_id: "apply"}
             },
             %{
               id: "shot.output_schema.missing",
               severity: :warning,
               location: %{shot_id: "step1"}
             },
             %{id: "shot.timeout.missing", severity: :warning, location: %{shot_id: "apply"}},
             %{id: "shot.timeout.missing", severity: :warning, location: %{shot_id: "step1"}}
           ] = report.findings
  end

  test "does not fail warning-only reports in strict mode" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_warning",
        version: "1.0.0",
        shots: [%{id: "inspect", kind: :slug, agent: "agent"}]
      })

    report = Lint.run(workflow, strict?: true)

    assert report.status == :ok
    assert report.exit_code == 0
    assert Enum.all?(report.findings, &(&1.severity == :warning))
  end

  test "accepts write-capable shots with a direct safety dependency" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_safety",
        version: "1.0.0",
        shots: [
          %{id: "approval", kind: :safety},
          %{
            id: "apply",
            kind: :slug,
            agent: "agent",
            depends_on: ["approval"],
            tools: ["kubectl_apply"]
          }
        ]
      })

    report = Lint.run(workflow, strict?: true)

    refute Enum.any?(report.findings, &(&1.id == "shot.safety.write_without_gate"))
    assert report.status == :ok
  end

  test "reports unknown shot tools as error-level findings" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_unknown_tool",
        version: "1.0.0",
        shots: [%{id: "inspect", kind: :slug, agent: "agent", tools: ["not_a_tool"]}]
      })

    report = Lint.run(workflow, strict?: true)

    assert Enum.any?(report.findings, fn finding ->
             finding.id == "shot.tool.unknown" and finding.details.tools == ["not_a_tool"]
           end)

    assert report.status == :failed
  end

  test "reports missing discovered agent context from file lint" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    File.write!(workflow_path, workflow_with_agent_tool("missing_agent", "kubectl_get"))

    assert {:ok, report} = Lint.run_path(workflow_path)

    assert Enum.any?(report.findings, fn finding ->
             finding.id == "shot.agent.missing" and finding.details.agent == "missing_agent"
           end)
  end

  test "reports agent tool allow and deny mismatches from file lint" do
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    agent_path = Path.join(root, "agents/operator.yaml")
    File.mkdir_p!(Path.dirname(agent_path))
    File.write!(workflow_path, workflow_with_agent_tool("operator", "kubectl_apply"))
    File.write!(agent_path, agent_with_tools_yaml("operator", ["kubectl_get"], []))

    assert {:ok, report} = Lint.run_path(workflow_path, strict?: true)

    assert Enum.any?(report.findings, &(&1.id == "shot.tool.not_allowed_by_agent"))
    assert report.status == :failed

    File.write!(
      agent_path,
      agent_with_tools_yaml("operator", ["kubectl_apply"], ["kubectl_apply"])
    )

    assert {:ok, report} = Lint.run_path(workflow_path, strict?: true)
    assert Enum.any?(report.findings, &(&1.id == "shot.tool.denied_by_agent"))
    assert report.status == :failed
  end

  test "keeps in-memory lint workflow-only unless agents are supplied" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_memory_context",
        version: "1.0.0",
        shots: [%{id: "inspect", kind: :slug, agent: "missing_agent"}]
      })

    report = Lint.run(workflow)

    refute Enum.any?(report.findings, &(&1.id == "shot.agent.missing"))
  end

  test "warns when shot iterations exceed the effective resource profile" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_profile_iterations",
        version: "1.0.0",
        policy: %{resource_profile: :minimal},
        shots: [
          %{
            id: "inspect",
            kind: :slug,
            agent: "agent",
            choke: %{max_iterations: 6}
          }
        ]
      })

    report = Lint.run(workflow)

    assert Enum.any?(report.findings, fn finding ->
             finding.id == "shot.choke.max_iterations.exceeds_profile" and
               finding.details.profile == :minimal and
               finding.details.configured_max_iterations == 6 and
               finding.details.profile_max_iterations == 4
           end)

    assert report.status == :ok
  end

  test "warns when workflow profile is clamped by max profile" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_profile_clamped",
        version: "1.0.0",
        policy: %{resource_profile: :server},
        shots: [%{id: "inspect", kind: :slug, agent: "agent"}]
      })

    report = Lint.run(workflow, max_profile: :laptop)

    assert Enum.any?(report.findings, fn finding ->
             finding.id == "policy.resource_profile.clamped" and
               finding.details.requested_profile == :server and
               finding.details.effective_profile == :laptop
           end)

    assert report.status == :ok
  end

  test "reports invalid graph as an error-level finding" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_graph",
        version: "1.0.0",
        shots: [%{id: "a", kind: :slug, agent: "agent", depends_on: ["missing"]}]
      })

    report = Lint.run(workflow, strict?: true)

    assert %{id: "workflow.graph.invalid", severity: :error} = hd(report.findings)
    assert report.status == :failed
  end

  test "reports stale approval digest as an error-level finding" do
    {:ok, base} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_approval",
        version: "1.0.0",
        metadata: %{owner: "platform", lifecycle: "approved"},
        shots: [%{id: "inspect", kind: :slug, agent: "agent", prompt: "inspect"}]
      })

    digest = Digest.workflow_subject_digest(base)

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_approval",
        version: "1.0.0",
        metadata: %{
          owner: "platform",
          lifecycle: "approved",
          approval: %{
            workflow_digest: digest,
            approver: "human:sre",
            approved_at: "2026-05-03T00:00:00Z",
            scope: "prod"
          }
        },
        shots: [%{id: "inspect", kind: :slug, agent: "agent", prompt: "changed"}]
      })

    report = Lint.run(workflow, strict?: true)

    assert Enum.any?(report.findings, &(&1.id == "approval.digest.stale"))
    assert report.status == :failed
  end

  test "fails approved lifecycle without a current approval binding" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_approval_missing",
        version: "1.0.0",
        metadata: %{owner: "platform", lifecycle: "approved"},
        shots: [%{id: "inspect", kind: :slug, agent: "agent", prompt: "inspect"}]
      })

    report = Lint.run(workflow, strict?: true)

    assert Enum.any?(report.findings, &(&1.id == "approval.digest.missing"))
    assert report.status == :failed
  end

  test "accepts current approval digest" do
    {:ok, base} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_approval_current",
        version: "1.0.0",
        metadata: %{owner: "platform", lifecycle: "approved"},
        shots: [%{id: "inspect", kind: :slug, agent: "agent", prompt: "inspect"}]
      })

    digest = Digest.workflow_subject_digest(base)

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_approval_current",
        version: "1.0.0",
        metadata: %{
          owner: "platform",
          lifecycle: "approved",
          approval: %{
            workflow_digest: digest,
            approver: "human:sre",
            approved_at: "2026-05-03T00:00:00Z",
            scope: "prod"
          }
        },
        shots: [%{id: "inspect", kind: :slug, agent: "agent", prompt: "inspect"}]
      })

    report = Lint.run(workflow, strict?: true)

    refute Enum.any?(report.findings, &(&1.id == "approval.digest.stale"))
  end

  test "reports deprecated and retired lifecycle states" do
    {:ok, deprecated} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_deprecated",
        version: "1.0.0",
        metadata: %{owner: "platform", lifecycle: "deprecated", lifecycle_reason: "replaced"},
        shots: [%{id: "inspect", kind: :slug, agent: "agent"}]
      })

    deprecated_report = Lint.run(deprecated, strict?: true)

    assert Enum.any?(deprecated_report.findings, &(&1.id == "lifecycle.deprecated"))
    assert deprecated_report.status == :ok

    {:ok, retired} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_retired",
        version: "1.0.0",
        metadata: %{owner: "platform", lifecycle: "retired", lifecycle_reason: "audit only"},
        shots: [%{id: "inspect", kind: :slug, agent: "agent"}]
      })

    retired_report = Lint.run(retired, strict?: true)

    assert Enum.any?(retired_report.findings, &(&1.id == "lifecycle.retired"))
    assert retired_report.status == :failed
  end

  test "maps reports to stable JSON-safe shapes" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "lint_json",
        version: "1.0.0",
        shots: [%{id: "inspect", kind: :slug, agent: "agent"}]
      })

    map = workflow |> Lint.run(path: "workflow.yaml") |> Lint.to_map()

    assert %{
             path: "workflow.yaml",
             status: "ok",
             exit_code: 0,
             errors: [],
             skipped: [],
             findings: findings
           } = map

    assert Enum.any?(findings, &(&1.id == "shot.output_schema.missing"))
  end

  defp workflow_with_agent_tool(agent, tool) do
    """
    kind: workflow
    id: context_lint
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: #{agent}
        timeout: 1m
        tools: [#{tool}]
        output_schema:
          type: object
          required: [summary]
          properties:
            summary:
              type: string
    """
  end

  defp agent_with_tools_yaml(agent, allowed, denied) do
    """
    kind: agent
    id: #{agent}
    version: 1.0.0
    provider: mock
    model: mock-model
    system_prompt: Test agent.
    tools:
      allowed: [#{Enum.join(allowed, ", ")}]
      denied: [#{Enum.join(denied, ", ")}]
    """
  end

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-lint-test-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
