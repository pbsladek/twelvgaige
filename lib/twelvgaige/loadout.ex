defmodule Twelvgaige.Loadout do
  @moduledoc """
  Resolves the effective executor loadout for a workflow shot.

  Agent shells own provider, model, and system prompt selection. When no agent
  registry is supplied, Twelvgaige uses the local Ollama provider. Test builds
  use a deterministic internal provider instead.
  """

  alias Twelvgaige.Shell.Agent

  @default_system_prompt "You are running a Twelvgaige foreground shot."
  @test_providers Application.compile_env(:twelvgaige, :test_provider_ids, [])
  @default_provider if("mock" in @test_providers, do: :mock, else: :ollama)
  @default_model if("mock" in @test_providers, do: "mock-model", else: "llama3.2")

  @spec for_shot(term(), keyword()) :: map()
  def for_shot(shot, opts \\ []) do
    fallback = fallback_loadout(opts)

    case agent_for_shot(shot, opts) do
      nil -> fallback
      agent -> agent_loadout(agent, fallback)
    end
  end

  defp fallback_loadout(opts) do
    %{
      provider: Keyword.get(opts, :provider, @default_provider),
      model: Keyword.get(opts, :model, @default_model),
      system_prompt: Keyword.get(opts, :system_prompt, @default_system_prompt),
      choke: %{},
      tool_policy: nil
    }
  end

  defp agent_for_shot(shot, opts) do
    shot
    |> value(:agent)
    |> case do
      nil -> nil
      agent_id -> Map.get(normalize_agents(Keyword.get(opts, :agents)), to_string(agent_id))
    end
  end

  defp normalize_agents(nil), do: %{}

  defp normalize_agents(%Agent{id: id} = agent), do: %{id => agent}

  defp normalize_agents(%{} = agents) do
    if map_has_id?(agents) do
      id = value(agents, :id)
      %{to_string(id) => agents}
    else
      Map.new(agents, fn {id, agent} -> {to_string(id), agent} end)
    end
  end

  defp normalize_agents(agents) when is_list(agents) do
    Map.new(agents, fn
      %Agent{id: id} = agent ->
        {id, agent}

      %{} = agent ->
        id = value(agent, :id)
        {to_string(id), agent}

      id ->
        {to_string(id), nil}
    end)
  end

  defp normalize_agents(_agents), do: %{}

  defp map_has_id?(%{} = map), do: Map.has_key?(map, :id) or Map.has_key?(map, "id")

  defp agent_loadout(agent, fallback) do
    %{
      provider: value(agent, :provider, fallback.provider),
      model: value(agent, :model, fallback.model),
      system_prompt: value(agent, :system_prompt, fallback.system_prompt),
      choke: value(agent, :choke, %{}),
      tool_policy: value(agent, :tools, nil)
    }
  end

  defp value(term, key, default \\ nil)

  defp value(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_term, _key, default), do: default
end
