defmodule Twelvgaige.Manager.Envelope do
  @moduledoc "Previously approved authority within which a manager may create children automatically."

  alias Twelvgaige.Manager.Budget

  defstruct [
    :budget,
    :deadline,
    repositories: MapSet.new(),
    agents: MapSet.new(),
    workflows: MapSet.new(),
    auth_profiles: MapSet.new(),
    sandbox_profiles: MapSet.new(),
    network_modes: MapSet.new(),
    capabilities: MapSet.new(),
    mounts: MapSet.new(),
    allowed_paths: [],
    max_depth: 1,
    max_children: 16,
    max_fanout: 4
  ]

  def new(attrs) when is_map(attrs) or is_list(attrs) do
    with {:ok, budget} <- Budget.new(value(attrs, :budget, %{})) do
      {:ok,
       %__MODULE__{
         budget: budget,
         deadline: value(attrs, :deadline, nil),
         repositories: set(attrs, :repositories),
         agents: set(attrs, :agents),
         workflows: set(attrs, :workflows),
         auth_profiles: set(attrs, :auth_profiles),
         sandbox_profiles: set(attrs, :sandbox_profiles),
         network_modes: set(attrs, :network_modes),
         capabilities: set(attrs, :capabilities),
         mounts: set(attrs, :mounts),
         allowed_paths: value(attrs, :allowed_paths, []),
         max_depth: value(attrs, :max_depth, 1),
         max_children: value(attrs, :max_children, 16),
         max_fanout: value(attrs, :max_fanout, 4)
       }}
    end
  end

  defp set(attrs, key), do: attrs |> value(key, []) |> enumerable() |> MapSet.new()
  defp enumerable(%MapSet{} = set), do: MapSet.to_list(set)
  defp enumerable(map) when is_map(map), do: Map.keys(map)
  defp enumerable(list) when is_list(list), do: list
  defp enumerable(value) when is_nil(value), do: []
  defp enumerable(value), do: [value]

  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
