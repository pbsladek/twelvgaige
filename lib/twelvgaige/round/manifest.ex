defmodule Twelvgaige.Round.Manifest do
  @moduledoc """
  Immutable run manifest used by recovery.

  The manifest snapshots the workflow that was accepted at round creation time.
  Recovery must use this stored workflow, not whatever file or registry entry
  happens to exist when the daemon restarts.
  """

  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Workflow

  @schema_version 1

  @type source :: %{optional(atom()) => term()} | %{optional(String.t()) => term()} | nil

  @type t :: %__MODULE__{
          schema_version: pos_integer(),
          round_id: String.t(),
          shell_id: String.t(),
          shell_version: String.t(),
          workflow: Workflow.t(),
          workflow_hash: String.t(),
          agent_hashes: %{String.t() => String.t()},
          agent_sources: [source()],
          effective_resource_profile: atom() | String.t() | nil,
          source: source(),
          created_at: DateTime.t() | String.t() | nil
        }

  @enforce_keys [:round_id, :shell_id, :shell_version, :workflow, :workflow_hash]
  defstruct [
    :round_id,
    :shell_id,
    :shell_version,
    :workflow,
    :workflow_hash,
    :agent_hashes,
    :agent_sources,
    :effective_resource_profile,
    :source,
    :created_at,
    schema_version: @schema_version
  ]

  @doc "Builds a manifest from atom-key or string-key attributes."
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    workflow = normalize_workflow!(required!(attrs, :workflow))
    agents = value(attrs, :agents, [])
    agent_paths = value(attrs, :agent_paths, value(attrs, :agent_shell_paths, []))

    %__MODULE__{
      schema_version: value(attrs, :schema_version, @schema_version),
      round_id: required!(attrs, :round_id),
      shell_id: value(attrs, :shell_id, workflow.id),
      shell_version: value(attrs, :shell_version, workflow.version),
      workflow: workflow,
      workflow_hash: value(attrs, :workflow_hash, workflow_hash(workflow)),
      agent_hashes: value(attrs, :agent_hashes, agent_hashes(agents)),
      agent_sources: value(attrs, :agent_sources, sources_for(agent_paths)),
      effective_resource_profile: value(attrs, :effective_resource_profile, nil),
      source: value(attrs, :source, nil),
      created_at: value(attrs, :created_at, nil)
    }
  end

  @doc """
  Returns the stored workflow after validating the manifest hash when present.

  Legacy manifest maps without a workflow hash are accepted so existing durable
  test fixtures and early file stores remain readable.
  """
  @spec workflow(t() | map()) ::
          {:ok, Workflow.t()}
          | {:error,
             :manifest_missing_workflow | :manifest_invalid_workflow | :manifest_hash_mismatch}
  def workflow(%__MODULE__{workflow: workflow, workflow_hash: expected_hash}) do
    with {:ok, workflow} <- normalize_workflow(workflow),
         :ok <- verify_hash(workflow, expected_hash) do
      {:ok, workflow}
    end
  end

  def workflow(%{} = manifest) do
    with {:ok, workflow} <- fetch_workflow(manifest),
         :ok <- verify_hash(workflow, value(manifest, :workflow_hash, nil)) do
      {:ok, workflow}
    end
  end

  @doc "Returns a stable SHA-256 hash for a normalized workflow snapshot."
  @spec workflow_hash(Workflow.t()) :: String.t()
  def workflow_hash(%Workflow{} = workflow), do: shell_hash(workflow)

  @doc "Returns stable SHA-256 hashes for normalized agent snapshots."
  @spec agent_hashes([Agent.t() | map()]) :: %{String.t() => String.t()}
  def agent_hashes(agents) when is_list(agents) do
    agents
    |> Enum.flat_map(fn
      %Agent{id: id} = agent when is_binary(id) -> [{id, shell_hash(agent)}]
      %{} = agent -> agent_id_hash(agent)
      _other -> []
    end)
    |> Map.new()
  end

  def agent_hashes(_agents), do: %{}

  @doc "Normalizes source metadata for accepted workflow or agent inputs."
  @spec sources_for([term()] | term()) :: [source()]
  def sources_for(values) when is_list(values),
    do: values |> Enum.map(&source_for/1) |> Enum.reject(&is_nil/1)

  def sources_for(nil), do: []
  def sources_for(value), do: sources_for([value])

  @doc "Normalizes source metadata for accepted workflow or agent input."
  @spec source_for(term()) :: source()
  def source_for(path) when is_binary(path) do
    expanded = Path.expand(path)

    %{
      type: :path,
      path: expanded,
      format: path |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    }
    |> put_file_hash(expanded)
  end

  def source_for(%Workflow{} = workflow),
    do: %{type: :workflow_struct, shell_hash: workflow_hash(workflow)}

  def source_for(%Agent{} = agent),
    do: %{type: :agent_struct, shell_id: agent.id, shell_hash: shell_hash(agent)}

  def source_for(%{} = map), do: %{type: :shell_map, content_hash: term_hash(map)}
  def source_for(_other), do: nil

  defp shell_hash(shell), do: term_hash(shell)

  defp term_hash(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term))
    |> Base.encode16(case: :lower)
  end

  defp file_hash(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, :sha256 |> :crypto.hash(contents) |> Base.encode16(case: :lower)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp put_file_hash(source, path) do
    case file_hash(path) do
      {:ok, hash} -> Map.put(source, :content_hash, hash)
      {:error, reason} -> Map.put(source, :content_hash_error, inspect(reason))
    end
  end

  defp agent_id_hash(%{} = agent) do
    id = Map.get(agent, :id, Map.get(agent, "id"))

    if is_binary(id) do
      [{id, shell_hash(agent)}]
    else
      []
    end
  end

  defp fetch_workflow(manifest) do
    case value(manifest, :workflow, nil) do
      nil -> {:error, :manifest_missing_workflow}
      workflow -> normalize_workflow(workflow)
    end
  end

  defp verify_hash(_workflow, nil), do: :ok
  defp verify_hash(_workflow, ""), do: :ok

  defp verify_hash(%Workflow{} = workflow, expected_hash) when is_binary(expected_hash) do
    if workflow_hash(workflow) == expected_hash do
      :ok
    else
      {:error, :manifest_hash_mismatch}
    end
  end

  defp verify_hash(_workflow, _expected_hash), do: {:error, :manifest_hash_mismatch}

  defp normalize_workflow!(workflow) do
    case normalize_workflow(workflow) do
      {:ok, workflow} -> workflow
      {:error, reason} -> raise ArgumentError, "invalid workflow manifest: #{inspect(reason)}"
    end
  end

  defp normalize_workflow(%Workflow{} = workflow), do: {:ok, workflow}

  defp normalize_workflow(%{} = workflow) do
    case Workflow.from_map(workflow) do
      {:ok, %Workflow{} = workflow} -> {:ok, workflow}
      {:error, _reason} -> {:error, :manifest_invalid_workflow}
    end
  end

  defp normalize_workflow(_workflow), do: {:error, :manifest_invalid_workflow}

  defp required!(attrs, key) do
    case value(attrs, key, :__missing__) do
      :__missing__ -> raise ArgumentError, "missing required round manifest field: #{key}"
      value -> value
    end
  end

  defp value(attrs, key, default) when is_list(attrs) do
    Keyword.get(attrs, key, default)
  end

  defp value(attrs, key, default) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
