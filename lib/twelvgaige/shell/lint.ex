defmodule Twelvgaige.Shell.Lint do
  @moduledoc """
  Workflow lint rules for authoring.

  In-memory lint stays workflow-only so generated candidates and tests can be
  checked without a repository context. Path-based lint also discovers adjacent
  agent shells and checks shot tool usage against agent allow/deny policy.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Digest
  alias Twelvgaige.Shell.Graph
  alias Twelvgaige.Shell.Loader
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shell.Workflow.Shot
  alias Twelvgaige.Tool.Catalog
  alias Twelvgaige.RuntimeProfile

  @generic_ids MapSet.new(~w(step step1 run fix do_it doit task action check))

  @type severity :: :warning | :error
  @type finding_class :: :workflow | :shot

  @type finding :: %{
          id: String.t(),
          severity: severity(),
          class: finding_class(),
          message: String.t(),
          location: map(),
          details: map()
        }

  @type report :: %{
          path: Path.t(),
          status: :ok | :failed,
          exit_code: 0 | 1,
          errors: [map()],
          findings: [finding()],
          skipped: [map()]
        }

  @type target_report :: report() | collection_report()
  @type collection_report :: %{
          path: Path.t(),
          status: :ok | :failed,
          exit_code: 0 | 1,
          errors: [map()],
          reports: [report()],
          skipped: [map()]
        }

  @spec run_target(Path.t(), keyword()) :: {:ok, target_report()} | {:error, Error.t()}
  def run_target(path, opts \\ []) when is_binary(path) do
    cond do
      File.dir?(path) -> run_directory(path, opts)
      true -> run_path(path, opts)
    end
  end

  @spec run_path(Path.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def run_path(path, opts \\ []) when is_binary(path) do
    case Loader.load(path) do
      {:ok, %Workflow{} = workflow} ->
        {:ok, agents} = contextual_agents(path, opts)
        {:ok, run(workflow, opts |> Keyword.put(:path, path) |> Keyword.put(:agents, agents))}

      {:ok, _other_shell} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "shell lint requires a workflow shell",
           details: %{path: path}
         )}

      {:error, _reason} = error ->
        error
    end
  end

  @spec run_directory(Path.t(), keyword()) :: {:ok, collection_report()} | {:error, Error.t()}
  def run_directory(path, opts \\ []) when is_binary(path) do
    expanded = Path.expand(path)
    strict? = Keyword.get(opts, :strict?, false)

    {reports, errors, skipped} =
      expanded
      |> shell_paths()
      |> Enum.reduce({[], [], []}, fn path, {reports, errors, skipped} ->
        case Loader.load(path) do
          {:ok, %Workflow{} = workflow} ->
            {:ok, agents} = contextual_agents(path, opts)

            report =
              run(workflow, opts |> Keyword.merge(path: path) |> Keyword.put(:agents, agents))

            {[report | reports], errors, skipped}

          {:ok, _agent} ->
            {reports, errors, [%{path: path, reason: "agent_shell"} | skipped]}

          {:error, %Error{} = error} ->
            {reports, [%{path: path, error: Error.to_map(error)} | errors], skipped}
        end
      end)

    reports = Enum.reverse(reports)
    errors = Enum.reverse(errors)
    skipped = Enum.reverse(skipped)
    status = collection_status(reports, errors, strict?)

    {:ok,
     %{
       path: expanded,
       status: status,
       exit_code: if(status == :ok, do: 0, else: 1),
       errors: errors,
       reports: reports,
       skipped: skipped
     }}
  end

  @spec run(Workflow.t(), keyword()) :: report()
  def run(%Workflow{} = workflow, opts \\ []) do
    path = Keyword.get(opts, :path, "<memory>")
    strict? = Keyword.get(opts, :strict?, false)

    findings =
      workflow
      |> graph_findings()
      |> Kernel.++(metadata_findings(workflow))
      |> Kernel.++(shot_findings(workflow))
      |> Kernel.++(profile_findings(workflow, opts))
      |> Kernel.++(contextual_findings(workflow, opts))
      |> Enum.sort_by(&{severity_rank(&1.severity), &1.id, Map.get(&1.location, :shot_id, "")})

    status = report_status(findings, strict?)

    %{
      path: path,
      status: status,
      exit_code: if(status == :ok, do: 0, else: 1),
      errors: [],
      findings: findings,
      skipped: []
    }
  end

  @spec to_map(report()) :: map()
  def to_map(report) do
    if Map.has_key?(report, :reports) do
      collection_to_map(report)
    else
      report_to_map(report)
    end
  end

  defp report_to_map(report) do
    %{
      path: report.path,
      status: Atom.to_string(report.status),
      exit_code: report.exit_code,
      errors: report.errors,
      findings: Enum.map(report.findings, &finding_to_map/1),
      skipped: report.skipped
    }
  end

  defp collection_to_map(report) do
    %{
      path: report.path,
      status: Atom.to_string(report.status),
      exit_code: report.exit_code,
      errors: report.errors,
      reports: Enum.map(report.reports, &report_to_map/1),
      skipped: report.skipped
    }
  end

  defp shell_paths(path) do
    Loader.supported_extensions()
    |> Enum.map(&Path.join(path, "**/*#{&1}"))
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
    |> Enum.uniq()
  end

  defp contextual_agents(path, opts) do
    if Keyword.get(opts, :contextual?, true) do
      case Loader.load_agents_for_workflow(path, opts) do
        {:ok, agents} ->
          {:ok, agents}

        {:error, %Error{} = error} ->
          {:ok, {:error, error}}

        {:error, reason} ->
          error =
            Error.new(:input_error, :invalid_shell, "agent context discovery failed",
              details: %{path: path, reason: inspect(reason)}
            )

          {:ok, {:error, error}}
      end
    else
      {:ok, :not_loaded}
    end
  end

  defp graph_findings(%Workflow{} = workflow) do
    case Graph.build(workflow) do
      {:ok, _graph} ->
        []

      {:error, %Error{} = error} ->
        [
          finding(
            "workflow.graph.invalid",
            :error,
            :workflow,
            error.message,
            %{shot_id: Map.get(error.details, :shot_id)},
            %{reason: Atom.to_string(error.reason), details: error.details}
          )
        ]
    end
  end

  defp metadata_findings(%Workflow{} = workflow) do
    []
    |> maybe_missing_owner(workflow)
    |> maybe_generated_unreviewed(workflow)
    |> maybe_deprecated(workflow)
    |> maybe_retired(workflow)
    |> maybe_missing_current_approval(workflow)
    |> maybe_stale_approval(workflow)
  end

  defp maybe_missing_owner(findings, %Workflow{metadata: %{owner: nil}}) do
    [
      finding(
        "metadata.owner.missing",
        :warning,
        :workflow,
        "workflow metadata owner is missing",
        %{shot_id: nil},
        %{}
      )
      | findings
    ]
  end

  defp maybe_missing_owner(findings, _workflow), do: findings

  defp maybe_generated_unreviewed(
         findings,
         %Workflow{metadata: %{generated_by: generated_by, lifecycle: lifecycle}}
       )
       when is_map(generated_by) and lifecycle in [nil, :draft] do
    [
      finding(
        "metadata.generated.unreviewed",
        :warning,
        :workflow,
        "generated workflow has not been reviewed",
        %{shot_id: nil},
        %{lifecycle: lifecycle || :none}
      )
      | findings
    ]
  end

  defp maybe_generated_unreviewed(findings, _workflow), do: findings

  defp maybe_deprecated(findings, %Workflow{
         metadata: %{lifecycle: :deprecated, lifecycle_reason: reason}
       }) do
    [
      finding(
        "lifecycle.deprecated",
        :warning,
        :workflow,
        "deprecated workflow should not be used for new automation",
        %{shot_id: nil},
        %{reason: reason}
      )
      | findings
    ]
  end

  defp maybe_deprecated(findings, _workflow), do: findings

  defp maybe_retired(findings, %Workflow{
         metadata: %{lifecycle: :retired, lifecycle_reason: reason}
       }) do
    [
      finding(
        "lifecycle.retired",
        :error,
        :workflow,
        "retired workflow should only be kept for history, replay, or audit",
        %{shot_id: nil},
        %{reason: reason}
      )
      | findings
    ]
  end

  defp maybe_retired(findings, _workflow), do: findings

  defp maybe_missing_current_approval(
         findings,
         %Workflow{metadata: %{lifecycle: lifecycle}} = workflow
       )
       when lifecycle in [:approved, :scheduled] do
    if Digest.current_binding?(workflow, :approval) do
      findings
    else
      [
        finding(
          "approval.digest.missing",
          :error,
          :workflow,
          "approved or scheduled workflow is missing a current approval digest",
          %{shot_id: nil},
          %{lifecycle: lifecycle}
        )
        | findings
      ]
    end
  end

  defp maybe_missing_current_approval(findings, _workflow), do: findings

  defp maybe_stale_approval(findings, %Workflow{} = workflow) do
    case Digest.binding_digest(workflow, :approval) do
      nil ->
        findings

      bound_digest ->
        current_digest = Digest.workflow_subject_digest(workflow)

        if bound_digest == current_digest do
          findings
        else
          [
            finding(
              "approval.digest.stale",
              :error,
              :workflow,
              "approved digest does not match the normalized workflow digest",
              %{shot_id: nil},
              %{approved_digest: bound_digest, current_digest: current_digest}
            )
            | findings
          ]
        end
    end
  end

  defp shot_findings(%Workflow{} = workflow) do
    safety_by_id = Map.new(workflow.shots, &{&1.id, &1.kind == :safety})

    workflow.shots
    |> Enum.flat_map(fn shot ->
      []
      |> maybe_generic_id(shot)
      |> maybe_unknown_tools(shot)
      |> maybe_missing_output_schema(shot)
      |> maybe_missing_timeout(shot)
      |> maybe_missing_safety_dependency(shot, safety_by_id)
    end)
  end

  defp contextual_findings(%Workflow{} = workflow, opts) do
    case Keyword.get(opts, :agents, :not_loaded) do
      :not_loaded ->
        []

      {:error, %Error{} = error} ->
        [
          finding(
            "context.agent_discovery.failed",
            :warning,
            :workflow,
            "agent shell discovery failed",
            %{shot_id: nil},
            Error.to_map(error)
          )
        ]

      agents when is_list(agents) ->
        contextual_agent_findings(workflow, agents)
    end
  end

  defp profile_findings(%Workflow{} = workflow, opts) do
    case RuntimeProfile.effective(workflow.policy, opts) do
      {:ok, profile} ->
        max_iterations = RuntimeProfile.shot_opts(profile) |> Keyword.fetch!(:max_iterations)

        []
        |> maybe_clamped_profile(workflow, profile)
        |> Kernel.++(shot_iteration_profile_findings(workflow, profile, max_iterations))

      {:error, %Error{} = error} ->
        [
          finding(
            "policy.resource_profile.invalid",
            :warning,
            :workflow,
            "workflow resource profile could not be normalized",
            %{shot_id: nil},
            Error.to_map(error)
          )
        ]
    end
  end

  defp maybe_clamped_profile(findings, %Workflow{} = workflow, profile) do
    requested = workflow.policy.resource_profile

    if requested != profile do
      [
        finding(
          "policy.resource_profile.clamped",
          :warning,
          :workflow,
          "workflow resource profile exceeds the configured maximum and will be clamped",
          %{shot_id: nil},
          %{requested_profile: requested, effective_profile: profile}
        )
        | findings
      ]
    else
      findings
    end
  end

  defp shot_iteration_profile_findings(%Workflow{} = workflow, profile, max_iterations) do
    workflow.shots
    |> Enum.filter(fn shot ->
      shot.kind == :slug and shot.choke.max_iterations > max_iterations
    end)
    |> Enum.map(fn shot ->
      finding(
        "shot.choke.max_iterations.exceeds_profile",
        :warning,
        :shot,
        "shot max_iterations exceeds the effective resource profile recommendation",
        %{shot_id: shot.id},
        %{
          profile: profile,
          configured_max_iterations: shot.choke.max_iterations,
          profile_max_iterations: max_iterations
        }
      )
    end)
  end

  defp contextual_agent_findings(%Workflow{} = workflow, agents) do
    agents_by_id = Map.new(agents, &{&1.id, &1})

    workflow.shots
    |> Enum.flat_map(fn shot ->
      case shot.agent do
        nil ->
          []

        agent_id ->
          case Map.fetch(agents_by_id, agent_id) do
            {:ok, agent} -> agent_tool_findings(shot, agent)
            :error -> [missing_agent_finding(shot)]
          end
      end
    end)
  end

  defp missing_agent_finding(%Shot{} = shot) do
    finding(
      "shot.agent.missing",
      :warning,
      :shot,
      "shot references an agent shell that was not discovered",
      %{shot_id: shot.id},
      %{agent: shot.agent}
    )
  end

  defp agent_tool_findings(%Shot{tools: []}, %Agent{}), do: []

  defp agent_tool_findings(%Shot{} = shot, %Agent{} = agent) do
    []
    |> Kernel.++(denied_tool_findings(shot, agent))
    |> Kernel.++(unallowed_tool_findings(shot, agent))
  end

  defp denied_tool_findings(%Shot{} = shot, %Agent{} = agent) do
    denied = Enum.filter(shot.tools, &(&1 in agent.tools.denied))

    case denied do
      [] ->
        []

      denied ->
        [
          finding(
            "shot.tool.denied_by_agent",
            :error,
            :shot,
            "shot uses tools denied by its agent shell",
            %{shot_id: shot.id},
            %{agent: agent.id, tools: denied}
          )
        ]
    end
  end

  defp unallowed_tool_findings(%Shot{}, %Agent{tools: %{allowed: []}}), do: []

  defp unallowed_tool_findings(%Shot{} = shot, %Agent{} = agent) do
    unallowed = Enum.reject(shot.tools, &(&1 in agent.tools.allowed))

    case unallowed do
      [] ->
        []

      unallowed ->
        [
          finding(
            "shot.tool.not_allowed_by_agent",
            :error,
            :shot,
            "shot uses tools not allowed by its agent shell",
            %{shot_id: shot.id},
            %{agent: agent.id, tools: unallowed, allowed_tools: agent.tools.allowed}
          )
        ]
    end
  end

  defp maybe_generic_id(findings, %Shot{id: id} = shot) do
    if MapSet.member?(@generic_ids, id) do
      [
        finding(
          "shot.id.generic",
          :warning,
          :shot,
          "shot id is too generic",
          %{shot_id: shot.id},
          %{shot_id: shot.id}
        )
        | findings
      ]
    else
      findings
    end
  end

  defp maybe_missing_output_schema(findings, %Shot{kind: :slug, output_schema: nil} = shot) do
    [
      finding(
        "shot.output_schema.missing",
        :warning,
        :shot,
        "slug shot is missing an output schema",
        %{shot_id: shot.id},
        %{agent: shot.agent}
      )
      | findings
    ]
  end

  defp maybe_missing_output_schema(findings, _shot), do: findings

  defp maybe_unknown_tools(findings, %Shot{tools: tools} = shot) do
    unknown_tools =
      Enum.reject(tools, fn tool ->
        match?({:ok, _metadata}, Catalog.metadata(tool))
      end)

    case unknown_tools do
      [] ->
        findings

      unknown_tools ->
        [
          finding(
            "shot.tool.unknown",
            :error,
            :shot,
            "shot references unknown tools",
            %{shot_id: shot.id},
            %{tools: unknown_tools}
          )
          | findings
        ]
    end
  end

  defp maybe_missing_timeout(findings, %Shot{kind: :slug, timeout_ms: nil} = shot) do
    [
      finding(
        "shot.timeout.missing",
        :warning,
        :shot,
        "slug shot is missing an explicit timeout",
        %{shot_id: shot.id},
        %{agent: shot.agent}
      )
      | findings
    ]
  end

  defp maybe_missing_timeout(findings, _shot), do: findings

  defp maybe_missing_safety_dependency(findings, %Shot{} = shot, safety_by_id) do
    if write_capable?(shot) and not direct_safety_dependency?(shot, safety_by_id) do
      [
        finding(
          "shot.safety.write_without_gate",
          :error,
          :shot,
          "write-capable shot is missing a direct safety dependency",
          %{shot_id: shot.id},
          %{tools: shot.tools}
        )
        | findings
      ]
    else
      findings
    end
  end

  defp direct_safety_dependency?(%Shot{} = shot, safety_by_id) do
    Enum.any?(shot.depends_on, &Map.get(safety_by_id, &1, false))
  end

  defp write_capable?(%Shot{} = shot), do: Enum.any?(shot.tools, &write_capable_tool?/1)

  defp write_capable_tool?(tool) do
    case Catalog.metadata(tool) do
      {:ok, %{safety_level: :read_only}} -> false
      {:ok, %{safety_level: _level}} -> true
      {:error, _reason} -> false
    end
  end

  defp report_status(findings, true) do
    if Enum.any?(findings, &(&1.severity == :error)), do: :failed, else: :ok
  end

  defp report_status(_findings, false), do: :ok

  defp collection_status(_reports, [_error | _rest], _strict?), do: :failed

  defp collection_status(reports, [], true) do
    if Enum.any?(reports, &(&1.status == :failed)), do: :failed, else: :ok
  end

  defp collection_status(_reports, [], false), do: :ok

  defp severity_rank(:error), do: 0
  defp severity_rank(:warning), do: 1

  defp finding(id, severity, class, message, location, details) do
    %{
      id: id,
      severity: severity,
      class: class,
      message: message,
      location: location,
      details: details
    }
  end

  defp finding_to_map(finding) do
    %{
      id: finding.id,
      severity: Atom.to_string(finding.severity),
      class: Atom.to_string(finding.class),
      message: finding.message,
      location: stringify_values(finding.location),
      details: stringify_values(finding.details)
    }
  end

  defp stringify_values(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(value) -> {key, Atom.to_string(value)}
      {key, value} -> {key, value}
    end)
  end
end
