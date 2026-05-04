defmodule Twelvgaige.Shell.BulkRefactor do
  @moduledoc """
  Collection-scale shell refactors with explicit dry-run and write modes.
  """

  alias Twelvgaige.Authoring.AtomicFile
  alias Twelvgaige.Authoring.ShotRefactor
  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Impact
  alias Twelvgaige.Shell.Lint
  alias Twelvgaige.Shell.Loader

  @type report :: %{
          path: Path.t(),
          operation: :replace_agent | :replace_tool,
          selector: map(),
          mode: :dry_run | :write,
          status: :ok | :partial | :failed,
          exit_code: 0 | 1,
          changes: [map()],
          errors: [map()],
          summary: map()
        }

  @spec replace_agent(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, report()} | {:error, Error.t()}
  def replace_agent(path, old_agent, new_agent, opts \\ [])

  def replace_agent(path, old_agent, new_agent, opts)
      when is_binary(path) and is_binary(old_agent) and is_binary(new_agent) do
    write? = Keyword.get(opts, :write?, false)
    yes? = Keyword.get(opts, :yes?, false)

    cond do
      write? and not yes? ->
        invalid("shell bulk replace-agent requires --yes with --write")

      true ->
        with {:ok, impact} <- Impact.run(path, :agent, old_agent, opts) do
          candidates =
            impact.matches
            |> Enum.map(& &1["path"])
            |> Enum.uniq()
            |> Enum.sort()

          {changes, errors} =
            Enum.reduce(candidates, {[], impact.errors}, fn workflow_path, {changes, errors} ->
              case replace_agent_candidate(workflow_path, old_agent, new_agent, write?) do
                {:ok, change} -> {[change | changes], errors}
                {:error, error} -> {changes, [bulk_error(workflow_path, error) | errors]}
              end
            end)

          changes = Enum.reverse(changes)
          errors = Enum.reverse(errors)

          {:ok,
           report(%{
             path: impact.path,
             old_agent: old_agent,
             new_agent: new_agent,
             write?: write?,
             changes: changes,
             errors: errors,
             scanned_workflows: impact.summary["workflow_count"]
           })}
        end
    end
  end

  def replace_agent(_path, _old_agent, _new_agent, _opts) do
    invalid("shell bulk replace-agent requires path, old agent, and new agent strings")
  end

  @spec replace_tool(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, report()} | {:error, Error.t()}
  def replace_tool(path, old_tool, new_tool, opts \\ [])

  def replace_tool(path, old_tool, new_tool, opts)
      when is_binary(path) and is_binary(old_tool) and is_binary(new_tool) do
    write? = Keyword.get(opts, :write?, false)
    yes? = Keyword.get(opts, :yes?, false)

    cond do
      write? and not yes? ->
        invalid("shell bulk replace-tool requires --yes with --write")

      true ->
        with {:ok, impact} <- Impact.run(path, :tool, old_tool, opts) do
          candidates =
            impact.matches
            |> Enum.map(& &1["path"])
            |> Enum.uniq()
            |> Enum.sort()

          {changes, errors} =
            Enum.reduce(candidates, {[], impact.errors}, fn workflow_path, {changes, errors} ->
              case replace_tool_candidate(workflow_path, old_tool, new_tool, write?) do
                {:ok, change} -> {[change | changes], errors}
                {:error, error} -> {changes, [bulk_error(workflow_path, error) | errors]}
              end
            end)

          changes = Enum.reverse(changes)
          errors = Enum.reverse(errors)

          {:ok,
           report(%{
             path: impact.path,
             operation: :replace_tool,
             selector: %{"kind" => "tool", "old" => old_tool, "new" => new_tool},
             write?: write?,
             changes: changes,
             errors: errors,
             scanned_workflows: impact.summary["workflow_count"]
           })}
        end
    end
  end

  def replace_tool(_path, _old_tool, _new_tool, _opts) do
    invalid("shell bulk replace-tool requires path, old tool, and new tool strings")
  end

  @spec to_map(report()) :: map()
  def to_map(report) do
    %{
      path: report.path,
      operation: Atom.to_string(report.operation),
      selector: report.selector,
      mode: Atom.to_string(report.mode),
      status: Atom.to_string(report.status),
      exit_code: report.exit_code,
      summary: report.summary,
      changes: report.changes,
      errors: report.errors
    }
  end

  defp replace_agent_candidate(path, old_agent, new_agent, write?) do
    with {:ok, result} <- ShotRefactor.replace_agent(path, old_agent, new_agent),
         {:ok, lint_report} <- lint_candidate(path, result.workflow, new_agent),
         change <- agent_change_map(result, lint_report),
         :ok <- maybe_write(write?, result) do
      {:ok, Map.put(change, "wrote", write?)}
    end
  end

  defp replace_tool_candidate(path, old_tool, new_tool, write?) do
    with {:ok, result} <- ShotRefactor.replace_tool(path, old_tool, new_tool),
         {:ok, lint_report} <- lint_tool_candidate(path, result.workflow, new_tool),
         change <- tool_change_map(result, lint_report),
         :ok <- maybe_write(write?, result) do
      {:ok, Map.put(change, "wrote", write?)}
    end
  end

  defp lint_candidate(path, workflow, new_agent) do
    with {:ok, agents} <- Loader.load_agents_for_workflow(path),
         :ok <- ensure_replacement_agent_discovered(new_agent, agents) do
      report = Lint.run(workflow, path: path, strict?: true, agents: agents)

      if report.status == :ok do
        {:ok, report}
      else
        invalid("replacement agent failed contextual lint", %{
          agent: new_agent,
          findings: Lint.to_map(report).findings
        })
      end
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        invalid("agent shell discovery failed", %{path: path, reason: inspect(reason)})
    end
  end

  defp ensure_replacement_agent_discovered(new_agent, agents) do
    if Enum.any?(agents, &(&1.id == new_agent)) do
      :ok
    else
      invalid("replacement agent shell was not discovered", %{
        agent: new_agent,
        discovered_agents: Enum.map(agents, & &1.id)
      })
    end
  end

  defp lint_tool_candidate(path, workflow, new_tool) do
    case Loader.load_agents_for_workflow(path) do
      {:ok, agents} ->
        report = Lint.run(workflow, path: path, strict?: true, agents: agents)

        if report.status == :ok do
          {:ok, report}
        else
          invalid("replacement tool failed contextual lint", %{
            tool: new_tool,
            findings: Lint.to_map(report).findings
          })
        end

      {:error, %Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        invalid("agent shell discovery failed", %{path: path, reason: inspect(reason)})
    end
  end

  defp maybe_write(false, _result), do: :ok

  defp maybe_write(true, result) do
    with :ok <- AtomicFile.write(result.path, result.candidate),
         {:ok, _workflow} <- Twelvgaige.validate_shell(result.path) do
      :ok
    else
      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp agent_change_map(result, lint_report) do
    %{
      "path" => result.path,
      "old_agent" => result.old_agent,
      "new_agent" => result.new_agent,
      "changed_shot_ids" => result.changed_shot_ids,
      "format" => Atom.to_string(result.format),
      "lint_report" => Lint.to_map(lint_report),
      "diff" => result.diff
    }
  end

  defp tool_change_map(result, lint_report) do
    %{
      "path" => result.path,
      "old_tool" => result.old_tool,
      "new_tool" => result.new_tool,
      "changed_shot_ids" => result.changed_shot_ids,
      "format" => Atom.to_string(result.format),
      "lint_report" => Lint.to_map(lint_report),
      "diff" => result.diff
    }
  end

  defp status([], [_error | _rest]), do: :failed
  defp status(_changes, [_error | _rest]), do: :partial
  defp status(_changes, []), do: :ok

  defp report(%{operation: _operation} = attrs), do: do_report(attrs)

  defp report(attrs) do
    attrs
    |> Map.put(:operation, :replace_agent)
    |> Map.put(:selector, %{"kind" => "agent", "old" => attrs.old_agent, "new" => attrs.new_agent})
    |> do_report()
  end

  defp do_report(attrs) do
    changes = attrs.changes
    errors = attrs.errors
    status = status(changes, errors)

    %{
      path: attrs.path,
      operation: attrs.operation,
      selector: attrs.selector,
      mode: if(attrs.write?, do: :write, else: :dry_run),
      status: status,
      exit_code: if(status == :failed, do: 1, else: 0),
      changes: changes,
      errors: errors,
      summary: %{
        "scanned_workflows" => attrs.scanned_workflows,
        "changed_workflows" => length(changes),
        "changed_shots" =>
          changes
          |> Enum.flat_map(& &1["changed_shot_ids"])
          |> length(),
        "error_count" => length(errors)
      }
    }
  end

  defp bulk_error(path, %Error{} = error) do
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

  defp invalid(message, details \\ %{}) do
    {:error, Error.new(:input_error, :invalid_shell, message, details: details)}
  end
end
