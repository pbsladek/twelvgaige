defmodule Twelvgaige.Workspace.Manager do
  @moduledoc "Owns isolated workspace leases and enforces one writer per workspace."

  use GenServer

  alias Twelvgaige.Workspace
  alias Twelvgaige.Workspace.Git
  alias Twelvgaige.Workspace.Set
  alias Twelvgaige.Operations.Store, as: OperationsStore

  @far_future ~U[9999-12-31 23:59:59Z]

  defstruct [:root, :operations_store, workspaces: %{}, writer_leases: %{}, sets: %{}]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: name)
  end

  def create(repository, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:create, repository, opts}, :infinity)
  end

  def get(workspace_id, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:get, workspace_id})
  end

  def bind_owner(workspace_id, session_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:bind_owner, workspace_id, session_id}
    )
  end

  def finalize(workspace_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:finalize, workspace_id, opts},
      :infinity
    )
  end

  def create_set(repositories, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:create_set, repositories, opts},
      :infinity
    )
  end

  def get_set(set_id, opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:get_set, set_id})

  def finalize_set(set_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:finalize_set, set_id, opts},
      :infinity
    )
  end

  @impl true
  def init(opts) do
    root = opts |> Keyword.fetch!(:root) |> Path.expand()

    case File.mkdir_p(root) do
      :ok ->
        case File.chmod(root, 0o700) do
          :ok ->
            {:ok,
             %__MODULE__{
               root: root,
               operations_store: Keyword.get(opts, :operations_store)
             }}

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:create, repository, opts}, _from, state) do
    {reply, state} = create_workspace(repository, opts, state)
    {:reply, reply, state}
  end

  def handle_call({:create_set, repositories, opts}, _from, state) do
    set_id = Keyword.get(opts, :set_id, "wsset_" <> random_id())
    owner_session_id = Keyword.fetch!(opts, :owner_session_id)

    with :ok <- valid_set_id(set_id),
         false <- Map.has_key?(state.sets, set_id),
         {:ok, repository_entries} <- normalize_repositories(repositories),
         {:ok, created, state} <- create_repository_set(repository_entries, set_id, opts, state) do
      set = %Set{
        id: set_id,
        owner_session_id: owner_session_id,
        repositories: created,
        created_at: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
      }

      case persist_set(set, :active, state) do
        :ok ->
          {:reply, {:ok, set}, put_in(state.sets[set_id], set)}

        {:error, reason} ->
          Enum.each(created, fn {_name, workspace} -> File.rm_rf(workspace.path) end)

          {:reply, {:error, {:workspace_set_persistence_failed, reason}},
           drop_workspaces(state, Map.values(created))}
      end
    else
      true -> {:reply, {:error, :workspace_set_conflict}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:get_set, set_id}, _from, state),
    do: {:reply, Map.fetch(state.sets, set_id), state}

  def handle_call({:finalize_set, set_id, opts}, _from, state) do
    case Map.fetch(state.sets, set_id) do
      {:ok, set} ->
        case finalize_repositories(set.repositories, opts, state) do
          {:ok, repositories, reports, state} ->
            finalized = %{
              set
              | repositories: repositories,
                finalized_at: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
            }

            provenance = %{
              inputs: Set.input_commits(finalized),
              outputs: Set.output_commits(finalized),
              repositories: reports
            }

            case persist_set(finalized, :finalized, state) do
              :ok ->
                {:reply, {:ok, finalized, provenance}, put_in(state.sets[set_id], finalized)}

              {:error, reason} ->
                {:reply, {:error, {:workspace_set_persistence_failed, reason}}, state}
            end

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :workspace_set_not_found}, state}
    end
  end

  def handle_call({:get, workspace_id}, _from, state) do
    {:reply, Map.fetch(state.workspaces, workspace_id), state}
  end

  def handle_call({:bind_owner, workspace_id, session_id}, _from, state) do
    with {:ok, workspace} <- Map.fetch(state.workspaces, workspace_id),
         :ok <- writer_available(state, workspace_id, session_id, workspace.writable) do
      workspace = %{workspace | owner_session_id: session_id}

      state =
        state
        |> put_in([Access.key!(:workspaces), workspace_id], workspace)
        |> maybe_put_writer(workspace_id, session_id, workspace.writable)

      {:reply, {:ok, workspace}, state}
    else
      :error -> {:reply, {:error, :workspace_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:finalize, workspace_id, opts}, _from, state) do
    case Map.fetch(state.workspaces, workspace_id) do
      {:ok, workspace} ->
        with {:ok, status} <- Git.status(workspace.path, opts),
             {:ok, diff} <- Git.diff(workspace.path, opts),
             {:ok, head_commit} <- Git.resolve_commit(workspace.path, "HEAD", opts) do
          finalized = %{
            workspace
            | dirty: String.trim(status) != "",
              head_commit: head_commit,
              finalized_at: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
          }

          state =
            state
            |> put_in([Access.key!(:workspaces), workspace_id], finalized)
            |> update_in([Access.key!(:writer_leases)], &Map.delete(&1, workspace_id))

          {:reply, {:ok, finalized, %{status: status, diff: diff}}, state}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :workspace_not_found}, state}
    end
  end

  defp create_workspace(repository, opts, state) do
    transport = Keyword.get(opts, :transport, :copy_snapshot)
    interactive? = Keyword.get(opts, :interactive?, false)
    workspace_id = Keyword.get(opts, :workspace_id, Twelvgaige.ID.new(:workspace))

    with :ok <- valid_workspace_id(workspace_id),
         false <- Map.has_key?(state.workspaces, workspace_id),
         :ok <- admit_transport(transport, interactive?),
         {:ok, commit} <-
           Git.resolve_commit(repository, Keyword.get(opts, :base_ref, "HEAD"), opts),
         path <- Path.join(state.root, workspace_id),
         :ok <- create_transport(transport, repository, path, commit, opts) do
      workspace =
        Workspace.new(
          id: workspace_id,
          round_id: Keyword.get(opts, :round_id),
          shot_id: Keyword.get(opts, :shot_id),
          attempt: Keyword.get(opts, :attempt),
          repository: repository,
          base_ref: Keyword.get(opts, :base_ref, "HEAD"),
          base_commit: commit,
          transport: transport,
          path: path,
          writable: Keyword.get(opts, :writable, true),
          allowed_paths: Keyword.get(opts, :allowed_paths, []),
          created_at: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
        )

      {{:ok, workspace}, put_in(state.workspaces[workspace_id], workspace)}
    else
      true -> {{:error, :workspace_id_conflict}, state}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp admit_transport(:copy_snapshot, _interactive?), do: :ok
  defp admit_transport(:bind_worktree, true), do: :ok
  defp admit_transport(:bind_worktree, false), do: {:error, :bind_worktree_requires_interactive}
  defp admit_transport(_transport, _interactive?), do: {:error, :unsupported_workspace_transport}

  defp valid_workspace_id(id) when is_binary(id) do
    if Regex.match?(~r/^ws_[A-Za-z0-9_-]+$/, id),
      do: :ok,
      else: {:error, :workspace_id_invalid}
  end

  defp valid_workspace_id(_id), do: {:error, :workspace_id_invalid}

  defp valid_set_id(id) when is_binary(id) do
    if Regex.match?(~r/^wsset_[A-Za-z0-9_-]+$/, id),
      do: :ok,
      else: {:error, :workspace_set_id_invalid}
  end

  defp valid_set_id(_id), do: {:error, :workspace_set_id_invalid}

  defp normalize_repositories(repositories) when is_map(repositories) do
    normalize_repositories(Map.to_list(repositories))
  end

  defp normalize_repositories(repositories) when is_list(repositories) do
    result =
      Enum.reduce_while(repositories, {:ok, []}, fn
        {name, path}, {:ok, acc} when is_binary(path) ->
          name = to_string(name)

          if Regex.match?(~r/^[A-Za-z0-9_-]+$/, name) do
            {:cont, {:ok, [{name, Path.expand(path)} | acc]}}
          else
            {:halt, {:error, :workspace_repository_name_invalid}}
          end

        _entry, _acc ->
          {:halt, {:error, :workspace_repositories_invalid}}
      end)

    case result do
      {:ok, []} ->
        {:error, :workspace_repositories_empty}

      {:ok, entries} ->
        entries = Enum.reverse(entries)

        if entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> length() == length(entries),
          do: {:ok, entries},
          else: {:error, :workspace_repository_duplicate}

      error ->
        error
    end
  end

  defp normalize_repositories(_repositories), do: {:error, :workspace_repositories_invalid}

  defp create_repository_set(entries, set_id, opts, state) do
    Enum.reduce_while(entries, {:ok, %{}, state, []}, fn {name, repository},
                                                         {:ok, created, current, paths} ->
      workspace_id = "ws_" <> set_id <> "_" <> name

      workspace_opts =
        opts
        |> Keyword.put(:workspace_id, workspace_id)
        |> Keyword.put(:writable, true)

      case create_workspace(repository, workspace_opts, current) do
        {{:ok, workspace}, next} ->
          owner_session_id = Keyword.fetch!(opts, :owner_session_id)
          workspace = %{workspace | owner_session_id: owner_session_id}

          next =
            next
            |> put_in([Access.key!(:workspaces), workspace.id], workspace)
            |> maybe_put_writer(workspace.id, owner_session_id, workspace.writable)

          {:cont, {:ok, Map.put(created, name, workspace), next, [workspace.path | paths]}}

        {{:error, reason}, _unchanged} ->
          Enum.each(paths, &File.rm_rf/1)
          rolled_back = drop_workspaces(current, Map.values(created))
          {:halt, {:error, {:workspace_set_create_failed, name, reason}, rolled_back}}
      end
    end)
    |> case do
      {:ok, created, next, _paths} -> {:ok, created, next}
      {:error, reason, _rolled_back} -> {:error, reason}
    end
  end

  defp finalize_repositories(repositories, opts, state) do
    Enum.reduce_while(repositories, {:ok, %{}, %{}, state}, fn {name, workspace},
                                                               {:ok, completed, reports, current} ->
      case finalize_workspace(workspace, opts, current) do
        {:ok, finalized, report, next} ->
          {:cont,
           {:ok, Map.put(completed, name, finalized), Map.put(reports, name, report), next}}

        {:error, reason} ->
          {:halt, {:error, {:workspace_set_finalize_failed, name, reason}}}
      end
    end)
  end

  defp finalize_workspace(workspace, opts, state) do
    with {:ok, status} <- Git.status(workspace.path, opts),
         {:ok, diff} <- Git.diff(workspace.path, opts),
         {:ok, head_commit} <- Git.resolve_commit(workspace.path, "HEAD", opts) do
      finalized = %{
        workspace
        | dirty: String.trim(status) != "",
          head_commit: head_commit,
          finalized_at: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
      }

      next =
        state
        |> put_in([Access.key!(:workspaces), workspace.id], finalized)
        |> update_in([Access.key!(:writer_leases)], &Map.delete(&1, workspace.id))

      {:ok, finalized, %{status: status, diff: diff}, next}
    end
  end

  defp drop_workspaces(state, workspaces) do
    Enum.reduce(workspaces, state, fn workspace, acc ->
      %{
        acc
        | workspaces: Map.delete(acc.workspaces, workspace.id),
          writer_leases: Map.delete(acc.writer_leases, workspace.id)
      }
    end)
  end

  defp persist_set(_set, _status, %{operations_store: nil}), do: :ok

  defp persist_set(set, status, state) do
    repositories =
      Map.new(set.repositories, fn {name, workspace} ->
        {name,
         %{
           repository: workspace.repository,
           workspace_id: workspace.id,
           base_ref: workspace.base_ref,
           base_commit: workspace.base_commit,
           resulting_commit: workspace.head_commit
         }}
      end)

    record = %{
      schema_version: set.schema_version,
      set_id: set.id,
      owner_session_id: set.owner_session_id,
      status: status,
      created_at: set.created_at,
      finalized_at: set.finalized_at,
      inputs: Set.input_commits(set),
      outputs: Set.output_commits(set),
      repositories: repositories
    }

    store_opts = [
      server: state.operations_store,
      retention_class: :security,
      now: set.finalized_at || set.created_at
    ]

    store_opts =
      if status == :active,
        do: Keyword.put(store_opts, :hold_until, @far_future),
        else: store_opts

    OperationsStore.put(:workspace_set_provenance, set.id, record, store_opts)
  end

  defp random_id,
    do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  defp create_transport(:copy_snapshot, repository, path, commit, opts),
    do: Git.create_snapshot(repository, path, commit, Keyword.get(opts, :allowed_paths, []), opts)

  defp create_transport(:bind_worktree, repository, path, commit, opts),
    do: Git.create_worktree(repository, path, commit, opts)

  defp writer_available(_state, _workspace_id, _session_id, false), do: :ok

  defp writer_available(state, workspace_id, session_id, true) do
    case Map.get(state.writer_leases, workspace_id) do
      nil -> :ok
      ^session_id -> :ok
      _other -> {:error, :workspace_writer_already_leased}
    end
  end

  defp maybe_put_writer(state, _workspace_id, _session_id, false), do: state

  defp maybe_put_writer(state, workspace_id, session_id, true),
    do: put_in(state.writer_leases[workspace_id], session_id)
end
