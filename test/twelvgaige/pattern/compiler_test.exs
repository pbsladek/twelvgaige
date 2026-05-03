defmodule Twelvgaige.Pattern.CompilerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Pattern.Compiler
  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shot

  defp workflow(shots) do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "pattern_test",
        version: "1.0.0",
        shots: shots
      })

    workflow
  end

  test "compiles a DAG and returns initial ready shots" do
    {:ok, compiled} =
      workflow([
        %{id: "a", kind: :slug, agent: "agent"},
        %{id: "b", kind: :slug, agent: "agent", depends_on: ["a"]},
        %{id: "c", kind: :slug, agent: "agent"}
      ])
      |> Compiler.compile()

    assert compiled.workflow_id == "pattern_test"
    assert Map.keys(compiled.shot_by_id) == ["a", "b", "c"]
    assert Enum.map(Compiler.initially_ready(compiled), & &1.id) == ["a", "c"]
  end

  test "rejects duplicate shot IDs at the compiler boundary" do
    shell =
      workflow([
        %{id: "a", kind: :slug, agent: "agent"},
        %{id: "b", kind: :slug, agent: "agent"}
      ])

    [a, b] = shell.shots
    duplicated = %{shell | shots: [a, %{b | id: "a"}]}

    assert {:error, error} = Compiler.compile(duplicated)
    assert error.reason == :invalid_shell
    assert error.details.shot_id == "a"
  end

  test "rejects missing dependencies" do
    assert {:error, error} =
             workflow([
               %{id: "a", kind: :slug, agent: "agent", depends_on: ["missing"]}
             ])
             |> Compiler.compile()

    assert error.reason == :missing_dependency
    assert error.details.dependency == "missing"
  end

  test "rejects unknown agents when agent references are supplied" do
    assert {:error, error} =
             workflow([
               %{id: "a", kind: :slug, agent: "missing_agent"}
             ])
             |> Compiler.compile(agent_ids: ["known_agent"])

    assert error.reason == :unknown_agent
    assert error.details.shot_id == "a"
    assert error.details.agent == "missing_agent"
    assert error.details.known_agents == ["known_agent"]
  end

  test "rejects unknown tools against the tool catalog by default" do
    assert {:error, error} =
             workflow([
               %{id: "a", kind: :slug, agent: "agent", tools: ["missing_tool"]}
             ])
             |> Compiler.compile()

    assert error.reason == :unknown_tool
    assert error.details.shot_id == "a"
    assert error.details.tool == "missing_tool"
    assert "shell_read" in error.details.known_tools
  end

  test "validates shot tools against the referenced agent policy when agents are supplied" do
    {:ok, agent} =
      Agent.from_map(%{
        kind: :agent,
        id: "agent",
        version: "1.0.0",
        provider: "mock",
        model: "mock-model",
        system_prompt: "test",
        tools: %{allowed: ["shell_read"], denied: ["http_get"]}
      })

    assert {:ok, _compiled} =
             workflow([
               %{id: "a", kind: :slug, agent: "agent", tools: ["shell_read"]}
             ])
             |> Compiler.compile(agents: [agent])

    assert {:error, denied} =
             workflow([
               %{id: "a", kind: :slug, agent: "agent", tools: ["http_get"]}
             ])
             |> Compiler.compile(agents: [agent])

    assert denied.reason == :tool_denied
    assert denied.details.tool == "http_get"

    assert {:error, not_allowed} =
             workflow([
               %{id: "a", kind: :slug, agent: "agent", tools: ["kubectl_get"]}
             ])
             |> Compiler.compile(agents: [agent])

    assert not_allowed.reason == :tool_denied
    assert not_allowed.details.tool == "kubectl_get"
    assert not_allowed.details.allowed_tools == ["shell_read"]
  end

  test "requires non-read-only tool shots to depend on a safety shot" do
    assert {:error, error} =
             workflow([
               %{
                 id: "scale",
                 kind: :slug,
                 agent: "agent",
                 tools: ["kubectl_scale"],
                 choke: %{tool_safety: :idempotent_write}
               }
             ])
             |> Compiler.compile()

    assert error.reason == :missing_safety_dependency
    assert error.details.shot_id == "scale"
    assert error.details.tools == ["kubectl_scale"]
  end

  test "allows non-read-only tool shots with a direct safety dependency" do
    assert {:ok, _compiled} =
             workflow([
               %{id: "approval", kind: :safety},
               %{
                 id: "scale",
                 kind: :slug,
                 agent: "agent",
                 depends_on: ["approval"],
                 tools: ["kubectl_scale"],
                 choke: %{tool_safety: :idempotent_write}
               }
             ])
             |> Compiler.compile()
  end

  test "rejects non-read-only tool shots that only depend on a conditional safety shot" do
    assert {:error, error} =
             workflow([
               %{id: "approval", kind: :safety, condition: false},
               %{
                 id: "scale",
                 kind: :slug,
                 agent: "agent",
                 depends_on: ["approval"],
                 tools: ["kubectl_scale"],
                 choke: %{tool_safety: :idempotent_write}
               }
             ])
             |> Compiler.compile()

    assert error.reason == :missing_safety_dependency
    assert error.details.shot_id == "scale"
    assert error.details.tools == ["kubectl_scale"]
  end

  test "allows local development override for non-read-only tool safety dependency" do
    assert {:ok, _compiled} =
             workflow([
               %{
                 id: "scale",
                 kind: :slug,
                 agent: "agent",
                 tools: ["kubectl_scale"],
                 choke: %{tool_safety: :idempotent_write}
               }
             ])
             |> Compiler.compile(allow_unsafe_tools_without_safety?: true)
  end

  test "rejects cycles" do
    assert {:ok, shell} =
             Workflow.from_map(%{
               kind: :workflow,
               id: "cycle",
               version: "1.0.0",
               shots: [
                 %{id: "a", kind: :slug, agent: "agent"},
                 %{id: "b", kind: :slug, agent: "agent", depends_on: ["a"]}
               ]
             })

    cyclic = %{
      shell
      | shots: [
          %{Enum.at(shell.shots, 0) | depends_on: ["b"]},
          Enum.at(shell.shots, 1)
        ]
    }

    assert {:error, error} = Compiler.compile(cyclic)
    assert error.reason == :cycle_detected
  end

  test "readiness returns all pending root shots" do
    {:ok, compiled} =
      workflow([
        %{id: "a", kind: :slug, agent: "agent"},
        %{id: "b", kind: :slug, agent: "agent"},
        %{id: "c", kind: :slug, agent: "agent", depends_on: ["a"]}
      ])
      |> Compiler.compile()

    states = pending_states(compiled)

    assert {:ok, %{ready: ready, skipped: []}} = Compiler.readiness(compiled, states)
    assert Enum.map(ready, & &1.id) == ["a", "b"]
  end

  test "readiness returns dependent shots only after dependencies complete" do
    {:ok, compiled} =
      workflow([
        %{id: "a", kind: :slug, agent: "agent"},
        %{id: "b", kind: :slug, agent: "agent", depends_on: ["a"]}
      ])
      |> Compiler.compile()

    pending = pending_states(compiled)

    assert {:ok, %{ready: [root]}} = Compiler.readiness(compiled, pending)
    assert root.id == "a"

    running_parent = Map.put(pending, "a", Shot.State.new(id: "a", kind: :slug, status: :running))

    assert {:ok, %{ready: []}} = Compiler.readiness(compiled, running_parent)

    complete_parent =
      Map.put(pending, "a", Shot.State.new(id: "a", kind: :slug, status: :complete))

    assert {:ok, %{ready: [dependent]}} = Compiler.readiness(compiled, complete_parent)
    assert dependent.id == "b"
  end

  test "ready_shots requires dependencies to be complete" do
    {:ok, compiled} =
      workflow([
        %{id: "a", kind: :slug, agent: "agent"},
        %{id: "b", kind: :slug, agent: "agent", depends_on: ["a"]}
      ])
      |> Compiler.compile()

    states = %{
      "a" => Shot.State.new(id: "a", kind: :slug, status: :complete),
      "b" => Shot.State.new(id: "b", kind: :slug)
    }

    assert {:ok, [ready]} = Compiler.ready_shots(compiled, states)
    assert ready.id == "b"
  end

  test "ready_shots evaluates string conditions against input and shot outputs" do
    {:ok, compiled} =
      workflow([
        %{id: "a", kind: :slug, agent: "agent"},
        %{
          id: "b",
          kind: :slug,
          agent: "agent",
          depends_on: ["a"],
          condition: "input.cluster == \"prod\" and shots.a.ok == true"
        }
      ])
      |> Compiler.compile()

    states = %{
      "a" => Shot.State.new(id: "a", kind: :slug, status: :complete, output: %{"ok" => true}),
      "b" => Shot.State.new(id: "b", kind: :slug)
    }

    assert {:ok, [ready]} =
             Compiler.ready_shots(compiled, states, %{input: %{"cluster" => "prod"}})

    assert ready.id == "b"
  end

  test "readiness returns shots skipped by false conditions" do
    {:ok, compiled} =
      workflow([
        %{id: "a", kind: :slug, agent: "agent", condition: "input.enabled == true"}
      ])
      |> Compiler.compile()

    states = %{"a" => Shot.State.new(id: "a", kind: :slug)}

    assert {:ok, %{ready: [], skipped: [skipped]}} =
             Compiler.readiness(compiled, states, %{input: %{"enabled" => false}})

    assert skipped.id == "a"
  end

  test "compile rejects invalid condition strings" do
    assert {:error, error} =
             workflow([
               %{id: "a", kind: :slug, agent: "agent", condition: "steps.x.ok == true"}
             ])
             |> Compiler.compile()

    assert error.reason == :unsupported_condition
    assert error.details.shot_id == "a"
  end

  test "generated cyclic DAGs are rejected" do
    for size <- 2..8 do
      shots =
        for index <- 1..size do
          dependency =
            if index == 1 do
              "shot_#{size}"
            else
              "shot_#{index - 1}"
            end

          %{id: "shot_#{index}", kind: :slug, agent: "agent", depends_on: [dependency]}
        end

      assert {:error, error} = workflow(shots) |> Compiler.compile()
      assert error.reason == :cycle_detected
    end
  end

  test "generated acyclic DAGs compile and readiness respects dependencies" do
    for size <- 1..10 do
      {:ok, compiled} =
        size
        |> generated_acyclic_shots()
        |> workflow()
        |> Compiler.compile()

      states = pending_states(compiled)
      {final_states, observed} = complete_by_readiness(compiled, states, MapSet.new(), size)

      assert observed == MapSet.new(Enum.map(compiled.shots, & &1.id))

      assert Enum.all?(final_states, fn {_id, state} ->
               Shot.State.terminal_success?(state)
             end)
    end
  end

  defp pending_states(compiled) do
    Map.new(compiled.shots, fn shot ->
      {shot.id, Shot.State.new(id: shot.id, kind: shot.kind)}
    end)
  end

  defp generated_acyclic_shots(size) do
    for index <- 1..size do
      depends_on =
        if index == 1 do
          []
        else
          1..(index - 1)
          |> Enum.filter(&(rem(index + &1, 3) == 0))
          |> Enum.take(2)
          |> Enum.map(&"shot_#{&1}")
        end

      %{id: "shot_#{index}", kind: :slug, agent: "agent", depends_on: depends_on}
    end
  end

  defp complete_by_readiness(compiled, states, observed, expected_count) do
    if MapSet.size(observed) == expected_count do
      {states, observed}
    else
      continue_by_readiness(compiled, states, observed, expected_count)
    end
  end

  defp continue_by_readiness(compiled, states, observed, expected_count) do
    assert {:ok, %{ready: ready}} = Compiler.readiness(compiled, states)
    assert ready != []

    Enum.each(ready, fn shot ->
      assert Enum.all?(shot.depends_on, fn dependency ->
               states
               |> Map.fetch!(dependency)
               |> Shot.State.terminal_success?()
             end)
    end)

    next_states =
      Enum.reduce(ready, states, fn shot, acc ->
        Map.put(acc, shot.id, Shot.State.new(id: shot.id, kind: shot.kind, status: :complete))
      end)

    next_observed = MapSet.union(observed, MapSet.new(Enum.map(ready, & &1.id)))

    complete_by_readiness(compiled, next_states, next_observed, expected_count)
  end
end
