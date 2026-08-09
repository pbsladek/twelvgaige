defmodule Twelvgaige.LoadoutTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Loadout
  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Workflow

  test "resolves provider, model, and system prompt from a referenced agent shell" do
    {:ok, agent} =
      Agent.from_map(%{
        kind: :agent,
        id: "inspector",
        version: "1.0.0",
        provider: "mock",
        model: "agent-model",
        system_prompt: "Agent prompt"
      })

    shot = shot!("inspector")

    assert Loadout.for_shot(shot, agents: [agent]) == %{
             provider: "mock",
             model: "agent-model",
             system_prompt: "Agent prompt",
             choke: agent.choke,
             tool_policy: agent.tools
           }
  end

  test "falls back to runner defaults when no agent registry is supplied" do
    shot = shot!("inspector")

    assert Loadout.for_shot(shot, model: "fallback-model").model == "fallback-model"
    assert Loadout.for_shot(shot).provider == :mock
  end

  defp shot!(agent_id) do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "loadout_workflow",
        version: "1.0.0",
        shots: [%{id: "only", kind: :slug, agent: agent_id}]
      })

    hd(workflow.shots)
  end
end
