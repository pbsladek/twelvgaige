defmodule Twelvgaige.Shell.Agent.Tools do
  @moduledoc false

  alias Twelvgaige.Shell.Validation, as: V

  @keys ~w(allowed denied)

  @type t :: %__MODULE__{allowed: [String.t()], denied: [String.t()]}

  defstruct allowed: [], denied: []

  @spec from_map(term(), [term()]) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(nil, _path), do: {:ok, %__MODULE__{}}

  def from_map(map, path) do
    with {:ok, map} <- V.map(map, path),
         :ok <- V.known_keys(map, @keys, path),
         {:ok, allowed} <- V.optional_slug_list(map, :allowed, [], path),
         {:ok, denied} <- V.optional_slug_list(map, :denied, [], path) do
      {:ok, %__MODULE__{allowed: allowed, denied: denied}}
    end
  end
end

defmodule Twelvgaige.Shell.Agent.Choke do
  @moduledoc false

  alias Twelvgaige.Shell.Validation, as: V

  @keys ~w(token_budget max_iterations timeout)

  @type t :: %__MODULE__{
          token_budget: pos_integer() | nil,
          max_iterations: pos_integer(),
          timeout_ms: pos_integer() | nil
        }

  defstruct token_budget: nil, max_iterations: 6, timeout_ms: nil

  @spec from_map(term(), [term()]) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(nil, _path), do: {:ok, %__MODULE__{}}

  def from_map(map, path) do
    with {:ok, map} <- V.map(map, path),
         :ok <- V.known_keys(map, @keys, path),
         {:ok, token_budget} <- V.optional_positive_integer(map, :token_budget, nil, path),
         {:ok, max_iterations} <- V.optional_positive_integer(map, :max_iterations, 6, path),
         {:ok, timeout_ms} <- V.optional_duration_ms(map, :timeout, nil, path) do
      {:ok,
       %__MODULE__{
         token_budget: token_budget,
         max_iterations: max_iterations,
         timeout_ms: timeout_ms
       }}
    end
  end
end

defmodule Twelvgaige.Shell.Agent.Memory do
  @moduledoc false

  alias Twelvgaige.Shell.Validation, as: V

  @keys ~w(type)

  @type t :: %__MODULE__{type: :none}

  defstruct type: :none

  @spec from_map(term(), [term()]) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(nil, _path), do: {:ok, %__MODULE__{}}

  def from_map(map, path) do
    with {:ok, map} <- V.map(map, path),
         :ok <- V.known_keys(map, @keys, path),
         {:ok, type} <- V.optional_enum(map, :type, [:none], :none, path) do
      {:ok, %__MODULE__{type: type}}
    end
  end
end

defmodule Twelvgaige.Shell.Agent do
  @moduledoc """
  Declarative agent shell loaded from a validated map.
  """

  alias Twelvgaige.Shell.Agent.Choke
  alias Twelvgaige.Shell.Agent.Memory
  alias Twelvgaige.Shell.Agent.Tools
  alias Twelvgaige.Shell.Validation, as: V

  @keys ~w(kind id name version provider model system_prompt tools choke memory)
  @providers ~w(openai ollama) ++ Application.compile_env(:twelvgaige, :test_provider_ids, [])

  @type t :: %__MODULE__{
          kind: :agent,
          id: String.t(),
          name: String.t() | nil,
          version: String.t() | nil,
          provider: String.t(),
          model: String.t(),
          system_prompt: String.t(),
          tools: Tools.t(),
          choke: Choke.t(),
          memory: Memory.t()
        }

  defstruct [
    :id,
    :name,
    :version,
    :provider,
    :model,
    :system_prompt,
    kind: :agent,
    tools: %Tools{},
    choke: %Choke{},
    memory: %Memory{}
  ]

  @spec from_map(term()) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(map) do
    with {:ok, map} <- V.map(map, []),
         :ok <- V.known_keys(map, @keys, []),
         {:ok, :agent} <- V.required_enum(map, :kind, [:agent], []),
         {:ok, id} <- V.required_slug(map, :id, []),
         {:ok, name} <- V.optional_non_empty_string(map, :name, []),
         {:ok, version} <- V.optional_semver(map, :version, []),
         {:ok, provider} <- V.required_string_enum(map, :provider, @providers, []),
         {:ok, model} <- V.required_non_empty_string(map, :model, []),
         {:ok, system_prompt} <- V.required_non_empty_string(map, :system_prompt, []),
         {:ok, tools} <- Tools.from_map(V.optional(map, :tools, nil), ["tools"]),
         {:ok, choke} <- Choke.from_map(V.optional(map, :choke, nil), ["choke"]),
         {:ok, memory} <- Memory.from_map(V.optional(map, :memory, nil), ["memory"]) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         version: version,
         provider: provider,
         model: model,
         system_prompt: system_prompt,
         tools: tools,
         choke: choke,
         memory: memory
       }}
    end
  end
end
