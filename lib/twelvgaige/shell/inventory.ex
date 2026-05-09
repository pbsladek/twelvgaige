defmodule Twelvgaige.Shell.Inventory do
  @moduledoc """
  Read-only inventory for a collection of shell files.

  Inventory is intentionally daemon-free. It scans shell documents from disk,
  loads what it can, reports invalid shells as structured errors, and summarizes
  workflow/agent relationships for review and CI.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Graph
  alias Twelvgaige.Shell.Loader
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shell.Workflow.Shot
  alias Twelvgaige.Tool.Catalog

  @type report :: %{
          path: Path.t(),
          status: :ok | :degraded,
          exit_code: 0,
          workflows: [map()],
          agents: [map()],
          errors: [map()],
          summary: map()
        }

  @spec run(Path.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def run(path, opts \\ []) when is_binary(path) do
    expanded = Path.expand(path)

    cond do
      File.dir?(expanded) ->
        {:ok, scan_directory(expanded, opts)}

      File.exists?(expanded) ->
        {:ok, scan_paths(expanded, [expanded], opts)}

      true ->
        {:error,
         Error.new(:input_error, :invalid_shell, "inventory path does not exist",
           details: %{path: expanded}
         )}
    end
  end

  @spec to_map(report()) :: map()
  def to_map(report) do
    %{
      path: report.path,
      status: Atom.to_string(report.status),
      exit_code: report.exit_code,
      summary: report.summary,
      workflows: report.workflows,
      agents: report.agents,
      errors: report.errors
    }
  end

  defp scan_directory(path, opts) do
    paths =
      Loader.supported_extensions()
      |> Enum.map(&Path.join(path, "**/*#{&1}"))
      |> Enum.flat_map(&Path.wildcard/1)
      |> Enum.sort()
      |> Enum.uniq()

    scan_paths(path, paths, opts)
  end

  defp scan_paths(root, paths, _opts) do
    {workflows, agents, errors} =
      Enum.reduce(paths, {[], [], []}, fn path, {workflows, agents, errors} ->
        case Loader.load(path) do
          {:ok, %Workflow{} = workflow} ->
            {[{path, workflow} | workflows], agents, errors}

          {:ok, %Agent{} = agent} ->
            {workflows, [{path, agent} | agents], errors}

          {:error, %Error{} = error} ->
            {workflows, agents, [inventory_error(path, error) | errors]}
        end
      end)

    workflows = Enum.reverse(workflows)
    agents = Enum.reverse(agents)
    errors = Enum.reverse(errors)
    agents_by_id = Map.new(agents, fn {_path, agent} -> {agent.id, agent} end)

    workflow_reports =
      workflows
      |> Enum.map(fn {path, workflow} -> workflow_report(path, workflow, agents_by_id) end)
      |> Enum.sort_by(& &1["path"])

    agent_reports =
      agents
      |> Enum.map(fn {path, agent} -> agent_report(path, agent) end)
      |> Enum.sort_by(& &1["path"])

    %{
      path: root,
      status: if(errors == [], do: :ok, else: :degraded),
      exit_code: 0,
      workflows: workflow_reports,
      agents: agent_reports,
      errors: errors,
      summary: summary(workflow_reports, agent_reports, errors)
    }
  end

  defp workflow_report(path, %Workflow{} = workflow, agents_by_id) do
    tools = workflow.shots |> Enum.flat_map(& &1.tools) |> uniq_sort()

    agents =
      workflow.shots
      |> Enum.map(& &1.agent)
      |> Enum.reject(&is_nil/1)
      |> uniq_sort()

    providers = agents |> Enum.map(&provider_for(&1, agents_by_id)) |> uniq_sort()

    %{
      "path" => path,
      "id" => workflow.id,
      "name" => workflow.name,
      "version" => workflow.version,
      "owner" => workflow.metadata.owner,
      "lifecycle" => lifecycle(workflow.metadata.lifecycle),
      "tags" => workflow.metadata.tags,
      "generated" => is_map(workflow.metadata.generated_by),
      "shot_count" => length(workflow.shots),
      "safety_shot_count" => Enum.count(workflow.shots, &(&1.kind == :safety)),
      "write_capable" => Enum.any?(workflow.shots, &write_capable?/1),
      "agents" => agents,
      "missing_agents" => Enum.reject(agents, &Map.has_key?(agents_by_id, &1)),
      "providers" => providers,
      "tools" => tools,
      "write_tools" => Enum.filter(tools, &write_capable_tool?/1),
      "templates" => templates(workflow),
      "safety_shots" => workflow.shots |> Enum.filter(&(&1.kind == :safety)) |> Enum.map(& &1.id),
      "shots" => Enum.map(workflow.shots, &shot_report/1),
      "graph" => graph_summary(workflow)
    }
    |> compact()
  end

  defp shot_report(%Shot{} = shot) do
    %{
      "id" => shot.id,
      "kind" => Atom.to_string(shot.kind),
      "agent" => shot.agent,
      "tools" => shot.tools,
      "templates" => generated_source_ids(shot.metadata, "template"),
      "safety" => shot.kind == :safety,
      "write_capable" => write_capable?(shot),
      "owner" => shot.metadata.owner,
      "purpose" => shot.metadata.purpose
    }
    |> compact()
  end

  defp agent_report(path, %Agent{} = agent) do
    %{
      "path" => path,
      "id" => agent.id,
      "name" => agent.name,
      "version" => agent.version,
      "provider" => agent.provider,
      "model" => agent.model,
      "allowed_tools" => agent.tools.allowed,
      "denied_tools" => agent.tools.denied
    }
    |> compact()
  end

  defp provider_for(agent_id, agents_by_id) do
    case Map.fetch(agents_by_id, agent_id) do
      {:ok, agent} -> agent.provider
      :error -> "unknown"
    end
  end

  defp write_capable?(%Shot{} = shot), do: Enum.any?(shot.tools, &write_capable_tool?/1)

  defp write_capable_tool?(tool) do
    case Catalog.metadata(tool) do
      {:ok, %{safety_level: :read_only}} -> false
      {:ok, %{safety_level: _level}} -> true
      {:error, _reason} -> false
    end
  end

  defp graph_summary(%Workflow{} = workflow) do
    case Graph.build(workflow) do
      {:ok, graph} ->
        %{
          "status" => "ok",
          "groups" => graph.groups,
          "edge_count" => length(graph.edges)
        }

      {:error, error} ->
        %{
          "status" => "invalid",
          "error" => Error.to_map(error)
        }
    end
  end

  defp templates(%Workflow{} = workflow) do
    workflow_templates = generated_source_ids(workflow.metadata, "template")

    shot_templates =
      workflow.shots
      |> Enum.flat_map(&generated_source_ids(&1.metadata, "template"))

    (workflow_templates ++ shot_templates)
    |> uniq_sort()
  end

  defp generated_source_ids(%{generated_by: %{} = generated_by}, kind) do
    case Map.get(generated_by, "source") do
      %{"kind" => ^kind, "id" => id} when is_binary(id) -> [id]
      _other -> []
    end
  end

  defp generated_source_ids(_metadata, _kind), do: []

  defp inventory_error(path, %Error{} = error) do
    %{
      "path" => path,
      "error" => error_map(error)
    }
  end

  defp error_map(%Error{} = error) do
    error
    |> Error.to_map()
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp summary(workflows, agents, errors) do
    tools = workflows |> Enum.flat_map(&Map.get(&1, "tools", [])) |> uniq_sort()

    providers =
      agents |> Enum.map(& &1["provider"]) |> Enum.reject(&is_nil/1) |> uniq_sort()

    %{
      "workflow_count" => length(workflows),
      "agent_count" => length(agents),
      "error_count" => length(errors),
      "write_capable_workflow_count" =>
        Enum.count(workflows, &Map.get(&1, "write_capable", false)),
      "tool_count" => length(tools),
      "tools" => tools,
      "providers" => providers,
      "lifecycles" => lifecycle_counts(workflows),
      "owners" => owner_counts(workflows)
    }
  end

  defp lifecycle_counts(workflows) do
    workflows
    |> Enum.map(&Map.get(&1, "lifecycle", "none"))
    |> counts()
  end

  defp owner_counts(workflows) do
    workflows
    |> Enum.map(&Map.get(&1, "owner", "none"))
    |> counts()
  end

  defp counts(values) do
    values
    |> Enum.frequencies()
    |> Map.new(fn {key, count} -> {key, count} end)
  end

  defp uniq_sort(values) do
    values
    |> MapSet.new()
    |> MapSet.to_list()
    |> Enum.sort()
  end

  defp lifecycle(nil), do: nil
  defp lifecycle(value) when is_atom(value), do: Atom.to_string(value)

  defp compact(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = compact(value)

      if empty?(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(value), do: value

  defp empty?(nil), do: true
  defp empty?(map) when map == %{}, do: true
  defp empty?(_value), do: false
end
