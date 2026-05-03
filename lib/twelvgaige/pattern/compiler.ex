defmodule Twelvgaige.Pattern.Compiler do
  @moduledoc """
  Compiles workflow shells into deterministic execution patterns.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Pattern.Compiled
  alias Twelvgaige.Pattern.Condition
  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shot
  alias Twelvgaige.Tool.Catalog
  alias Twelvgaige.Tool.Safety

  @type shot :: Workflow.Shot.t()

  @spec compile(Workflow.t(), keyword()) :: {:ok, Compiled.t()} | {:error, Error.t()}
  def compile(%Workflow{} = workflow, opts \\ []) do
    shot_by_id = Map.new(workflow.shots, &{&1.id, &1})

    with :ok <- validate_unique_ids(workflow.shots),
         :ok <- validate_dependencies(workflow.shots, shot_by_id),
         :ok <- validate_conditions(workflow.shots),
         :ok <- validate_agent_references(workflow.shots, opts),
         :ok <- validate_tool_references(workflow.shots, opts),
         :ok <- validate_agent_tool_policy(workflow.shots, opts),
         :ok <- validate_safety_dependencies(workflow.shots, shot_by_id, opts),
         dependency_graph <- Map.new(workflow.shots, &{&1.id, &1.depends_on}),
         reverse_graph <- build_reverse_graph(workflow.shots),
         :ok <- validate_acyclic(dependency_graph) do
      {:ok,
       %Compiled{
         workflow_id: workflow.id,
         workflow_version: workflow.version,
         shots: workflow.shots,
         shot_by_id: shot_by_id,
         dependency_graph: dependency_graph,
         reverse_graph: reverse_graph
       }}
    end
  end

  defp validate_agent_references(shots, opts) do
    case known_agents(opts) do
      nil ->
        :ok

      agents ->
        Enum.reduce_while(shots, :ok, fn
          %{kind: :slug, agent: agent, id: shot_id}, :ok ->
            if Map.has_key?(agents, agent) do
              {:cont, :ok}
            else
              {:halt,
               {:error,
                Error.new(:compile_error, :unknown_agent, "shot references unknown agent",
                  details: %{shot_id: shot_id, agent: agent, known_agents: sorted_keys(agents)}
                )}}
            end

          _shot, :ok ->
            {:cont, :ok}
        end)
    end
  end

  defp validate_tool_references(shots, opts) do
    case known_tools(opts) do
      nil ->
        :ok

      tool_names ->
        Enum.reduce_while(shots, :ok, fn shot, :ok ->
          case Enum.find(shot.tools, &(&1 not in tool_names)) do
            nil ->
              {:cont, :ok}

            tool ->
              {:halt,
               {:error,
                Error.new(:compile_error, :unknown_tool, "shot references unknown tool",
                  details: %{shot_id: shot.id, tool: tool, known_tools: Enum.sort(tool_names)}
                )}}
          end
        end)
    end
  end

  defp validate_agent_tool_policy(shots, opts) do
    case known_agents(opts) do
      nil ->
        :ok

      agents ->
        Enum.reduce_while(shots, :ok, fn shot, :ok ->
          with {:ok, agent} <- Map.fetch(agents, shot.agent),
               {:ok, policy} <- tool_policy(agent) do
            validate_shot_tools_allowed_by_agent(shot, policy)
          else
            :error -> {:cont, :ok}
            :no_policy -> {:cont, :ok}
          end
        end)
    end
  end

  defp validate_safety_dependencies(shots, shot_by_id, opts) do
    if Keyword.get(opts, :allow_unsafe_tools_without_safety?, false) do
      :ok
    else
      tool_safety = tool_safety_levels(opts)

      Enum.reduce_while(shots, :ok, fn shot, :ok ->
        unsafe_tools = unsafe_tools(shot.tools, tool_safety)

        cond do
          unsafe_tools == [] ->
            {:cont, :ok}

          depends_on_unconditional_safety_shot?(shot, shot_by_id) ->
            {:cont, :ok}

          true ->
            {:halt,
             {:error,
              Error.new(
                :compile_error,
                :missing_safety_dependency,
                "shot with non-read-only tools must depend on an unconditional safety shot",
                details: %{shot_id: shot.id, tools: unsafe_tools}
              )}}
        end
      end)
    end
  end

  defp unsafe_tools(tools, tool_safety) do
    tools
    |> Enum.filter(fn tool -> non_read_only_tool?(Map.get(tool_safety, tool)) end)
    |> Enum.sort()
  end

  defp non_read_only_tool?(nil), do: false
  defp non_read_only_tool?(:read_only), do: false
  defp non_read_only_tool?(level), do: Safety.valid?(level)

  defp depends_on_unconditional_safety_shot?(shot, shot_by_id) do
    Enum.any?(shot.depends_on, fn dependency ->
      match?(%{kind: :safety, condition: true}, Map.get(shot_by_id, dependency))
    end)
  end

  defp tool_safety_levels(opts) do
    opts
    |> Keyword.get(:tool_catalog, Catalog)
    |> tool_names_from_catalog()
    |> Enum.reduce(%{}, fn tool, acc ->
      tool = tool_name(tool)

      case tool_metadata(tool, opts) do
        {:ok, %{safety_level: level}} -> Map.put(acc, tool, level)
        {:ok, %{"safety_level" => level}} -> Map.put(acc, tool, normalize_safety_level(level))
        _other -> acc
      end
    end)
  end

  defp tool_metadata(tool, opts) do
    catalog = Keyword.get(opts, :tool_catalog, Catalog)

    cond do
      is_atom(catalog) and Code.ensure_loaded?(catalog) and
          function_exported?(catalog, :metadata, 1) ->
        catalog.metadata(tool)

      catalog == Catalog ->
        Catalog.metadata(tool)

      true ->
        :error
    end
  end

  defp normalize_safety_level(level) when is_atom(level), do: level

  defp normalize_safety_level(level) when is_binary(level) do
    try do
      String.to_existing_atom(level)
    rescue
      ArgumentError -> level
    end
  end

  defp normalize_safety_level(level), do: level

  defp validate_shot_tools_allowed_by_agent(shot, %{allowed: allowed, denied: denied}) do
    allowed = MapSet.new(allowed)
    denied = MapSet.new(denied)

    case Enum.find(shot.tools, &MapSet.member?(denied, &1)) do
      nil ->
        case Enum.find(shot.tools, &(not MapSet.member?(allowed, &1))) do
          nil ->
            {:cont, :ok}

          tool ->
            {:halt,
             {:error,
              Error.new(:compile_error, :tool_denied, "shot tool is not allowed by agent",
                details: %{
                  shot_id: shot.id,
                  agent: shot.agent,
                  tool: tool,
                  allowed_tools: allowed |> MapSet.to_list() |> Enum.sort()
                }
              )}}
        end

      tool ->
        {:halt,
         {:error,
          Error.new(:compile_error, :tool_denied, "shot tool is denied by agent",
            details: %{shot_id: shot.id, agent: shot.agent, tool: tool}
          )}}
    end
  end

  defp known_agents(opts) do
    cond do
      Keyword.has_key?(opts, :agents) ->
        opts
        |> Keyword.fetch!(:agents)
        |> normalize_agents()

      Keyword.has_key?(opts, :agent_ids) ->
        opts
        |> Keyword.fetch!(:agent_ids)
        |> normalize_agent_ids()

      true ->
        nil
    end
  end

  defp known_tools(opts) do
    cond do
      Keyword.get(opts, :validate_tools?, true) == false ->
        nil

      Keyword.has_key?(opts, :known_tools) ->
        opts
        |> Keyword.fetch!(:known_tools)
        |> normalize_tool_names()

      true ->
        opts
        |> Keyword.get(:tool_catalog, Catalog)
        |> tool_names_from_catalog()
        |> normalize_tool_names()
    end
  end

  defp normalize_agents(agents) when is_list(agents) do
    Map.new(agents, fn
      %Agent{id: id} = agent ->
        {id, agent}

      %{} = agent ->
        id = Map.get(agent, :id, Map.get(agent, "id"))
        {to_string(id), agent}

      id ->
        {to_string(id), nil}
    end)
  end

  defp normalize_agents(_agents), do: %{}

  defp normalize_agent_ids(agent_ids) when is_list(agent_ids) do
    Map.new(agent_ids, fn id -> {to_string(id), nil} end)
  end

  defp normalize_agent_ids(_agent_ids), do: %{}

  defp normalize_tool_names(:catalog), do: normalize_tool_names(Catalog.names())

  defp normalize_tool_names(tools) when is_list(tools) do
    tools
    |> Enum.map(&tool_name/1)
    |> Enum.uniq()
  end

  defp normalize_tool_names(_tools), do: []

  defp tool_names_from_catalog(catalog) when is_atom(catalog) do
    if Code.ensure_loaded?(catalog) and function_exported?(catalog, :names, 0) do
      catalog.names()
    else
      []
    end
  end

  defp tool_names_from_catalog(names), do: names

  defp tool_name(tool) when is_atom(tool), do: Atom.to_string(tool)
  defp tool_name(tool) when is_binary(tool), do: tool

  defp tool_name(tool) when is_map(tool),
    do: Map.get(tool, :name, Map.get(tool, "name")) |> to_string()

  defp tool_name(tool), do: to_string(tool)

  defp tool_policy(%Agent{tools: %{allowed: allowed, denied: denied}}) do
    {:ok, %{allowed: allowed, denied: denied}}
  end

  defp tool_policy(%{tools: %{allowed: allowed, denied: denied}}) do
    {:ok, %{allowed: Enum.map(allowed, &to_string/1), denied: Enum.map(denied, &to_string/1)}}
  end

  defp tool_policy(%{"tools" => %{"allowed" => allowed, "denied" => denied}}) do
    {:ok, %{allowed: Enum.map(allowed, &to_string/1), denied: Enum.map(denied, &to_string/1)}}
  end

  defp tool_policy(nil), do: :no_policy
  defp tool_policy(_agent), do: :no_policy

  defp sorted_keys(map), do: map |> Map.keys() |> Enum.sort()

  @spec initially_ready(Compiled.t()) :: [shot()]
  def initially_ready(%Compiled{} = compiled) do
    Enum.filter(compiled.shots, fn shot ->
      shot.depends_on == [] and shot.condition == true
    end)
  end

  @spec ready_shots(Compiled.t(), %{String.t() => Shot.State.t()}, map()) ::
          {:ok, [shot()]} | {:error, Error.t()}
  def ready_shots(%Compiled{} = compiled, shot_states, context \\ %{}) do
    with {:ok, %{ready: ready}} <- readiness(compiled, shot_states, context) do
      {:ok, ready}
    end
  end

  @spec readiness(Compiled.t(), %{String.t() => Shot.State.t()}, map()) ::
          {:ok, %{ready: [shot()], skipped: [shot()]}} | {:error, Error.t()}
  def readiness(%Compiled{} = compiled, shot_states, context \\ %{}) do
    context = condition_context(context, shot_states)

    Enum.reduce_while(compiled.shots, {:ok, []}, fn shot, {:ok, ready} ->
      state = Map.get(shot_states, shot.id)

      cond do
        not startable_state?(state) ->
          {:cont, {:ok, ready}}

        not dependencies_complete?(shot, shot_states) ->
          {:cont, {:ok, ready}}

        true ->
          case Condition.evaluate(shot.condition, context) do
            {:ok, true} -> {:cont, {:ok, [shot | ready]}}
            {:ok, false} -> {:cont, {:ok, ready}}
            {:error, _error} = error -> {:halt, error}
          end
      end
    end)
    |> case do
      {:ok, ready} ->
        ready = Enum.reverse(ready)

        skipped =
          skippable_shots(
            compiled.shots,
            shot_states,
            context,
            MapSet.new(Enum.map(ready, & &1.id))
          )

        {:ok, %{ready: ready, skipped: skipped}}

      {:error, _error} = error ->
        error
    end
  end

  defp skippable_shots(shots, shot_states, context, ready_ids) do
    Enum.reduce_while(shots, [], fn shot, skipped ->
      state = Map.get(shot_states, shot.id)

      cond do
        MapSet.member?(ready_ids, shot.id) ->
          {:cont, skipped}

        not startable_state?(state) ->
          {:cont, skipped}

        not dependencies_complete?(shot, shot_states) ->
          {:cont, skipped}

        true ->
          case Condition.evaluate(shot.condition, context) do
            {:ok, false} -> {:cont, [shot | skipped]}
            {:ok, true} -> {:cont, skipped}
            {:error, _error} -> {:halt, skipped}
          end
      end
    end)
    |> Enum.reverse()
  end

  defp condition_context(context, shot_states) do
    input = Map.get(context, "input", Map.get(context, :input, %{}))

    shots =
      Map.new(shot_states, fn {shot_id, state} ->
        {shot_id, state.output}
      end)

    %{"input" => input, "shots" => shots}
  end

  defp validate_conditions(shots) do
    Enum.reduce_while(shots, :ok, fn shot, :ok ->
      case Condition.validate(shot.condition) do
        :ok ->
          {:cont, :ok}

        {:error, %Error{} = error} ->
          {:halt,
           {:error,
            %{
              error
              | details: Map.merge(error.details, %{shot_id: shot.id})
            }}}
      end
    end)
  end

  defp validate_unique_ids(shots) do
    ids = Enum.map(shots, & &1.id)

    case Enum.find(ids, fn id -> Enum.count(ids, &(&1 == id)) > 1 end) do
      nil ->
        :ok

      duplicate ->
        {:error,
         Error.new(:compile_error, :invalid_shell, "duplicate shot id",
           details: %{shot_id: duplicate}
         )}
    end
  end

  defp validate_dependencies(shots, shot_by_id) do
    Enum.reduce_while(shots, :ok, fn shot, :ok ->
      case Enum.find(shot.depends_on, &(not Map.has_key?(shot_by_id, &1))) do
        nil ->
          {:cont, :ok}

        missing ->
          {:halt,
           {:error,
            Error.new(:compile_error, :missing_dependency, "shot depends on unknown shot",
              details: %{shot_id: shot.id, dependency: missing}
            )}}
      end
    end)
  end

  defp build_reverse_graph(shots) do
    initial = Map.new(shots, &{&1.id, []})

    Enum.reduce(shots, initial, fn shot, graph ->
      Enum.reduce(shot.depends_on, graph, fn dependency, acc ->
        Map.update!(acc, dependency, &[shot.id | &1])
      end)
    end)
  end

  defp validate_acyclic(dependency_graph) do
    all_nodes = Map.keys(dependency_graph)

    ready =
      dependency_graph
      |> Enum.filter(fn {_id, deps} -> deps == [] end)
      |> Enum.map(&elem(&1, 0))

    visited = visit_ready(ready, dependency_graph, %{})

    if map_size(visited) == length(all_nodes) do
      :ok
    else
      {:error,
       Error.new(:compile_error, :cycle_detected, "workflow dependency graph contains a cycle",
         details: %{remaining: all_nodes -- Map.keys(visited)}
       )}
    end
  end

  defp visit_ready([], _graph, visited), do: visited

  defp visit_ready([node | rest], graph, visited) do
    if Map.has_key?(visited, node) do
      visit_ready(rest, graph, visited)
    else
      visited = Map.put(visited, node, true)

      newly_ready =
        graph
        |> Enum.reject(fn {id, _deps} -> Map.has_key?(visited, id) end)
        |> Enum.filter(fn {_id, deps} -> Enum.all?(deps, &Map.has_key?(visited, &1)) end)
        |> Enum.map(&elem(&1, 0))

      visit_ready(rest ++ newly_ready, graph, visited)
    end
  end

  defp startable_state?(nil), do: false

  defp startable_state?(%Shot.State{} = state),
    do: Shot.State.startable?(state, Twelvgaige.Clock.utc_now())

  defp dependencies_complete?(shot, shot_states) do
    Enum.all?(shot.depends_on, fn dependency ->
      case Map.fetch(shot_states, dependency) do
        {:ok, state} -> Shot.State.terminal_success?(state)
        :error -> false
      end
    end)
  end
end
