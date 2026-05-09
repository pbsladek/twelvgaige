defmodule Twelvgaige.Authoring.ShotRefactor do
  @moduledoc """
  Canonical workflow-shot refactoring helpers.

  These helpers operate on normalized shell documents. They intentionally drop
  comments and format-specific ordering because SAM6 authoring edits must leave
  behind a shell that the normal loader can validate.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Pattern.Condition

  import Twelvgaige.Authoring.ShotRefactor.Validation,
    only: [format_for_path: 1, invalid: 1, invalid: 2, unified_diff: 3]

  alias Twelvgaige.Shell.Document, as: ShellDocument
  alias Twelvgaige.Shell.Schema
  alias Twelvgaige.Shell.Workflow

  @type rename_result :: %{
          path: Path.t(),
          old_id: String.t(),
          new_id: String.t(),
          format: ShellDocument.format(),
          updated_dependencies: non_neg_integer(),
          updated_conditions: non_neg_integer(),
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @type remove_result :: %{
          path: Path.t(),
          shot_id: String.t(),
          format: ShellDocument.format(),
          removed_ids: [String.t()],
          dependent_ids: [String.t()],
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @type move_position :: :before | :after
  @type move_result :: %{
          path: Path.t(),
          shot_id: String.t(),
          target_id: String.t(),
          position: move_position(),
          format: ShellDocument.format(),
          original_index: non_neg_integer(),
          new_index: non_neg_integer(),
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @type add_result :: %{
          path: Path.t(),
          shot_id: String.t(),
          target_id: String.t() | nil,
          position: move_position() | :end,
          format: ShellDocument.format(),
          new_index: non_neg_integer(),
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @type split_result :: %{
          path: Path.t(),
          shot_id: String.t(),
          child_ids: [String.t()],
          final_child_id: String.t(),
          format: ShellDocument.format(),
          dependent_ids: [String.t()],
          updated_dependencies: non_neg_integer(),
          updated_conditions: non_neg_integer(),
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @type merge_result :: %{
          path: Path.t(),
          source_ids: [String.t()],
          new_id: String.t(),
          format: ShellDocument.format(),
          dependent_ids: [String.t()],
          updated_dependencies: non_neg_integer(),
          updated_conditions: non_neg_integer(),
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @type gate_result :: %{
          path: Path.t(),
          gate_id: String.t(),
          target_id: String.t(),
          format: ShellDocument.format(),
          original_dependencies: [String.t()],
          gate_dependencies: [String.t()],
          target_dependencies: [String.t()],
          gate_index: non_neg_integer(),
          target_index: non_neg_integer(),
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @type schema_result :: %{
          path: Path.t(),
          shot_id: String.t(),
          format: ShellDocument.format(),
          previous_schema: map() | nil,
          output_schema: map(),
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @type replace_agent_result :: %{
          path: Path.t(),
          old_agent: String.t(),
          new_agent: String.t(),
          format: ShellDocument.format(),
          changed_shot_ids: [String.t()],
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @type replace_tool_result :: %{
          path: Path.t(),
          old_tool: String.t(),
          new_tool: String.t(),
          format: ShellDocument.format(),
          changed_shot_ids: [String.t()],
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @spec rename(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, rename_result()} | {:error, Error.t()}
  def rename(path, old_id, new_id, opts \\ [])

  def rename(path, old_id, new_id, opts)
      when is_binary(path) and is_binary(old_id) and is_binary(new_id) do
    with {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = ShellDocument.to_map(workflow),
         {:ok, candidate_document, updated_dependencies, updated_conditions} <-
           rename_document(document, old_id, new_id),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- ShellDocument.encode(workflow, format),
         {:ok, candidate} <- ShellDocument.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         old_id: old_id,
         new_id: new_id,
         format: format,
         updated_dependencies: updated_dependencies,
         updated_conditions: updated_conditions,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shot rename requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def rename(_path, _old_id, _new_id, _opts) do
    invalid("shot rename requires path, old id, and new id strings")
  end

  @spec remove(Path.t(), String.t(), keyword()) ::
          {:ok, remove_result()} | {:error, Error.t()}
  def remove(path, shot_id, opts \\ [])

  def remove(path, shot_id, opts) when is_binary(path) and is_binary(shot_id) do
    with {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = ShellDocument.to_map(workflow),
         {:ok, removal} <- removal_plan(document, shot_id, opts),
         :ok <- ensure_no_remaining_condition_references(workflow, removal.removed_ids),
         candidate_document = remove_document_shots(document, removal.removed_ids),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- ShellDocument.encode(workflow, format),
         {:ok, candidate} <- ShellDocument.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         shot_id: shot_id,
         format: format,
         removed_ids: removal.removed_ids,
         dependent_ids: removal.dependent_ids,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shot remove requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def remove(_path, _shot_id, _opts) do
    invalid("shot remove requires path and shot id strings")
  end

  @spec move(Path.t(), String.t(), move_position(), String.t(), keyword()) ::
          {:ok, move_result()} | {:error, Error.t()}
  def move(path, shot_id, position, target_id, opts \\ [])

  def move(path, shot_id, position, target_id, opts)
      when is_binary(path) and is_binary(shot_id) and position in [:before, :after] and
             is_binary(target_id) do
    with {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = ShellDocument.to_map(workflow),
         {:ok, candidate_document, original_index, new_index} <-
           move_document_shot(document, shot_id, position, target_id),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- ShellDocument.encode(workflow, format),
         {:ok, candidate} <- ShellDocument.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         shot_id: shot_id,
         target_id: target_id,
         position: position,
         format: format,
         original_index: original_index,
         new_index: new_index,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shot move requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def move(_path, _shot_id, _position, _target_id, _opts) do
    invalid("shot move requires path, shot id, position, and target id")
  end

  @spec add(Path.t(), map(), keyword()) :: {:ok, add_result()} | {:error, Error.t()}
  def add(path, shot, opts \\ [])

  def add(path, shot, opts) when is_binary(path) and is_map(shot) do
    with {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = ShellDocument.to_map(workflow),
         {:ok, candidate_document, new_index} <- add_document_shot(document, shot, opts),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- ShellDocument.encode(workflow, format),
         {:ok, candidate} <- ShellDocument.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         shot_id: Map.get(shot, "id"),
         target_id: Keyword.get(opts, :target_id),
         position: Keyword.get(opts, :position, :end),
         format: format,
         new_index: new_index,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shot add requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def add(_path, _shot, _opts) do
    invalid("shot add requires a path and shot map")
  end

  @spec split(Path.t(), String.t(), [String.t()], keyword()) ::
          {:ok, split_result()} | {:error, Error.t()}
  def split(path, shot_id, child_ids, opts \\ [])

  def split(path, shot_id, child_ids, opts)
      when is_binary(path) and is_binary(shot_id) and is_list(child_ids) do
    with {:ok, child_ids} <- normalize_split_child_ids(child_ids),
         {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = ShellDocument.to_map(workflow),
         {:ok, candidate_document, split} <- split_document_shot(document, shot_id, child_ids),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- ShellDocument.encode(workflow, format),
         {:ok, candidate} <- ShellDocument.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         shot_id: shot_id,
         child_ids: child_ids,
         final_child_id: List.last(child_ids),
         format: format,
         dependent_ids: split.dependent_ids,
         updated_dependencies: split.updated_dependencies,
         updated_conditions: split.updated_conditions,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shot split requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def split(_path, _shot_id, _child_ids, _opts) do
    invalid("shot split requires path, shot id, and child id list")
  end

  @spec merge(Path.t(), [String.t()], String.t(), keyword()) ::
          {:ok, merge_result()} | {:error, Error.t()}
  def merge(path, source_ids, new_id, opts \\ [])

  def merge(path, source_ids, new_id, opts)
      when is_binary(path) and is_list(source_ids) and is_binary(new_id) do
    with {:ok, source_ids} <- normalize_merge_source_ids(source_ids),
         {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = ShellDocument.to_map(workflow),
         {:ok, candidate_document, merge} <- merge_document_shots(document, source_ids, new_id),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- ShellDocument.encode(workflow, format),
         {:ok, candidate} <- ShellDocument.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         source_ids: source_ids,
         new_id: new_id,
         format: format,
         dependent_ids: merge.dependent_ids,
         updated_dependencies: merge.updated_dependencies,
         updated_conditions: merge.updated_conditions,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shot merge requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def merge(_path, _source_ids, _new_id, _opts) do
    invalid("shot merge requires path, source ids, and new id")
  end

  @spec gate(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, gate_result()} | {:error, Error.t()}
  def gate(path, target_id, gate_id, opts \\ [])

  def gate(path, target_id, gate_id, opts)
      when is_binary(path) and is_binary(target_id) and is_binary(gate_id) do
    with {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = ShellDocument.to_map(workflow),
         {:ok, candidate_document, gate} <- gate_document_shot(document, target_id, gate_id, opts),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- ShellDocument.encode(workflow, format),
         {:ok, candidate} <- ShellDocument.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         gate_id: gate_id,
         target_id: target_id,
         format: format,
         original_dependencies: gate.original_dependencies,
         gate_dependencies: gate.gate_dependencies,
         target_dependencies: gate.target_dependencies,
         gate_index: gate.gate_index,
         target_index: gate.target_index,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shot gate requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def gate(_path, _target_id, _gate_id, _opts) do
    invalid("shot gate requires path, target shot id, and gate id strings")
  end

  @spec set_schema(Path.t(), String.t(), map(), keyword()) ::
          {:ok, schema_result()} | {:error, Error.t()}
  def set_schema(path, shot_id, schema, opts \\ [])

  def set_schema(path, shot_id, schema, opts)
      when is_binary(path) and is_binary(shot_id) and is_map(schema) do
    with {:ok, normalized_schema} <- normalize_output_schema(schema),
         {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = ShellDocument.to_map(workflow),
         {:ok, candidate_document, previous_schema} <-
           set_document_schema(document, shot_id, normalized_schema),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- ShellDocument.encode(workflow, format),
         {:ok, candidate} <- ShellDocument.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         shot_id: shot_id,
         format: format,
         previous_schema: previous_schema,
         output_schema: normalized_schema,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shot schema set requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def set_schema(_path, _shot_id, _schema, _opts) do
    invalid("shot schema set requires path, shot id, and schema map")
  end

  @spec replace_agent(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, replace_agent_result()} | {:error, Error.t()}
  def replace_agent(path, old_agent, new_agent, opts \\ [])

  def replace_agent(path, old_agent, new_agent, opts)
      when is_binary(path) and is_binary(old_agent) and is_binary(new_agent) do
    with {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = ShellDocument.to_map(workflow),
         {:ok, candidate_document, changed_shot_ids} <-
           replace_document_agent(document, old_agent, new_agent),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- ShellDocument.encode(workflow, format),
         {:ok, candidate} <- ShellDocument.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         old_agent: old_agent,
         new_agent: new_agent,
         format: format,
         changed_shot_ids: changed_shot_ids,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shot replace-agent requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def replace_agent(_path, _old_agent, _new_agent, _opts) do
    invalid("shot replace-agent requires path, old agent, and new agent strings")
  end

  @spec replace_tool(Path.t(), String.t(), String.t(), keyword()) ::
          {:ok, replace_tool_result()} | {:error, Error.t()}
  def replace_tool(path, old_tool, new_tool, opts \\ [])

  def replace_tool(path, old_tool, new_tool, opts)
      when is_binary(path) and is_binary(old_tool) and is_binary(new_tool) do
    with {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         document = ShellDocument.to_map(workflow),
         {:ok, candidate_document, changed_shot_ids} <-
           replace_document_tool(document, old_tool, new_tool),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- ShellDocument.encode(workflow, format),
         {:ok, candidate} <- ShellDocument.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         old_tool: old_tool,
         new_tool: new_tool,
         format: format,
         changed_shot_ids: changed_shot_ids,
         original: original,
         candidate: candidate,
         diff: Keyword.get_lazy(opts, :diff, fn -> unified_diff(path, original, candidate) end),
         workflow: candidate_workflow
       }}
    else
      {:ok, _other_shell} ->
        invalid("shot replace-tool requires a workflow shell", %{path: path})

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  def replace_tool(_path, _old_tool, _new_tool, _opts) do
    invalid("shot replace-tool requires path, old tool, and new tool strings")
  end

  defp rename_document(%{"shots" => shots} = document, old_id, new_id) when is_list(shots) do
    ids = Enum.map(shots, &Map.get(&1, "id"))

    cond do
      old_id not in ids ->
        invalid("shot id was not found", %{old_id: old_id})

      new_id in ids ->
        invalid("new shot id already exists", %{new_id: new_id})

      true ->
        with {:ok, renamed, dependency_updates, condition_updates} <-
               rename_shots(shots, old_id, new_id) do
          {:ok, Map.put(document, "shots", renamed), dependency_updates, condition_updates}
        end
    end
  end

  defp rename_document(_document, _old_id, _new_id) do
    invalid("workflow shell is missing shots")
  end

  defp rename_shots(shots, old_id, new_id) do
    Enum.reduce_while(shots, {:ok, [], 0, 0}, fn shot,
                                                 {:ok, renamed, dep_count, condition_count} ->
      with {:ok, shot, condition_updated?} <- rename_condition(shot, old_id, new_id) do
        {shot, dep_count} =
          shot
          |> rename_shot_id(old_id, new_id)
          |> rename_dependencies(old_id, new_id, dep_count)

        condition_count = if condition_updated?, do: condition_count + 1, else: condition_count
        {:cont, {:ok, [shot | renamed], dep_count, condition_count}}
      else
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
    |> case do
      {:ok, renamed, dep_count, condition_count} ->
        {:ok, Enum.reverse(renamed), dep_count, condition_count}

      {:error, %Error{} = error} ->
        {:error, error}
    end
  end

  defp rename_shot_id(%{"id" => old_id} = shot, old_id, new_id), do: Map.put(shot, "id", new_id)
  defp rename_shot_id(shot, _old_id, _new_id), do: shot

  defp rename_condition(%{"condition" => condition} = shot, old_id, new_id)
       when is_binary(condition) do
    case Condition.shot_references(condition, authoring_aliases?: true) do
      {:ok, refs} ->
        if old_id in refs do
          with {:ok, rewritten} <-
                 Condition.rewrite_shot_reference(condition, old_id, new_id,
                   authoring_aliases?: true
                 ) do
            {:ok, Map.put(shot, "condition", rewritten), true}
          end
        else
          {:ok, shot, false}
        end

      {:error, %Error{} = error} ->
        if String.contains?(condition, old_id) do
          invalid("shot rename cannot rewrite unsupported condition syntax", %{
            shot_id: Map.get(shot, "id"),
            old_id: old_id,
            condition_error: error.message
          })
        else
          {:ok, shot, false}
        end
    end
  end

  defp rename_condition(shot, _old_id, _new_id), do: {:ok, shot, false}

  defp rename_dependencies(%{"depends_on" => deps} = shot, old_id, new_id, count)
       when is_list(deps) do
    renamed = Enum.map(deps, &if(&1 == old_id, do: new_id, else: &1))
    updates = Enum.count(deps, &(&1 == old_id))
    {Map.put(shot, "depends_on", renamed), count + updates}
  end

  defp rename_dependencies(shot, _old_id, _new_id, count), do: {shot, count}

  defp removal_plan(%{"shots" => shots}, shot_id, opts) when is_list(shots) do
    ids = Enum.map(shots, &Map.get(&1, "id"))
    dependent_ids = transitive_dependents(shots, [shot_id])
    cascade? = Keyword.get(opts, :cascade?, false)
    confirmed? = Keyword.get(opts, :yes?, false)

    cond do
      shot_id not in ids ->
        invalid("shot id was not found", %{shot_id: shot_id})

      dependent_ids != [] and not cascade? ->
        invalid("shot has dependent shots; use --cascade --yes to remove them", %{
          shot_id: shot_id,
          dependent_ids: dependent_ids
        })

      dependent_ids != [] and not confirmed? ->
        invalid("cascading shot removal requires --yes", %{
          shot_id: shot_id,
          dependent_ids: dependent_ids
        })

      true ->
        {:ok, %{removed_ids: [shot_id | dependent_ids], dependent_ids: dependent_ids}}
    end
  end

  defp removal_plan(_document, _shot_id, _opts) do
    invalid("workflow shell is missing shots")
  end

  defp transitive_dependents(shots, ids) do
    ids_set = MapSet.new(ids)

    next =
      shots
      |> Enum.filter(fn shot ->
        shot_id = Map.get(shot, "id")
        deps = Map.get(shot, "depends_on", [])
        shot_id not in ids and Enum.any?(deps, &MapSet.member?(ids_set, &1))
      end)
      |> Enum.map(&Map.fetch!(&1, "id"))

    case next do
      [] ->
        []

      dependent_ids ->
        Enum.uniq(dependent_ids ++ transitive_dependents(shots, ids ++ dependent_ids))
    end
  end

  defp ensure_no_remaining_condition_references(%Workflow{} = workflow, removed_ids) do
    removed = MapSet.new(removed_ids)

    matches =
      workflow.shots
      |> Enum.reject(&MapSet.member?(removed, &1.id))
      |> Enum.filter(&condition_references_any?(&1, removed_ids))
      |> Enum.map(& &1.id)

    case matches do
      [] ->
        :ok

      shot_ids ->
        invalid("shot remove refuses shells with remaining condition references", %{
          removed_ids: removed_ids,
          condition_shots: shot_ids
        })
    end
  end

  defp condition_references_any?(%{condition: condition}, removed_ids)
       when is_binary(condition) do
    case Condition.shot_references(condition, authoring_aliases?: true) do
      {:ok, refs} ->
        Enum.any?(removed_ids, &(&1 in refs))

      {:error, %Error{}} ->
        Enum.any?(removed_ids, &String.contains?(condition, &1))
    end
  end

  defp condition_references_any?(_shot, _removed_ids), do: false

  defp remove_document_shots(%{"shots" => shots} = document, removed_ids) do
    removed = MapSet.new(removed_ids)
    Map.put(document, "shots", Enum.reject(shots, &MapSet.member?(removed, Map.get(&1, "id"))))
  end

  defp move_document_shot(%{"shots" => shots} = document, shot_id, position, target_id)
       when is_list(shots) do
    ids = Enum.map(shots, &Map.get(&1, "id"))

    cond do
      shot_id not in ids ->
        invalid("shot id was not found", %{shot_id: shot_id})

      target_id not in ids ->
        invalid("target shot id was not found", %{target_id: target_id})

      shot_id == target_id ->
        invalid("shot move target must be different from the moved shot", %{shot_id: shot_id})

      true ->
        do_move_document_shot(document, shots, shot_id, position, target_id)
    end
  end

  defp move_document_shot(_document, _shot_id, _position, _target_id) do
    invalid("workflow shell is missing shots")
  end

  defp do_move_document_shot(document, shots, shot_id, position, target_id) do
    original_index = Enum.find_index(shots, &(Map.get(&1, "id") == shot_id))
    shot = Enum.at(shots, original_index)
    remaining = Enum.reject(shots, &(Map.get(&1, "id") == shot_id))
    target_index = Enum.find_index(remaining, &(Map.get(&1, "id") == target_id))
    insert_index = if position == :before, do: target_index, else: target_index + 1
    moved = insert_at(remaining, insert_index, shot)
    new_index = Enum.find_index(moved, &(Map.get(&1, "id") == shot_id))

    {:ok, Map.put(document, "shots", moved), original_index, new_index}
  end

  defp insert_at(items, index, item) do
    {left, right} = Enum.split(items, index)
    left ++ [item] ++ right
  end

  defp add_document_shot(%{"shots" => shots} = document, shot, opts) when is_list(shots) do
    ids = Enum.map(shots, &Map.get(&1, "id"))
    shot_id = Map.get(shot, "id")

    cond do
      not is_binary(shot_id) or shot_id == "" ->
        invalid("new shot id must be a non-empty string")

      shot_id in ids ->
        invalid("new shot id already exists", %{shot_id: shot_id})

      true ->
        insert_new_shot(document, shots, shot, opts)
    end
  end

  defp add_document_shot(_document, _shot, _opts) do
    invalid("workflow shell is missing shots")
  end

  defp insert_new_shot(document, shots, shot, opts) do
    position = Keyword.get(opts, :position, :end)
    target_id = Keyword.get(opts, :target_id)

    with {:ok, insert_index} <- add_insert_index(shots, position, target_id) do
      updated = insert_at(shots, insert_index, shot)
      {:ok, Map.put(document, "shots", updated), insert_index}
    end
  end

  defp add_insert_index(shots, :end, nil), do: {:ok, length(shots)}

  defp add_insert_index(shots, position, target_id) when position in [:before, :after] do
    case Enum.find_index(shots, &(Map.get(&1, "id") == target_id)) do
      nil ->
        invalid("target shot id was not found", %{target_id: target_id})

      index ->
        {:ok, if(position == :before, do: index, else: index + 1)}
    end
  end

  defp add_insert_index(_shots, _position, _target_id) do
    invalid("shot add accepts either --before, --after, or no position target")
  end

  defp normalize_split_child_ids(child_ids) do
    child_ids = Enum.map(child_ids, &String.trim/1)

    cond do
      length(child_ids) < 2 ->
        invalid("shot split requires at least two child ids")

      Enum.any?(child_ids, &(&1 == "")) ->
        invalid("shot split child ids must be non-empty strings")

      length(Enum.uniq(child_ids)) != length(child_ids) ->
        invalid("shot split child ids must be unique", %{child_ids: child_ids})

      true ->
        {:ok, child_ids}
    end
  end

  defp normalize_merge_source_ids(source_ids) do
    source_ids = Enum.map(source_ids, &String.trim/1)

    cond do
      length(source_ids) < 2 ->
        invalid("shot merge requires at least two source shot ids")

      Enum.any?(source_ids, &(&1 == "")) ->
        invalid("shot merge source ids must be non-empty strings")

      length(Enum.uniq(source_ids)) != length(source_ids) ->
        invalid("shot merge source ids must be unique", %{source_ids: source_ids})

      true ->
        {:ok, source_ids}
    end
  end

  defp split_document_shot(%{"shots" => shots} = document, shot_id, child_ids)
       when is_list(shots) do
    ids = Enum.map(shots, &Map.get(&1, "id"))

    cond do
      shot_id not in ids ->
        invalid("shot id was not found", %{shot_id: shot_id})

      Enum.any?(child_ids, &(&1 in ids)) ->
        invalid("split child id already exists", %{
          child_ids: Enum.filter(child_ids, &(&1 in ids))
        })

      true ->
        do_split_document_shot(document, shots, shot_id, child_ids)
    end
  end

  defp split_document_shot(_document, _shot_id, _child_ids) do
    invalid("workflow shell is missing shots")
  end

  defp do_split_document_shot(document, shots, shot_id, child_ids) do
    shot_index = Enum.find_index(shots, &(Map.get(&1, "id") == shot_id))
    original_shot = Enum.at(shots, shot_index)
    final_child_id = List.last(child_ids)

    with :ok <- ensure_split_source(original_shot, shot_id),
         :ok <- ensure_original_condition_not_self_referencing(original_shot, shot_id),
         {:ok, rewritten_shots, dependency_updates} <-
           rewrite_split_dependencies(shots, shot_id, final_child_id),
         {:ok, rewritten_shots, condition_updates} <-
           rewrite_split_conditions(rewritten_shots, shot_id, final_child_id),
         child_shots = split_child_shots(original_shot, shot_id, child_ids),
         {before_shots, [_removed | after_shots]} = Enum.split(rewritten_shots, shot_index),
         dependent_ids = dependent_ids(shots, shot_id) do
      {:ok, Map.put(document, "shots", before_shots ++ child_shots ++ after_shots),
       %{
         dependent_ids: dependent_ids,
         updated_dependencies: dependency_updates,
         updated_conditions: condition_updates
       }}
    end
  end

  defp ensure_split_source(%{"kind" => "slug"}, _shot_id), do: :ok

  defp ensure_split_source(_shot, shot_id) do
    invalid("shot split only supports slug shots", %{shot_id: shot_id})
  end

  defp ensure_original_condition_not_self_referencing(%{"condition" => condition}, shot_id)
       when is_binary(condition) do
    case Condition.shot_references(condition, authoring_aliases?: true) do
      {:ok, refs} ->
        if shot_id in refs do
          invalid("shot split refuses self-referential source conditions", %{shot_id: shot_id})
        else
          :ok
        end

      {:error, %Error{} = error} ->
        if String.contains?(condition, shot_id) do
          invalid("shot split cannot preserve unsupported source condition syntax", %{
            shot_id: shot_id,
            condition_error: error.message
          })
        else
          :ok
        end
    end
  end

  defp ensure_original_condition_not_self_referencing(_shot, _shot_id), do: :ok

  defp rewrite_split_dependencies(shots, shot_id, final_child_id) do
    {rewritten, updates} =
      Enum.map_reduce(shots, 0, fn shot, count ->
        if Map.get(shot, "id") == shot_id do
          {shot, count}
        else
          rename_dependencies(shot, shot_id, final_child_id, count)
        end
      end)

    {:ok, rewritten, updates}
  end

  defp rewrite_split_conditions(shots, shot_id, final_child_id) do
    Enum.reduce_while(shots, {:ok, [], 0}, fn shot, {:ok, rewritten, condition_count} ->
      if Map.get(shot, "id") == shot_id do
        {:cont, {:ok, [shot | rewritten], condition_count}}
      else
        case rename_condition(shot, shot_id, final_child_id) do
          {:ok, shot, true} -> {:cont, {:ok, [shot | rewritten], condition_count + 1}}
          {:ok, shot, false} -> {:cont, {:ok, [shot | rewritten], condition_count}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end
    end)
    |> case do
      {:ok, rewritten, condition_count} -> {:ok, Enum.reverse(rewritten), condition_count}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp dependent_ids(shots, shot_id) do
    shots
    |> Enum.reject(&(Map.get(&1, "id") == shot_id))
    |> Enum.filter(fn shot -> shot_id in Map.get(shot, "depends_on", []) end)
    |> Enum.map(&Map.fetch!(&1, "id"))
  end

  defp split_child_shots(original_shot, source_id, child_ids) do
    total = length(child_ids)

    child_ids
    |> Enum.with_index()
    |> Enum.map(fn {child_id, index} ->
      original_shot
      |> Map.put("id", child_id)
      |> put_split_dependencies(original_shot, child_ids, index)
      |> put_split_condition(original_shot, index)
      |> put_split_prompt(source_id, child_id, index, total)
      |> put_split_output_schema(original_shot, index, total)
      |> put_split_metadata(source_id, child_id, index, total)
    end)
  end

  defp put_split_dependencies(shot, original_shot, _child_ids, 0) do
    Map.put(shot, "depends_on", Map.get(original_shot, "depends_on", []))
  end

  defp put_split_dependencies(shot, _original_shot, child_ids, index) do
    Map.put(shot, "depends_on", [Enum.at(child_ids, index - 1)])
  end

  defp put_split_condition(shot, original_shot, 0) do
    case Map.fetch(original_shot, "condition") do
      {:ok, condition} -> Map.put(shot, "condition", condition)
      :error -> Map.delete(shot, "condition")
    end
  end

  defp put_split_condition(shot, _original_shot, _index), do: Map.delete(shot, "condition")

  defp put_split_prompt(shot, source_id, child_id, index, total) do
    original_prompt = Map.get(shot, "prompt", "")

    prompt =
      [
        "Draft split #{index + 1}/#{total} from #{source_id} as #{child_id}.",
        "Refine this child shot before approval.",
        "",
        "Original prompt:",
        original_prompt
      ]
      |> Enum.join("\n")
      |> String.trim()

    Map.put(shot, "prompt", prompt)
  end

  defp put_split_output_schema(shot, original_shot, index, total) do
    if index == total - 1 do
      case Map.fetch(original_shot, "output_schema") do
        {:ok, schema} -> Map.put(shot, "output_schema", schema)
        :error -> Map.delete(shot, "output_schema")
      end
    else
      Map.delete(shot, "output_schema")
    end
  end

  defp put_split_metadata(shot, source_id, child_id, index, total) do
    metadata =
      shot
      |> Map.get("metadata", %{})
      |> normalize_metadata_map()
      |> Map.drop(["review", "approval", "last_reviewed"])
      |> Map.put("purpose", "Draft split child #{index + 1}/#{total} from #{source_id}.")
      |> Map.put("generated_by", %{
        "tool" => "twelvgaige",
        "command" => "shot split",
        "version" => Twelvgaige.version(),
        "source" => %{
          "kind" => "split",
          "id" => source_id,
          "path" => child_id
        }
      })

    Map.put(shot, "metadata", metadata)
  end

  defp normalize_metadata_map(metadata) when is_map(metadata), do: metadata
  defp normalize_metadata_map(_metadata), do: %{}

  defp merge_document_shots(%{"shots" => shots} = document, source_ids, new_id)
       when is_list(shots) do
    ids = Enum.map(shots, &Map.get(&1, "id"))
    missing = Enum.reject(source_ids, &(&1 in ids))

    cond do
      new_id in ids ->
        invalid("merged shot id already exists", %{new_id: new_id})

      missing != [] ->
        invalid("source shot id was not found", %{source_ids: missing})

      true ->
        do_merge_document_shots(document, shots, source_ids, new_id)
    end
  end

  defp merge_document_shots(_document, _source_ids, _new_id) do
    invalid("workflow shell is missing shots")
  end

  defp do_merge_document_shots(document, shots, source_ids, new_id) do
    source_set = MapSet.new(source_ids)

    source_shots =
      Enum.map(source_ids, &Enum.find(shots, fn shot -> Map.get(shot, "id") == &1 end))

    with :ok <- ensure_merge_sources(source_shots, source_ids),
         :ok <- ensure_merge_chain(source_shots),
         :ok <- ensure_merge_conditions(source_shots, source_ids),
         {:ok, merged_shot} <- merged_shot(source_shots, source_ids, new_id),
         {:ok, rewritten_shots, dependency_updates} <-
           rewrite_merge_dependencies(shots, source_set, new_id),
         {:ok, rewritten_shots, condition_updates} <-
           rewrite_merge_conditions(rewritten_shots, source_ids, new_id),
         dependent_ids = merge_dependent_ids(shots, source_set),
         merged_shots = replace_sources_with_merged(rewritten_shots, source_set, merged_shot) do
      {:ok, Map.put(document, "shots", merged_shots),
       %{
         dependent_ids: dependent_ids,
         updated_dependencies: dependency_updates,
         updated_conditions: condition_updates
       }}
    end
  end

  defp ensure_merge_sources(source_shots, source_ids) do
    cond do
      Enum.any?(source_shots, &(Map.get(&1, "kind") != "slug")) ->
        invalid("shot merge only supports slug shots", %{source_ids: source_ids})

      source_shots |> Enum.map(&Map.get(&1, "agent")) |> Enum.uniq() |> length() != 1 ->
        invalid("shot merge requires all source shots to use the same agent", %{
          source_ids: source_ids
        })

      true ->
        :ok
    end
  end

  defp ensure_merge_chain(source_shots) do
    source_shots
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find(fn [left, right] ->
      Map.get(left, "id") not in Map.get(right, "depends_on", [])
    end)
    |> case do
      nil ->
        :ok

      [left, right] ->
        invalid("shot merge requires source shots to form a dependency chain", %{
          left: Map.get(left, "id"),
          right: Map.get(right, "id")
        })
    end
  end

  defp ensure_merge_conditions(source_shots, source_ids) do
    source_set = MapSet.new(source_ids)

    with :ok <- ensure_no_source_condition_references(source_shots, source_set),
         :ok <- ensure_compatible_source_conditions(source_shots) do
      :ok
    end
  end

  defp ensure_no_source_condition_references(source_shots, source_set) do
    Enum.reduce_while(source_shots, :ok, fn shot, :ok ->
      case Map.get(shot, "condition", true) do
        condition when is_binary(condition) ->
          case Condition.shot_references(condition, authoring_aliases?: true) do
            {:ok, refs} ->
              if Enum.any?(refs, &MapSet.member?(source_set, &1)) do
                {:halt,
                 invalid("shot merge refuses source conditions that reference merged shots", %{
                   shot_id: Map.get(shot, "id")
                 })}
              else
                {:cont, :ok}
              end

            {:error, %Error{} = error} ->
              if Enum.any?(source_set, &String.contains?(condition, &1)) do
                {:halt,
                 invalid("shot merge cannot preserve unsupported source condition syntax", %{
                   shot_id: Map.get(shot, "id"),
                   condition_error: error.message
                 })}
              else
                {:cont, :ok}
              end
          end

        _condition ->
          {:cont, :ok}
      end
    end)
  end

  defp ensure_compatible_source_conditions(source_shots) do
    conditions = source_shots |> Enum.map(&Map.get(&1, "condition", true)) |> Enum.uniq()

    if length(conditions) == 1 do
      :ok
    else
      invalid("shot merge requires compatible source conditions")
    end
  end

  defp merged_shot(source_shots, source_ids, new_id) do
    first = List.first(source_shots)
    last = List.last(source_shots)

    with {:ok, output_schema} <- merged_output_schema(source_shots, source_ids) do
      merged =
        first
        |> Map.put("id", new_id)
        |> Map.put("depends_on", merge_dependencies(source_shots, source_ids))
        |> put_merged_condition(first)
        |> Map.put("tools", merge_tools(source_shots))
        |> Map.put("prompt", merged_prompt(source_shots))
        |> put_optional_value("output_schema", output_schema)
        |> Map.put("metadata", merged_metadata(source_ids, new_id, last))

      {:ok, merged}
    end
  end

  defp merge_dependencies(source_shots, source_ids) do
    source_set = MapSet.new(source_ids)

    source_shots
    |> Enum.flat_map(&Map.get(&1, "depends_on", []))
    |> Enum.reject(&MapSet.member?(source_set, &1))
    |> Enum.uniq()
  end

  defp put_merged_condition(shot, first) do
    case Map.get(first, "condition", true) do
      true -> Map.delete(shot, "condition")
      condition -> Map.put(shot, "condition", condition)
    end
  end

  defp merge_tools(source_shots) do
    source_shots
    |> Enum.flat_map(&Map.get(&1, "tools", []))
    |> Enum.uniq()
  end

  defp merged_prompt(source_shots) do
    source_shots
    |> Enum.map(fn shot ->
      """
      ## #{Map.fetch!(shot, "id")}

      #{Map.get(shot, "prompt", "")}
      """
      |> String.trim()
    end)
    |> Enum.join("\n\n")
    |> then(&("Merged from source shots. Refine before approval.\n\n" <> &1))
  end

  defp merged_output_schema(source_shots, source_ids) do
    schemas =
      source_shots
      |> Enum.map(&Map.get(&1, "output_schema"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case schemas do
      [] ->
        {:ok, nil}

      [schema] ->
        {:ok, schema}

      _schemas ->
        invalid("shot merge requires compatible output schemas", %{source_ids: source_ids})
    end
  end

  defp put_optional_value(map, key, nil), do: Map.delete(map, key)
  defp put_optional_value(map, key, value), do: Map.put(map, key, value)

  defp merged_metadata(source_ids, new_id, last) do
    last
    |> Map.get("metadata", %{})
    |> normalize_metadata_map()
    |> Map.drop(["review", "approval", "last_reviewed"])
    |> Map.put("purpose", "Draft merge of #{Enum.join(source_ids, ", ")}.")
    |> Map.put("generated_by", %{
      "tool" => "twelvgaige",
      "command" => "shot merge",
      "version" => Twelvgaige.version(),
      "source" => %{
        "kind" => "merge",
        "id" => new_id,
        "path" => Enum.join(source_ids, ",")
      }
    })
  end

  defp rewrite_merge_dependencies(shots, source_set, new_id) do
    {rewritten, count} =
      Enum.map_reduce(shots, 0, fn shot, count ->
        cond do
          MapSet.member?(source_set, Map.get(shot, "id")) ->
            {shot, count}

          is_list(Map.get(shot, "depends_on")) ->
            deps = Map.get(shot, "depends_on")
            updates = Enum.count(deps, &MapSet.member?(source_set, &1))

            rewritten_deps =
              deps
              |> Enum.map(&if(MapSet.member?(source_set, &1), do: new_id, else: &1))
              |> Enum.uniq()

            {Map.put(shot, "depends_on", rewritten_deps), count + updates}

          true ->
            {shot, count}
        end
      end)

    {:ok, rewritten, count}
  end

  defp rewrite_merge_conditions(shots, source_ids, new_id) do
    Enum.reduce_while(shots, {:ok, [], 0}, fn shot, {:ok, rewritten, condition_count} ->
      if Map.get(shot, "id") in source_ids do
        {:cont, {:ok, [shot | rewritten], condition_count}}
      else
        case rewrite_merge_condition(shot, source_ids, new_id) do
          {:ok, shot, true} -> {:cont, {:ok, [shot | rewritten], condition_count + 1}}
          {:ok, shot, false} -> {:cont, {:ok, [shot | rewritten], condition_count}}
          {:error, %Error{} = error} -> {:halt, {:error, error}}
        end
      end
    end)
    |> case do
      {:ok, rewritten, condition_count} -> {:ok, Enum.reverse(rewritten), condition_count}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp rewrite_merge_condition(shot, source_ids, new_id) do
    Enum.reduce_while(source_ids, {:ok, shot, false}, fn source_id, {:ok, shot, updated?} ->
      case rename_condition(shot, source_id, new_id) do
        {:ok, shot, changed?} -> {:cont, {:ok, shot, updated? or changed?}}
        {:error, %Error{} = error} -> {:halt, {:error, error}}
      end
    end)
  end

  defp merge_dependent_ids(shots, source_set) do
    shots
    |> Enum.reject(&MapSet.member?(source_set, Map.get(&1, "id")))
    |> Enum.filter(fn shot ->
      shot
      |> Map.get("depends_on", [])
      |> Enum.any?(&MapSet.member?(source_set, &1))
    end)
    |> Enum.map(&Map.fetch!(&1, "id"))
  end

  defp replace_sources_with_merged(shots, source_set, merged_shot) do
    {merged, _inserted?} =
      Enum.reduce(shots, {[], false}, fn shot, {acc, inserted?} ->
        cond do
          MapSet.member?(source_set, Map.get(shot, "id")) and not inserted? ->
            {[merged_shot | acc], true}

          MapSet.member?(source_set, Map.get(shot, "id")) ->
            {acc, inserted?}

          true ->
            {[shot | acc], inserted?}
        end
      end)

    Enum.reverse(merged)
  end

  defp normalize_output_schema(schema) do
    with {:ok, %Schema{root: root}} <- Schema.from_map(schema) do
      {:ok, root}
    end
  end

  defp set_document_schema(%{"shots" => shots} = document, shot_id, schema) when is_list(shots) do
    ids = Enum.map(shots, &Map.get(&1, "id"))

    if shot_id in ids do
      {updated, previous_schema} =
        Enum.map_reduce(shots, nil, fn shot, previous_schema ->
          if Map.get(shot, "id") == shot_id do
            {Map.put(shot, "output_schema", schema), Map.get(shot, "output_schema")}
          else
            {shot, previous_schema}
          end
        end)

      {:ok, Map.put(document, "shots", updated), previous_schema}
    else
      invalid("shot id was not found", %{shot_id: shot_id})
    end
  end

  defp set_document_schema(_document, _shot_id, _schema) do
    invalid("workflow shell is missing shots")
  end

  defp replace_document_agent(%{"shots" => shots} = document, old_agent, new_agent)
       when is_list(shots) do
    if old_agent == new_agent do
      invalid("replacement agent must be different from the current agent", %{agent: old_agent})
    else
      {updated, changed_shot_ids} =
        Enum.map_reduce(shots, [], fn shot, changed_shot_ids ->
          if Map.get(shot, "agent") == old_agent do
            {Map.put(shot, "agent", new_agent), [Map.fetch!(shot, "id") | changed_shot_ids]}
          else
            {shot, changed_shot_ids}
          end
        end)

      case Enum.reverse(changed_shot_ids) do
        [] ->
          invalid("no shots reference the old agent", %{old_agent: old_agent})

        changed_shot_ids ->
          {:ok, Map.put(document, "shots", updated), changed_shot_ids}
      end
    end
  end

  defp replace_document_agent(_document, _old_agent, _new_agent) do
    invalid("workflow shell is missing shots")
  end

  defp replace_document_tool(%{"shots" => shots} = document, old_tool, new_tool)
       when is_list(shots) do
    if old_tool == new_tool do
      invalid("replacement tool must be different from the current tool", %{tool: old_tool})
    else
      {updated, changed_shot_ids} =
        Enum.map_reduce(shots, [], fn shot, changed_shot_ids ->
          tools = Map.get(shot, "tools", [])

          if is_list(tools) and old_tool in tools do
            replaced_tools =
              tools
              |> Enum.map(&if(&1 == old_tool, do: new_tool, else: &1))
              |> Enum.uniq()

            {Map.put(shot, "tools", replaced_tools), [Map.fetch!(shot, "id") | changed_shot_ids]}
          else
            {shot, changed_shot_ids}
          end
        end)

      case Enum.reverse(changed_shot_ids) do
        [] ->
          invalid("no shots reference the old tool", %{old_tool: old_tool})

        changed_shot_ids ->
          {:ok, Map.put(document, "shots", updated), changed_shot_ids}
      end
    end
  end

  defp replace_document_tool(_document, _old_tool, _new_tool) do
    invalid("workflow shell is missing shots")
  end

  defp gate_document_shot(%{"shots" => shots} = document, target_id, gate_id, opts)
       when is_list(shots) do
    ids = Enum.map(shots, &Map.get(&1, "id"))

    cond do
      target_id not in ids ->
        invalid("target shot id was not found", %{target_id: target_id})

      gate_id in ids ->
        invalid("gate shot id already exists", %{gate_id: gate_id})

      true ->
        do_gate_document_shot(document, shots, target_id, gate_id, opts)
    end
  end

  defp gate_document_shot(_document, _target_id, _gate_id, _opts) do
    invalid("workflow shell is missing shots")
  end

  defp do_gate_document_shot(document, shots, target_id, gate_id, opts) do
    target_index = Enum.find_index(shots, &(Map.get(&1, "id") == target_id))
    target = Enum.at(shots, target_index)
    original_dependencies = Map.get(target, "depends_on", [])
    gate = gate_shot(gate_id, target_id, original_dependencies, opts)
    updated_target = Map.put(target, "depends_on", [gate_id])
    updated_shots = List.replace_at(shots, target_index, updated_target)
    gated_shots = insert_at(updated_shots, target_index, gate)

    {:ok, Map.put(document, "shots", gated_shots),
     %{
       original_dependencies: original_dependencies,
       gate_dependencies: original_dependencies,
       target_dependencies: [gate_id],
       gate_index: target_index,
       target_index: target_index + 1
     }}
  end

  defp gate_shot(gate_id, target_id, dependencies, opts) do
    %{
      "id" => gate_id,
      "kind" => "safety",
      "description" => Keyword.get(opts, :description, "Human approval before #{target_id}"),
      "depends_on" => non_empty(dependencies),
      "prompt" =>
        Keyword.get(
          opts,
          :prompt,
          "Review the prior shot outputs and approve before the next write-capable shot runs."
        )
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp non_empty([]), do: nil
  defp non_empty(values), do: values
end
