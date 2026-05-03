defmodule Twelvgaige do
  @moduledoc """
  Public API for Twelvgaige.

  Twelvgaige executes deterministic rounds where Elixir owns control flow and
  LLMs produce bounded shot results.
  """

  @type round_id :: String.t()
  @type shot_id :: String.t()
  @type shell_id :: String.t()

  alias Twelvgaige.Breech
  alias Twelvgaige.Breech.Daemon
  alias Twelvgaige.Breech.IPC.Client, as: IPCClient
  alias Twelvgaige.Breech.IPC.Endpoint, as: IPCEndpoint
  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Server
  alias Twelvgaige.Shell

  @doc """
  Runs a workflow shell synchronously in the current BEAM.

  Phase 1 accepts a `%Twelvgaige.Shell.Workflow{}`, a workflow map, or a
  workflow shell path.
  """
  @spec run_round_sync(Shell.Workflow.t() | map() | Path.t(), map(), keyword()) ::
          {:ok, Twelvgaige.Round.Snapshot.t()} | {:error, term()}
  def run_round_sync(shell_or_path, input, opts \\ [])

  def run_round_sync(%Shell.Workflow{} = workflow, input, opts) when is_map(input) do
    Server.run_sync(workflow, input, opts)
  end

  def run_round_sync(%{} = workflow_map, input, opts) when is_map(input) do
    with {:ok, workflow} <- Shell.Workflow.from_map(workflow_map) do
      Server.run_sync(workflow, input, opts)
    end
  end

  def run_round_sync(path, input, opts) when is_binary(path) and is_map(input) do
    agent_paths = Shell.Loader.agent_shell_paths_for_workflow(path, opts)

    agent_opts =
      opts
      |> Keyword.put(:agent_shell_paths, agent_paths)
      |> Keyword.put(:discover_agents?, false)

    with {:ok, %Shell.Workflow{} = workflow} <- Shell.Loader.load(path, opts),
         {:ok, agents} <- Shell.Loader.load_agents_for_workflow(path, agent_opts) do
      opts =
        opts
        |> put_discovered_agents(agents)
        |> put_manifest_provenance(path, agent_paths, agents)

      Server.run_sync(workflow, input, opts)
    end
  end

  @doc """
  Validates and loads a shell file.
  """
  @spec validate_shell(Path.t(), keyword()) :: {:ok, Shell.t()} | {:error, term()}
  def validate_shell(path, opts \\ []) when is_binary(path) do
    Shell.Loader.load(path, opts)
  end

  @doc """
  Lists workflow shells loaded in the configured shell cache.
  """
  @spec list_shells(keyword()) :: {:ok, [Shell.Workflow.t()]} | {:error, term()}
  def list_shells(opts \\ []) do
    Shell.Cache.list_workflows(shell_cache_opts(opts))
  end

  @doc """
  Returns a workflow or agent shell loaded in the configured shell cache.
  """
  @spec get_shell(shell_id(), keyword()) :: {:ok, Shell.t()} | {:error, term()}
  def get_shell(id, opts \\ []) when is_binary(id) do
    cache_opts = shell_cache_opts(opts)

    case normalize_shell_kind(Keyword.get(opts, :kind, :any)) do
      :workflow ->
        Shell.Cache.get_workflow(id, cache_opts)

      :agent ->
        Shell.Cache.get_agent(id, cache_opts)

      :any ->
        case Shell.Cache.get_workflow(id, cache_opts) do
          {:ok, workflow} ->
            {:ok, workflow}

          {:error, workflow_error} ->
            case Shell.Cache.get_agent(id, cache_opts) do
              {:ok, agent} -> {:ok, agent}
              {:error, _agent_error} -> {:error, workflow_error}
            end
        end
    end
  end

  @doc """
  Lists agent shells loaded in the configured shell cache.
  """
  @spec list_agents(keyword()) :: {:ok, [Shell.Agent.t()]} | {:error, term()}
  def list_agents(opts \\ []) do
    Shell.Cache.list_agents(shell_cache_opts(opts))
  end

  @doc """
  Reloads workflow and agent shells into the configured shell cache.
  """
  @spec reload_shells(keyword()) :: {:ok, map()} | {:error, term()}
  def reload_shells(opts \\ []) do
    Shell.Cache.reload(shell_cache_opts(opts))
  end

  @doc """
  Detached rounds require the Breech daemon, which is not part of Phase 1.
  """
  @spec run_round(shell_id() | Path.t(), map(), keyword()) ::
          {:ok, round_id()} | {:error, term()}
  def run_round(shell_or_path, input, opts \\ []) when is_map(input) do
    case ipc_address(opts) do
      {:ok, address} when is_binary(shell_or_path) ->
        IPCClient.start_round(address, shell_or_path, input, ipc_opts(opts))

      {:ok, _address} ->
        {:error, :invalid_ipc_request}

      :none ->
        Breech.start_round(shell_or_path, input, opts)

      {:error, _reason} = error ->
        error
    end
  end

  defp put_discovered_agents(opts, []), do: opts

  defp put_discovered_agents(opts, agents) do
    Keyword.update(opts, :agents, agents, fn existing_agents ->
      List.wrap(existing_agents) ++ agents
    end)
  end

  defp put_manifest_provenance(opts, workflow_path, agent_paths, agents) do
    opts
    |> Keyword.put(:workflow_source, Twelvgaige.Round.Manifest.source_for(workflow_path))
    |> Keyword.put(:agent_sources, Twelvgaige.Round.Manifest.sources_for(agent_paths))
    |> Keyword.put(:agent_hashes, Twelvgaige.Round.Manifest.agent_hashes(agents))
  end

  defp shell_cache_opts(opts) do
    []
    |> maybe_put_cache_server(Keyword.get(opts, :shell_cache))
    |> maybe_put_cache_paths(Keyword.get(opts, :paths))
  end

  defp maybe_put_cache_server(opts, nil), do: opts
  defp maybe_put_cache_server(opts, server), do: Keyword.put(opts, :server, server)

  defp maybe_put_cache_paths(opts, nil), do: opts
  defp maybe_put_cache_paths(opts, paths), do: Keyword.put(opts, :paths, paths)

  defp normalize_shell_kind(kind) when kind in [:workflow, "workflow"], do: :workflow
  defp normalize_shell_kind(kind) when kind in [:agent, "agent"], do: :agent
  defp normalize_shell_kind(_kind), do: :any

  @doc """
  Returns a daemon-owned round snapshot.
  """
  @spec get_round(round_id(), keyword()) ::
          {:ok, Twelvgaige.Round.Snapshot.t()} | {:error, :not_found | :daemon_unavailable}
  def get_round(round_id, opts \\ []) when is_binary(round_id) do
    case ipc_address(opts) do
      {:ok, address} -> IPCClient.get_round(address, round_id, ipc_opts(opts))
      :none -> Breech.get_round(round_id, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Lists daemon-owned round snapshots from the current store.
  """
  @spec list_rounds(keyword()) :: {:ok, [Twelvgaige.Round.Snapshot.t()]} | {:error, term()}
  def list_rounds(opts \\ []) do
    case ipc_address(opts) do
      {:ok, address} -> IPCClient.list_rounds(address, opts ++ ipc_opts(opts))
      :none -> Breech.list_rounds(opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Lists daemon-owned round events after an optional sequence cursor.
  """
  @spec list_round_events(round_id(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def list_round_events(round_id, opts \\ []) when is_binary(round_id) do
    case ipc_address(opts) do
      {:ok, address} -> IPCClient.list_round_events(address, round_id, opts ++ ipc_opts(opts))
      :none -> Breech.list_round_events(round_id, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Waits for committed daemon-owned round events after an optional sequence cursor.

  This is a bounded long-poll API used by pre-durable watch commands. It reads
  from explicit round events, never telemetry.
  """
  @spec await_round_events(round_id(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
  def await_round_events(round_id, opts \\ []) when is_binary(round_id) do
    case ipc_address(opts) do
      {:ok, address} -> IPCClient.await_round_events(address, round_id, opts ++ ipc_opts(opts))
      :none -> Breech.await_round_events(round_id, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Lists durable audit records for a daemon-owned round after an optional sequence cursor.
  """
  @spec list_audit_events(round_id(), keyword()) :: {:ok, [AuditEvent.t()]} | {:error, term()}
  def list_audit_events(round_id, opts \\ []) when is_binary(round_id) do
    case ipc_address(opts) do
      {:ok, address} -> IPCClient.list_audit_events(address, round_id, opts ++ ipc_opts(opts))
      :none -> Breech.list_audit_events(round_id, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Approves a daemon-owned safety shot.
  """
  @spec approve_safety(round_id(), shot_id(), keyword()) :: :ok | {:error, term()}
  def approve_safety(round_id, shot_id, opts \\ [])
      when is_binary(round_id) and is_binary(shot_id) do
    case ipc_address(opts) do
      {:ok, address} -> IPCClient.approve_safety(address, round_id, shot_id, ipc_opts(opts))
      :none -> Breech.approve_safety(round_id, shot_id, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Rejects a daemon-owned safety shot.
  """
  @spec reject_safety(round_id(), shot_id(), keyword()) :: :ok | {:error, term()}
  def reject_safety(round_id, shot_id, opts \\ [])
      when is_binary(round_id) and is_binary(shot_id) do
    case ipc_address(opts) do
      {:ok, address} -> IPCClient.reject_safety(address, round_id, shot_id, ipc_opts(opts))
      :none -> Breech.reject_safety(round_id, shot_id, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Cancels a daemon-owned round.
  """
  @spec cancel_round(round_id(), keyword()) :: :ok | {:error, term()}
  def cancel_round(round_id, opts \\ []) when is_binary(round_id) do
    case ipc_address(opts) do
      {:ok, address} -> IPCClient.cancel_round(address, round_id, ipc_opts(opts))
      :none -> Breech.cancel_round(round_id, opts)
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns local Breech daemon status.
  """
  @spec status(keyword()) :: {:ok, Breech.status()} | {:error, :daemon_unavailable}
  def status(opts \\ []) do
    case ipc_address(opts) do
      {:ok, address} ->
        IPCClient.status(address, ipc_opts(opts))

      :none ->
        opts
        |> Keyword.get(:server, Breech)
        |> Breech.status()

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  Requests the discovered Breech daemon IPC listener to stop.
  """
  @spec stop_daemon(keyword()) :: :ok | {:error, term()}
  def stop_daemon(opts \\ []) do
    case ipc_address(opts) do
      {:ok, address} -> IPCClient.stop_daemon(address, ipc_opts(opts))
      :none -> {:error, :daemon_unavailable}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Returns default local daemon paths for the current platform.
  """
  @spec daemon_paths(keyword()) :: map()
  def daemon_paths(opts \\ []), do: Daemon.paths(opts)

  @doc """
  Returns the application version from Mix project metadata.
  """
  @spec version() :: String.t()
  def version do
    Application.spec(:twelvgaige, :vsn)
    |> to_string()
  end

  defp ipc_address(opts) do
    cond do
      address = Keyword.get(opts, :ipc_addr) ->
        {:ok, address}

      address = System.get_env("TWELVGAIGE_BREECH_ADDR") ->
        IPCClient.parse_address(address)

      discover_breech?(opts) ->
        case IPCEndpoint.discover(endpoint_opts(opts)) do
          {:ok, endpoint} -> {:ok, endpoint.address}
          :none -> :none
          {:error, _reason} = error -> error
        end

      true ->
        :none
    end
  end

  defp ipc_opts(opts) do
    token =
      Keyword.get(opts, :token) || System.get_env("TWELVGAIGE_BREECH_TOKEN") ||
        discovered_token(opts)

    opts
    |> Keyword.take([
      :timeout_ms,
      :round_id,
      :profile,
      :resource_profile,
      :approve_all_safety?,
      :agent_shells,
      :discover_agents?,
      :trusted_root?,
      :untrusted_root?,
      :allow_untrusted_agent_discovery?,
      :allow_unsafe_tools_without_safety?,
      :status,
      :reason,
      :actor,
      :npipe_transport,
      :pipe_transport
    ])
    |> Keyword.merge(Keyword.take(opts, [:after_seq, :limit]))
    |> maybe_put_token(token)
  end

  defp maybe_put_token(opts, nil), do: opts
  defp maybe_put_token(opts, token), do: Keyword.put(opts, :token, token)

  defp discovered_token(opts) do
    if discover_breech?(opts) do
      case IPCEndpoint.discover(endpoint_opts(opts)) do
        {:ok, endpoint} -> endpoint.token
        _other -> nil
      end
    end
  end

  defp discover_breech?(opts) do
    Keyword.has_key?(opts, :endpoint_path) or
      Keyword.get(
        opts,
        :discover_breech?,
        Application.get_env(:twelvgaige, :discover_breech?, true)
      )
  end

  defp endpoint_opts(opts) do
    case Keyword.get(opts, :endpoint_path) || System.get_env("TWELVGAIGE_BREECH_ENDPOINT") do
      nil -> []
      path -> [path: path]
    end
  end
end
