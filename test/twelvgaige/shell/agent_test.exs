defmodule Twelvgaige.Shell.AgentTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Agent

  test "builds an agent shell from a map" do
    assert {:ok, agent} =
             Agent.from_map(%{
               "kind" => "agent",
               "id" => "incident_analyst",
               "name" => "Incident Analyst",
               "version" => "1.0.0",
               "provider" => "mock",
               "model" => "mock-model",
               "system_prompt" => "Analyze the incident.",
               "tools" => %{"allowed" => ["kubectl_get"], "denied" => ["kubectl_delete"]},
               "choke" => %{"token_budget" => 4096, "max_iterations" => 2, "timeout" => "30s"},
               "memory" => %{"type" => "none"}
             })

    assert agent.id == "incident_analyst"
    assert agent.provider == "mock"
    assert agent.tools.allowed == ["kubectl_get"]
    assert agent.tools.denied == ["kubectl_delete"]
    assert agent.choke.timeout_ms == 30_000
    assert agent.memory.type == :none
  end

  test "rejects unknown providers" do
    assert {:error, error} =
             Agent.from_map(%{
               kind: :agent,
               id: "agent",
               provider: "not_real",
               model: "model",
               system_prompt: "Prompt"
             })

    assert error.reason == :invalid_shell
    assert error.details.path == ["provider"]
  end
end
