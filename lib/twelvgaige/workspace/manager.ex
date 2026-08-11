defmodule Twelvgaige.Workspace.Manager do
  @moduledoc "Owns isolated workspace leases and enforces one writer per workspace."

  use GenServer

  alias Twelvgaige.Workspace
  alias Twelvgaige.Workspace.DirectApply
  alias Twelvgaige.Artifact.Store, as: ArtifactStore
  alias Twelvgaige.Lifecycle.FaultMatrix
  alias Twelvgaige.Workspace.Git.ManagedWorkspace
  alias Twelvgaige.Workspace.Git.SourceRead
  alias Twelvgaige.Workspace.Operation
  alias Twelvgaige.Workspace.Result
  alias Twelvgaige.Workspace.ResultManifest
  alias Twelvgaige.Workspace.RepositoryInspection
  alias Twelvgaige.Workspace.ReviewWorktree
  alias Twelvgaige.Workspace.Set
  alias Twelvgaige.Workspace.SourceCapture
  alias Twelvgaige.Workspace.Storage
  alias Twelvgaige.Operations.Store, as: OperationsStore

  @far_future ~U[9999-12-31 23:59:59Z]
  @default_execution_reserve 512 * 1_024 * 1_024
  @default_result_reserve 512 * 1_024 * 1_024
  @default_verification_reserve 512 * 1_024 * 1_024
  @default_protected_finalization 512 * 1_024 * 1_024

  defstruct [
    :root,
    :operations_store,
    :artifact_store,
    :disk_available_fun,
    :protected_finalization_bytes,
    :workspace_retention_days,
    :backup_retention_days,
    :retention_interval_ms,
    :retention_last_run,
    :fault_checkpoint_fun,
    workspaces: %{},
    writer_leases: %{},
    sets: %{},
    operations: %{},
    storage_reservations: %{}
  ]

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

  def list(opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), :list)
  end

  def get_operation(request_id, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:get_operation, request_id})
  end

  def list_operations(opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), :list_operations)
  end

  def bind_owner(workspace_id, session_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:bind_owner, workspace_id, session_id}
    )
  end

  def quiesce(workspace_id, evidence, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:quiesce, workspace_id, evidence}
    )
  end

  def quarantine(workspace_id, reason, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:quarantine, workspace_id, reason}
    )
  end

  def finalize(workspace_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:finalize, workspace_id, opts},
      :infinity
    )
  end

  def cleanup(workspace_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:cleanup, workspace_id, opts},
      :infinity
    )
  end

  def export(workspace_id, destination, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:export, workspace_id, destination, opts},
      :infinity
    )
  end

  def apply(workspace_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:apply, workspace_id, opts},
      :infinity
    )
  end

  def reconcile(workspace_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:reconcile, workspace_id, opts},
      :infinity
    )
  end

  def cleanup_review(workspace_id, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:cleanup_review, workspace_id, opts},
      :infinity
    )
  end

  def retention_status(opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), :retention_status)
  end

  def run_retention(opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:run_retention, Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())},
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

  def list_sets(opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :list_sets)

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
    operations_store = Keyword.get(opts, :operations_store)

    case File.mkdir_p(root) do
      :ok ->
        case File.chmod(root, 0o700) do
          :ok ->
            state = %__MODULE__{
              root: root,
              operations_store: operations_store,
              artifact_store: Keyword.get(opts, :artifact_store),
              disk_available_fun:
                Keyword.get(opts, :disk_available_fun, &Storage.available_bytes/1),
              protected_finalization_bytes:
                Keyword.get(
                  opts,
                  :protected_finalization_bytes,
                  @default_protected_finalization
                ),
              workspace_retention_days: Keyword.get(opts, :workspace_retention_days, 7),
              backup_retention_days: Keyword.get(opts, :backup_retention_days, 7),
              retention_interval_ms: Keyword.get(opts, :retention_interval_ms, 3_600_000),
              fault_checkpoint_fun: Keyword.get(opts, :fault_checkpoint_fun)
            }

            with {:ok, state} <- recover_operations(state),
                 {:ok, state} <- recover_workspaces(state, opts) do
              schedule_retention(state.retention_interval_ms)
              {:ok, state}
            else
              {:error, reason} -> {:stop, reason}
            end

          {:error, reason} ->
            {:stop, reason}
        end

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:create, repository, opts}, _from, state) do
    {reply, state} = create_workspace_operation(repository, opts, state)
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

  def handle_call(:list_sets, _from, state) do
    sets = state.sets |> Map.values() |> Enum.sort_by(& &1.id)
    {:reply, {:ok, sets}, state}
  end

  def handle_call({:finalize_set, set_id, opts}, _from, state) do
    case Map.fetch(state.sets, set_id) do
      {:ok, set} ->
        repositories =
          Map.new(set.repositories, fn {name, workspace} ->
            {name, Map.get(state.workspaces, workspace.id, workspace)}
          end)

        case finalize_repositories(repositories, Keyword.put(opts, :set_id, set_id), state) do
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

  def handle_call(:list, _from, state) do
    workspaces = state.workspaces |> Map.values() |> Enum.sort_by(&{&1.created_at, &1.id})
    {:reply, {:ok, workspaces}, state}
  end

  def handle_call({:get_operation, request_id}, _from, state) do
    {:reply, Map.fetch(state.operations, request_id), state}
  end

  def handle_call(:list_operations, _from, state) do
    operations =
      state.operations
      |> Map.values()
      |> Enum.sort_by(&{&1.created_at, &1.request_id})

    {:reply, {:ok, operations}, state}
  end

  def handle_call({:bind_owner, workspace_id, session_id}, _from, state) do
    with {:ok, workspace} <- Map.fetch(state.workspaces, workspace_id),
         :ok <- bindable(workspace, session_id),
         :ok <- writer_available(state, workspace_id, session_id, workspace.writable),
         workspace <- %{
           workspace
           | owner_session_id: session_id,
             state: :running,
             control_epoch: workspace.control_epoch + 1
         },
         :ok <- persist_workspace(workspace, state) do
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

  def handle_call({:quiesce, workspace_id, evidence}, _from, state) do
    with {:ok, workspace} <- Map.fetch(state.workspaces, workspace_id),
         :ok <- quiesceable(workspace),
         {:ok, evidence} <- validate_quiescence(evidence),
         quiesced <- %{
           workspace
           | state: :quiesced,
             quiescence_evidence: evidence,
             control_epoch: workspace.control_epoch + 1
         },
         :ok <- persist_workspace(quiesced, state) do
      next =
        state
        |> put_in([Access.key!(:workspaces), workspace_id], quiesced)
        |> update_in([Access.key!(:writer_leases)], &Map.delete(&1, workspace_id))

      {:reply, {:ok, quiesced}, next}
    else
      :error -> {:reply, {:error, :workspace_not_found}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:quarantine, workspace_id, reason}, _from, state) do
    case Map.fetch(state.workspaces, workspace_id) do
      {:ok, workspace} ->
        quarantined = %{
          workspace
          | state: :quarantined,
            quarantine_reason: reason,
            control_epoch: workspace.control_epoch + 1
        }

        case persist_workspace(quarantined, state) do
          :ok ->
            {:reply, {:ok, quarantined}, put_in(state.workspaces[workspace_id], quarantined)}

          {:error, persist_reason} ->
            {:reply, {:error, {:workspace_persistence_failed, persist_reason}}, state}
        end

      :error ->
        {:reply, {:error, :workspace_not_found}, state}
    end
  end

  def handle_call({:finalize, workspace_id, opts}, _from, state) do
    {reply, state} = finalize_workspace_operation(workspace_id, opts, state)
    {:reply, reply, state}
  end

  def handle_call({:cleanup, workspace_id, opts}, _from, state) do
    {reply, state} = cleanup_workspace_operation(workspace_id, opts, state)
    {:reply, reply, state}
  end

  def handle_call({:export, workspace_id, destination, opts}, _from, state) do
    {reply, state} = export_workspace_operation(workspace_id, destination, opts, state)
    {:reply, reply, state}
  end

  def handle_call({:apply, workspace_id, opts}, _from, state) do
    {reply, state} = apply_workspace_operation(workspace_id, opts, state)
    {:reply, reply, state}
  end

  def handle_call({:reconcile, workspace_id, opts}, _from, state) do
    {reply, state} = reconcile_workspace_operation(workspace_id, opts, state)
    {:reply, reply, state}
  end

  def handle_call({:cleanup_review, workspace_id, opts}, _from, state) do
    {reply, state} = cleanup_review_operation(workspace_id, opts, state)
    {:reply, reply, state}
  end

  def handle_call(:retention_status, _from, state) do
    now = Twelvgaige.Clock.utc_now()

    report = %{
      workspace_retention_days: state.workspace_retention_days,
      backup_retention_days: state.backup_retention_days,
      interval_ms: state.retention_interval_ms,
      last_run: state.retention_last_run,
      expired_workspaces: expired_workspace_ids(state, now)
    }

    {:reply, {:ok, report}, state}
  end

  def handle_call({:run_retention, %DateTime{} = now}, _from, state) do
    {report, state} = retention_sweep(state, now)
    {:reply, {:ok, report}, state}
  end

  @impl true
  def handle_info(:workspace_retention_sweep, state) do
    {_report, state} = retention_sweep(state, Twelvgaige.Clock.utc_now())
    schedule_retention(state.retention_interval_ms)
    {:noreply, state}
  end

  defp retention_sweep(state, now) do
    {removed, failures, state} =
      Enum.reduce(expired_workspace_ids(state, now), {[], [], state}, fn workspace_id,
                                                                         {removed, failures,
                                                                          current} ->
        workspace = Map.fetch!(current.workspaces, workspace_id)
        request_id = retention_request_id(workspace)

        opts = [
          write: true,
          yes: true,
          expected_epoch: workspace.control_epoch,
          request_id: request_id,
          now: now
        ]

        case cleanup_workspace_operation(workspace_id, opts, current) do
          {{:ok, report}, next} ->
            {[report | removed], failures, next}

          {{:error, reason}, next} ->
            {removed, [%{workspace_id: workspace_id, reason: reason} | failures], next}
        end
      end)

    report = %{
      ran_at: now,
      removed: Enum.reverse(removed),
      failures: Enum.reverse(failures),
      workspace_retention_days: state.workspace_retention_days
    }

    {report, %{state | retention_last_run: now}}
  end

  defp expired_workspace_ids(state, now) do
    state.workspaces
    |> Map.values()
    |> Enum.filter(fn workspace ->
      workspace.state in [:reviewable, :retained, :quarantined] and
        match?(%DateTime{}, workspace.retention_expires_at) and
        DateTime.compare(workspace.retention_expires_at, now) in [:lt, :eq]
    end)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp retention_request_id(workspace) do
    suffix =
      :crypto.hash(
        :sha256,
        "#{workspace.id}\0#{DateTime.to_iso8601(workspace.retention_expires_at)}"
      )
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 20)

    "req_retention_#{suffix}"
  end

  defp schedule_retention(:infinity), do: :ok

  defp schedule_retention(interval_ms) when is_integer(interval_ms) and interval_ms > 0 do
    Process.send_after(self(), :workspace_retention_sweep, interval_ms)
    :ok
  end

  defp export_workspace_operation(workspace_id, destination, opts, state) do
    with {:ok, workspace} <- fetch_workspace(state, workspace_id) do
      if Keyword.get(opts, :write?, false) do
        execute_export_request(workspace, Path.expand(destination), opts, state)
      else
        {Result.export(workspace, state.artifact_store, destination, opts), state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp execute_export_request(workspace, destination, opts, state) do
    request_id = Keyword.get(opts, :request_id, "req_workspace_export_" <> random_id())

    intent = %{
      "kind" => "export",
      "workspace_id" => workspace.id,
      "destination" => destination,
      "manifest_digest" => workspace.result_manifest && workspace.result_manifest.manifest_digest
    }

    candidate =
      Operation.new(:export, workspace.id, intent,
        request_id: request_id,
        now: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
      )
      |> Map.put(:effects, [
        %{
          kind: :artifact_export_publish,
          path: destination,
          staging_path: Result.staging_path(destination, request_id)
        }
      ])

    case operation_admission(candidate, state) do
      {:replay, operation} ->
        replay_export(operation, state)

      {:error, reason} ->
        {{:error, reason}, state}

      :new ->
        commit_export(candidate, workspace, destination, opts, state)
    end
  end

  defp commit_export(operation, workspace, destination, opts, state) do
    with :ok <- persist_operation(operation, state) do
      state = put_in(state.operations[operation.request_id], operation)

      started =
        Operation.transition(operation, :side_effects_started, %{
          effects: operation.effects
        })

      export_opts =
        opts
        |> Keyword.put(:request_id, operation.request_id)
        |> Keyword.put(:operation_id, operation.id)
        |> Keyword.put(:fault_checkpoint_fun, state.fault_checkpoint_fun)

      with :ok <- persist_operation(started, state),
           {:ok, report} <-
             Result.export(workspace, state.artifact_store, destination, export_opts) do
        completed = Operation.transition(started, :completed, %{result: report})

        case persist_operation(completed, state) do
          :ok ->
            next = put_in(state.operations[completed.request_id], completed)
            {{:ok, report}, next}

          {:error, reason} ->
            export_reconciliation(started, workspace, destination, reason, state)
        end
      else
        {:error, reason} ->
          if File.exists?(destination) do
            export_reconciliation(started, workspace, destination, reason, state)
          else
            failed = Operation.transition(started, :failed, %{error: reason})
            _ = persist_operation(failed, state)
            {{:error, reason}, put_in(state.operations[failed.request_id], failed)}
          end
      end
    else
      {:error, reason} -> {{:error, {:workspace_operation_persistence_failed, reason}}, state}
    end
  end

  defp export_reconciliation(operation, workspace, destination, reason, state) do
    reconciliation =
      Operation.transition(operation, :needs_reconciliation, %{
        error: %{failure: reason, destination: destination}
      })

    updated = %{
      workspace
      | state: :needs_reconciliation,
        quarantine_reason: {:workspace_export_interrupted, operation.request_id},
        last_operation_id: operation.id,
        control_epoch: workspace.control_epoch + 1
    }

    _ = persist_lifecycle_workspace(updated, state, :export, operation)
    _ = persist_operation(reconciliation, state)

    next =
      state
      |> put_in([Access.key!(:workspaces), workspace.id], updated)
      |> put_in([Access.key!(:operations), reconciliation.request_id], reconciliation)

    {{:error, {:workspace_operation_needs_reconciliation, operation.request_id, reason}}, next}
  end

  defp replay_export(%Operation{status: :completed, result: result}, state),
    do: {{:ok, Map.put(result, :replayed, true)}, state}

  defp replay_export(%Operation{request_id: id, status: status}, state),
    do: {{:error, {:workspace_operation_not_replayable, id, status}}, state}

  defp cleanup_review_operation(workspace_id, opts, state) do
    request_id = Keyword.get(opts, :request_id)

    case Map.get(state.operations, request_id) do
      %Operation{kind: :cleanup_review, workspace_id: ^workspace_id} = operation ->
        replay_review_cleanup(operation, state)

      _operation ->
        with {:ok, workspace} <- fetch_workspace(state, workspace_id),
             {:ok, apply_operation} <- completed_review_apply(state, workspace.id),
             path when is_binary(path) <- map_value(apply_operation.result, :path),
             true <- File.dir?(path),
             {:ok, capture} <-
               SourceRead.capture_worktree_result(
                 path,
                 map_value(apply_operation.result, :base_commit),
                 artifact_base: map_value(apply_operation.result, :base_commit)
               ),
             true <- capture.result_tree == map_value(apply_operation.result, :result_tree) do
          report = %{
            workspace_id: workspace.id,
            review_path: path,
            result_tree: capture.result_tree,
            expected_epoch: workspace.control_epoch,
            dry_run: not Keyword.get(opts, :write?, false),
            recoverable_from_artifact: not is_nil(workspace.result_artifact_ref)
          }

          if Keyword.get(opts, :write?, false) do
            execute_review_cleanup(workspace, apply_operation, report, opts, state)
          else
            {{:ok, report}, state}
          end
        else
          false -> {{:error, :review_worktree_has_uncaptured_changes}, state}
          nil -> {{:error, :review_worktree_path_invalid}, state}
          {:error, reason} -> {{:error, reason}, state}
        end
    end
  end

  defp completed_review_apply(state, workspace_id) do
    state.operations
    |> Map.values()
    |> Enum.filter(
      &(&1.workspace_id == workspace_id and &1.kind == :apply_review and &1.status == :completed)
    )
    |> Enum.sort_by(fn operation -> DateTime.to_unix(operation.completed_at, :microsecond) end)
    |> List.last()
    |> case do
      nil -> {:error, :review_worktree_not_found}
      operation -> {:ok, operation}
    end
  end

  defp execute_review_cleanup(workspace, apply_operation, report, opts, state) do
    expected_epoch = Keyword.get(opts, :expected_epoch)
    request_id = Keyword.get(opts, :request_id)

    intent = %{
      "kind" => "cleanup_review",
      "workspace_id" => workspace.id,
      "review_path" => report.review_path,
      "result_tree" => report.result_tree,
      "expected_epoch" => expected_epoch,
      "apply_request_id" => apply_operation.request_id
    }

    candidate =
      Operation.new(:cleanup_review, workspace.id, intent,
        request_id: request_id || "",
        expected_epoch: expected_epoch,
        now: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
      )
      |> Map.put(:effects, [
        %{kind: :verified_review_worktree_remove, path: report.review_path}
      ])

    cond do
      Keyword.get(opts, :yes?, false) != true ->
        {{:error, :review_worktree_cleanup_confirmation_required}, state}

      not is_integer(expected_epoch) ->
        {{:error, :workspace_expected_epoch_required}, state}

      not is_binary(request_id) or request_id == "" ->
        {{:error, :workspace_request_id_required}, state}

      true ->
        case operation_admission(candidate, state) do
          {:replay, operation} -> replay_review_cleanup(operation, state)
          {:error, reason} -> {{:error, reason}, state}
          :new -> commit_review_cleanup(candidate, workspace, report, state)
        end
    end
  end

  defp commit_review_cleanup(candidate, workspace, report, state) do
    with :ok <- expected_epoch(workspace, candidate.expected_epoch),
         :ok <- persist_operation(candidate, state) do
      started =
        Operation.transition(candidate, :side_effects_started, %{
          effects: candidate.effects
        })

      with :ok <- persist_operation(started, state),
           {:ok, authority} <-
             ManagedWorkspace.authorize(workspace,
               root: workspace.repository,
               target_path: Path.expand(report.review_path),
               expected_epoch: candidate.expected_epoch,
               lease: candidate.request_id,
               operation_id: candidate.id,
               request_id: candidate.request_id,
               audit_fun: git_audit_sink(state, []),
               scope: :review_registration
             ),
           :ok <-
             FaultMatrix.around(
               fault_opts(state),
               :review_cleanup,
               :review_registration_remove,
               operation_metadata(candidate),
               fn ->
                 ManagedWorkspace.remove_verified_worktree(
                   authority,
                   report.review_path
                 )
               end
             ) do
        updated = %{
          workspace
          | last_operation_id: candidate.id,
            control_epoch: workspace.control_epoch + 1
        }

        result =
          report
          |> Map.merge(%{
            dry_run: false,
            removed: true,
            control_epoch: updated.control_epoch
          })

        completed = Operation.transition(started, :completed, %{result: result})

        with :ok <-
               persist_lifecycle_workspace(
                 updated,
                 state,
                 :review_cleanup,
                 candidate
               ),
             :ok <- persist_operation(completed, state) do
          next =
            state
            |> put_in([Access.key!(:workspaces), workspace.id], updated)
            |> put_in([Access.key!(:operations), completed.request_id], completed)

          {{:ok, result}, next}
        else
          {:error, reason} -> apply_reconciliation(started, workspace, reason, state)
        end
      else
        {:error, reason} ->
          if File.exists?(report.review_path) do
            failed = Operation.transition(started, :failed, %{error: reason})
            _ = persist_operation(failed, state)
            {{:error, reason}, put_in(state.operations[failed.request_id], failed)}
          else
            apply_reconciliation(started, workspace, reason, state)
          end
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp replay_review_cleanup(%Operation{status: :completed, result: result}, state),
    do: {{:ok, Map.put(result, :replayed, true)}, state}

  defp replay_review_cleanup(%Operation{request_id: id, status: status}, state),
    do: {{:error, {:workspace_operation_not_replayable, id, status}}, state}

  defp reconcile_workspace_operation(workspace_id, opts, state) do
    request_id = Keyword.get(opts, :request_id)

    case Map.get(state.operations, request_id) do
      %Operation{kind: :reconcile, workspace_id: ^workspace_id} = operation ->
        replay_reconcile(operation, state)

      _operation ->
        with {:ok, workspace} <- fetch_workspace(state, workspace_id),
             :ok <- reconciliation_required(workspace),
             %Operation{} = interrupted <- interrupted_operation(state, workspace.id) do
          export_resume = export_resume_report(interrupted, workspace)
          cleanup_resume = cleanup_resume_report(interrupted, workspace)
          review_discard = review_discard_report(interrupted, workspace, state)

          report = %{
            workspace_id: workspace.id,
            state: workspace.state,
            interrupted_request_id: interrupted.request_id,
            interrupted_kind: interrupted.kind,
            effects: interrupted.effects,
            reason: workspace.quarantine_reason,
            expected_epoch: workspace.control_epoch,
            action:
              recommended_reconciliation_action(export_resume, cleanup_resume, review_discard),
            dry_run: not Keyword.get(opts, :write?, false),
            recovery_commands:
              [
                "twelvgaige workspace show #{workspace.id}",
                "twelvgaige workspace export #{workspace.id} --output ./#{workspace.id}-recovery"
              ] ++
                export_resume_commands(export_resume) ++
                cleanup_resume_commands(cleanup_resume) ++
                review_discard_commands(review_discard),
            restoration: restoration_report(interrupted, workspace),
            export_resume: export_resume,
            cleanup_resume: cleanup_resume,
            review_discard: review_discard
          }

          if Keyword.get(opts, :write?, false) do
            execute_reconcile(workspace, interrupted, report, opts, state)
          else
            {{:ok, report}, state}
          end
        else
          nil -> {{:error, :workspace_reconciliation_operation_missing}, state}
          {:error, reason} -> {{:error, reason}, state}
        end
    end
  end

  defp execute_reconcile(workspace, interrupted, report, opts, state) do
    expected_epoch = Keyword.get(opts, :expected_epoch)
    request_id = Keyword.get(opts, :request_id)
    action = Keyword.get(opts, :action, :quarantine)

    intent = %{
      "kind" => "reconcile",
      "workspace_id" => workspace.id,
      "interrupted_request_id" => interrupted.request_id,
      "expected_epoch" => expected_epoch,
      "action" => action
    }

    candidate =
      Operation.new(:reconcile, workspace.id, intent,
        request_id: request_id || "",
        expected_epoch: expected_epoch,
        now: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
      )

    cond do
      Keyword.get(opts, :yes?, false) != true ->
        {{:error, :workspace_reconcile_confirmation_required}, state}

      action not in [
        :quarantine,
        :restore_backup,
        :resume_export,
        :resume_cleanup,
        :discard_review
      ] ->
        {{:error, :workspace_reconcile_action_invalid}, state}

      action == :restore_backup and not restoration_available?(interrupted, report) ->
        {{:error, :workspace_recovery_backup_unavailable}, state}

      action == :resume_export and not export_resume_available?(interrupted) ->
        {{:error, :workspace_export_resume_unavailable}, state}

      action == :resume_cleanup and not cleanup_resume_available?(interrupted) ->
        {{:error, :workspace_cleanup_resume_unavailable}, state}

      action == :discard_review and not review_discard_available?(interrupted, workspace, state) ->
        {{:error, :workspace_review_discard_unavailable}, state}

      not is_integer(expected_epoch) ->
        {{:error, :workspace_expected_epoch_required}, state}

      not is_binary(request_id) or request_id == "" ->
        {{:error, :workspace_request_id_required}, state}

      true ->
        case operation_admission(candidate, state) do
          {:replay, operation} ->
            replay_reconcile(operation, state)

          {:error, reason} ->
            {{:error, reason}, state}

          :new when action == :restore_backup ->
            commit_restore_reconcile(candidate, workspace, interrupted, report, opts, state)

          :new when action == :resume_export ->
            commit_export_resume(candidate, workspace, interrupted, report, opts, state)

          :new when action == :resume_cleanup ->
            commit_cleanup_resume(candidate, workspace, interrupted, report, state)

          :new when action == :discard_review ->
            commit_review_discard(candidate, workspace, interrupted, report, state)

          :new ->
            commit_reconcile(candidate, workspace, interrupted, report, state)
        end
    end
  end

  defp commit_export_resume(candidate, workspace, interrupted, report, opts, state) do
    destination = export_destination(interrupted)
    source_request_id = export_source_request_id(interrupted)

    with :ok <- expected_epoch(workspace, candidate.expected_epoch),
         :ok <- persist_operation(candidate, state) do
      started =
        Operation.transition(candidate, :side_effects_started, %{
          effects: [
            %{
              kind: :artifact_export_resume,
              path: destination,
              source_request_id: source_request_id,
              staging_path: Result.staging_path(destination, source_request_id)
            }
          ]
        })

      resume_opts =
        opts
        |> Keyword.put(:request_id, source_request_id)
        |> Keyword.put(:operation_id, candidate.id)
        |> Keyword.put(:fault_checkpoint_fun, state.fault_checkpoint_fun)

      with :ok <- persist_operation(started, state),
           {:ok, resume_report} <-
             Result.resume_export(
               workspace,
               state.artifact_store,
               destination,
               resume_opts
             ) do
        updated = %{
          workspace
          | state: :reviewable,
            quarantine_reason: nil,
            last_operation_id: candidate.id,
            control_epoch: workspace.control_epoch + 1
        }

        resolved_interrupted =
          Operation.transition(interrupted, :failed, %{
            error: {:export_resumed, candidate.request_id}
          })

        result =
          report
          |> Map.merge(resume_report)
          |> Map.merge(%{
            state: :reviewable,
            action: :resume_export,
            dry_run: false,
            control_epoch: updated.control_epoch,
            request_id: candidate.request_id
          })

        completed = Operation.transition(started, :completed, %{result: result})

        with :ok <- persist_lifecycle_workspace(updated, state, :reconcile, candidate),
             :ok <-
               FaultMatrix.around(
                 fault_opts(state),
                 :reconcile,
                 :interrupted_operation_resolve,
                 operation_metadata(candidate),
                 fn -> persist_operation(resolved_interrupted, state) end
               ),
             :ok <- persist_operation(completed, state) do
          next =
            state
            |> put_in([Access.key!(:workspaces), workspace.id], updated)
            |> put_in([Access.key!(:operations), interrupted.request_id], resolved_interrupted)
            |> put_in([Access.key!(:operations), completed.request_id], completed)

          {{:ok, result}, next}
        else
          {:error, reason} ->
            export_resume_reconciliation(started, workspace, reason, state)
        end
      else
        {:error, reason} ->
          export_resume_reconciliation(started, workspace, reason, state)
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp export_resume_reconciliation(operation, workspace, reason, state) do
    reconciliation =
      Operation.transition(operation, :needs_reconciliation, %{
        error: {:workspace_export_resume_interrupted, reason}
      })

    updated = %{
      workspace
      | state: :needs_reconciliation,
        quarantine_reason: {:workspace_export_resume_interrupted, operation.request_id},
        last_operation_id: operation.id,
        control_epoch: workspace.control_epoch + 1
    }

    _ = persist_lifecycle_workspace(updated, state, :reconcile, operation)
    _ = persist_operation(reconciliation, state)

    next =
      state
      |> put_in([Access.key!(:workspaces), workspace.id], updated)
      |> put_in([Access.key!(:operations), reconciliation.request_id], reconciliation)

    {{:error, {:workspace_operation_needs_reconciliation, operation.request_id, reason}}, next}
  end

  defp commit_cleanup_resume(candidate, workspace, interrupted, report, state) do
    with :ok <- expected_epoch(workspace, candidate.expected_epoch),
         :ok <- exact_managed_path(workspace, state.root),
         :ok <- persist_operation(candidate, state) do
      started =
        Operation.transition(candidate, :side_effects_started, %{
          effects: [%{kind: :managed_path_remove_resume, path: workspace.path}]
        })

      with :ok <- persist_operation(started, state),
           :ok <- resume_managed_path_remove(started, workspace, state) do
        deleted = %{
          workspace
          | state: :deleted,
            quarantine_reason: nil,
            last_operation_id: candidate.id,
            control_epoch: workspace.control_epoch + 1
        }

        resolved_interrupted =
          Operation.transition(interrupted, :failed, %{
            error: {:cleanup_resumed, candidate.request_id}
          })

        result =
          report
          |> Map.merge(%{
            state: :deleted,
            action: :resume_cleanup,
            dry_run: false,
            deleted: true,
            control_epoch: deleted.control_epoch,
            request_id: candidate.request_id
          })

        completed = Operation.transition(started, :completed, %{result: result})

        with :ok <- persist_lifecycle_workspace(deleted, state, :reconcile, candidate),
             :ok <-
               FaultMatrix.around(
                 fault_opts(state),
                 :reconcile,
                 :interrupted_operation_resolve,
                 operation_metadata(candidate),
                 fn -> persist_operation(resolved_interrupted, state) end
               ),
             :ok <- persist_operation(completed, state) do
          next =
            state
            |> put_in([Access.key!(:workspaces), workspace.id], deleted)
            |> update_in([Access.key!(:writer_leases)], &Map.delete(&1, workspace.id))
            |> put_in([Access.key!(:operations), interrupted.request_id], resolved_interrupted)
            |> put_in([Access.key!(:operations), completed.request_id], completed)

          {{:ok, result}, next}
        else
          {:error, reason} ->
            cleanup_resume_reconciliation(started, workspace, reason, state)
        end
      else
        {:error, reason} -> cleanup_resume_reconciliation(started, workspace, reason, state)
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp resume_managed_path_remove(operation, workspace, state) do
    case File.lstat(workspace.path) do
      {:ok, %{type: :directory}} ->
        FaultMatrix.around(
          fault_opts(state),
          :reconcile,
          :cleanup_resume,
          operation_metadata(operation),
          fn -> remove_exact_managed_path(workspace.path) end
        )

      {:error, :enoent} ->
        :ok

      {:ok, _stat} ->
        {:error, :workspace_cleanup_target_not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp cleanup_resume_reconciliation(operation, workspace, reason, state) do
    reconciliation =
      Operation.transition(operation, :needs_reconciliation, %{
        error: {:workspace_cleanup_resume_interrupted, reason}
      })

    updated = %{
      workspace
      | state: :needs_reconciliation,
        quarantine_reason: {:workspace_cleanup_resume_interrupted, operation.request_id},
        last_operation_id: operation.id,
        control_epoch: workspace.control_epoch + 1
    }

    _ = persist_lifecycle_workspace(updated, state, :reconcile, operation)
    _ = persist_operation(reconciliation, state)

    next =
      state
      |> put_in([Access.key!(:workspaces), workspace.id], updated)
      |> put_in([Access.key!(:operations), reconciliation.request_id], reconciliation)

    {{:error, {:workspace_operation_needs_reconciliation, operation.request_id, reason}}, next}
  end

  defp commit_review_discard(candidate, workspace, interrupted, report, state) do
    destination = review_destination(interrupted)

    with :ok <- expected_epoch(workspace, candidate.expected_epoch),
         :ok <- valid_review_destination(destination, workspace, state),
         :ok <- persist_operation(candidate, state) do
      started =
        Operation.transition(candidate, :side_effects_started, %{
          effects: [%{kind: :interrupted_review_discard, path: destination}]
        })

      with :ok <- persist_operation(started, state),
           :ok <- discard_interrupted_review(started, workspace, destination, state) do
        updated = %{
          workspace
          | state: :reviewable,
            quarantine_reason: nil,
            last_operation_id: candidate.id,
            control_epoch: workspace.control_epoch + 1
        }

        resolved_interrupted =
          Operation.transition(interrupted, :failed, %{
            error: {:interrupted_review_discarded, candidate.request_id}
          })

        result =
          report
          |> Map.merge(%{
            state: :reviewable,
            action: :discard_review,
            review_path: destination,
            dry_run: false,
            removed: true,
            control_epoch: updated.control_epoch,
            request_id: candidate.request_id
          })

        completed = Operation.transition(started, :completed, %{result: result})

        with :ok <- persist_lifecycle_workspace(updated, state, :reconcile, candidate),
             :ok <-
               FaultMatrix.around(
                 fault_opts(state),
                 :reconcile,
                 :interrupted_operation_resolve,
                 operation_metadata(candidate),
                 fn -> persist_operation(resolved_interrupted, state) end
               ),
             :ok <- persist_operation(completed, state) do
          next =
            state
            |> put_in([Access.key!(:workspaces), workspace.id], updated)
            |> put_in([Access.key!(:operations), interrupted.request_id], resolved_interrupted)
            |> put_in([Access.key!(:operations), completed.request_id], completed)

          {{:ok, result}, next}
        else
          {:error, reason} ->
            review_discard_reconciliation(started, workspace, reason, state)
        end
      else
        {:error, reason} -> review_discard_reconciliation(started, workspace, reason, state)
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp discard_interrupted_review(operation, workspace, destination, state) do
    case File.lstat(destination) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :directory}} ->
        with true <- review_tree_discardable?(destination, workspace),
             {:ok, authority} <-
               ManagedWorkspace.authorize(workspace,
                 root: workspace.repository,
                 target_path: destination,
                 expected_epoch: operation.expected_epoch,
                 lease: operation.request_id,
                 operation_id: operation.id,
                 request_id: operation.request_id,
                 audit_fun: git_audit_sink(state, []),
                 scope: :review_registration
               ),
             :ok <-
               FaultMatrix.around(
                 fault_opts(state),
                 :reconcile,
                 :review_discard,
                 operation_metadata(operation),
                 fn -> ManagedWorkspace.remove_verified_worktree(authority, destination) end
               ) do
          :ok
        else
          false -> {:error, :workspace_review_discard_drifted}
          {:error, _reason} = error -> error
        end

      {:ok, _stat} ->
        {:error, :workspace_review_discard_target_invalid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp review_discard_reconciliation(operation, workspace, reason, state) do
    reconciliation =
      Operation.transition(operation, :needs_reconciliation, %{
        error: {:workspace_review_discard_interrupted, reason}
      })

    updated = %{
      workspace
      | state: :needs_reconciliation,
        quarantine_reason: {:workspace_review_discard_interrupted, operation.request_id},
        last_operation_id: operation.id,
        control_epoch: workspace.control_epoch + 1
    }

    _ = persist_lifecycle_workspace(updated, state, :reconcile, operation)
    _ = persist_operation(reconciliation, state)

    next =
      state
      |> put_in([Access.key!(:workspaces), workspace.id], updated)
      |> put_in([Access.key!(:operations), reconciliation.request_id], reconciliation)

    {{:error, {:workspace_operation_needs_reconciliation, operation.request_id, reason}}, next}
  end

  defp commit_restore_reconcile(candidate, workspace, interrupted, report, opts, state) do
    recovery = map_value(interrupted.error, :recovery, %{})
    restoration = map_value(report, :restoration, %{})
    backup_path = map_value(recovery, :backup_path) || map_value(restoration, :backup_path)

    source_token =
      map_value(recovery, :source_state_token) || map_value(restoration, :source_state_token)

    with :ok <- expected_epoch(workspace, candidate.expected_epoch),
         :ok <- persist_operation(candidate, state) do
      started =
        Operation.transition(candidate, :side_effects_started, %{
          effects: [
            %{
              kind: :current_worktree_restore,
              backup_path: backup_path,
              source_state_token: source_token
            }
          ]
        })

      with :ok <- persist_operation(started, state),
           {:ok, recovery_report} <-
             FaultMatrix.around(
               fault_opts(state, opts),
               :reconcile,
               :backup_restore,
               operation_metadata(candidate),
               fn -> DirectApply.restore(workspace, backup_path, source_token, opts) end
             ) do
        updated = %{
          workspace
          | state: :reviewable,
            quarantine_reason: nil,
            last_operation_id: candidate.id,
            control_epoch: workspace.control_epoch + 1
        }

        resolved_interrupted =
          Operation.transition(interrupted, :failed, %{
            error: {:restored_from_backup, candidate.request_id}
          })

        result =
          report
          |> Map.merge(recovery_report)
          |> Map.merge(%{
            state: :reviewable,
            action: :restore_backup,
            dry_run: false,
            control_epoch: updated.control_epoch,
            request_id: candidate.request_id
          })

        completed = Operation.transition(started, :completed, %{result: result})

        with :ok <-
               persist_lifecycle_workspace(updated, state, :reconcile, candidate),
             :ok <-
               FaultMatrix.around(
                 fault_opts(state),
                 :reconcile,
                 :interrupted_operation_resolve,
                 operation_metadata(candidate),
                 fn -> persist_operation(resolved_interrupted, state) end
               ),
             :ok <- persist_operation(completed, state) do
          next =
            state
            |> put_in([Access.key!(:workspaces), workspace.id], updated)
            |> put_in([Access.key!(:operations), interrupted.request_id], resolved_interrupted)
            |> put_in([Access.key!(:operations), completed.request_id], completed)

          {{:ok, result}, next}
        else
          {:error, reason} ->
            restore_reconciliation(started, workspace, interrupted, reason, state)
        end
      else
        {:error, reason} ->
          restore_reconciliation(
            started,
            workspace,
            interrupted,
            {:workspace_restore_interrupted, reason},
            state
          )
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp restore_reconciliation(operation, workspace, interrupted, reason, state) do
    recovery = map_value(interrupted.error, :recovery, %{})

    reconciliation =
      Operation.transition(operation, :needs_reconciliation, %{
        error: %{failure: reason, recovery: recovery}
      })

    updated = %{
      workspace
      | state: :needs_reconciliation,
        quarantine_reason: {:workspace_restore_interrupted, operation.request_id},
        last_operation_id: operation.id,
        control_epoch: workspace.control_epoch + 1
    }

    _ = persist_workspace(updated, state)
    _ = persist_operation(reconciliation, state)

    next =
      state
      |> put_in([Access.key!(:workspaces), workspace.id], updated)
      |> put_in([Access.key!(:operations), reconciliation.request_id], reconciliation)

    {{:error, {:workspace_operation_needs_reconciliation, operation.request_id, reason}}, next}
  end

  defp commit_reconcile(candidate, workspace, interrupted, report, state) do
    with :ok <- expected_epoch(workspace, candidate.expected_epoch),
         :ok <- persist_operation(candidate, state) do
      started =
        Operation.transition(candidate, :side_effects_started, %{
          effects: [%{kind: :reconciliation_disposition, action: :quarantine}]
        })

      updated = %{
        workspace
        | state: :quarantined,
          quarantine_reason: {:workspace_reconciled, interrupted.request_id},
          last_operation_id: candidate.id,
          control_epoch: workspace.control_epoch + 1
      }

      resolved_interrupted =
        Operation.transition(interrupted, :failed, %{
          error: {:reconciled_as_quarantined, candidate.request_id}
        })

      result =
        report
        |> Map.merge(%{
          state: :quarantined,
          dry_run: false,
          control_epoch: updated.control_epoch,
          request_id: candidate.request_id
        })

      completed = Operation.transition(started, :completed, %{result: result})

      with :ok <- persist_operation(started, state),
           :ok <- persist_lifecycle_workspace(updated, state, :reconcile, candidate),
           :ok <-
             FaultMatrix.around(
               fault_opts(state),
               :reconcile,
               :interrupted_operation_resolve,
               operation_metadata(candidate),
               fn -> persist_operation(resolved_interrupted, state) end
             ),
           :ok <- persist_operation(completed, state) do
        next =
          state
          |> put_in([Access.key!(:workspaces), workspace.id], updated)
          |> put_in([Access.key!(:operations), interrupted.request_id], resolved_interrupted)
          |> put_in([Access.key!(:operations), completed.request_id], completed)

        {{:ok, result}, next}
      else
        {:error, reason} ->
          reconciliation =
            Operation.transition(started, :needs_reconciliation, %{
              error: {:workspace_reconcile_interrupted, reason}
            })

          _ = persist_operation(reconciliation, state)
          next = put_in(state.operations[reconciliation.request_id], reconciliation)

          {{:error, {:workspace_operation_needs_reconciliation, candidate.request_id, reason}},
           next}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp replay_reconcile(%Operation{status: :completed, result: result}, state),
    do: {{:ok, Map.put(result, :replayed, true)}, state}

  defp replay_reconcile(%Operation{request_id: id, status: status}, state),
    do: {{:error, {:workspace_operation_not_replayable, id, status}}, state}

  defp reconciliation_required(%{state: :needs_reconciliation}), do: :ok
  defp reconciliation_required(_workspace), do: {:error, :workspace_reconciliation_not_required}

  defp restoration_report(interrupted, workspace) do
    recovery = map_value(interrupted.error, :recovery, %{})

    cond do
      restoration_available?(interrupted) ->
        restoration_details(
          workspace,
          map_value(recovery, :backup_path),
          map_value(recovery, :source_state_token)
        )

      is_binary(interrupted_apply_backup_path(interrupted)) ->
        derive_interrupted_apply_restoration(interrupted, workspace)

      true ->
        %{available: false}
    end
  end

  defp restoration_available?(interrupted) do
    recovery = map_value(interrupted.error, :recovery, %{})

    is_binary(map_value(recovery, :backup_path)) and
      is_binary(map_value(recovery, :source_state_token))
  end

  defp restoration_available?(interrupted, report) do
    restoration_available?(interrupted) or
      map_value(map_value(report, :restoration, %{}), :available, false) == true
  end

  defp derive_interrupted_apply_restoration(interrupted, workspace) do
    backup_path = interrupted_apply_backup_path(interrupted)
    result_tree = workspace.result_manifest && workspace.result_manifest.result_tree

    with path when is_binary(path) <- backup_path,
         true <- File.dir?(path),
         true <- File.regular?(Path.join(path, "backup.json")),
         {:ok, inspection} <- RepositoryInspection.inspect(workspace.repository),
         {:ok, capture} <-
           SourceRead.capture_worktree_result(
             workspace.repository,
             workspace.base_commit,
             artifact_base: workspace.base_commit
           ),
         {:ok, base_tree} <-
           SourceRead.resolve_tree(workspace.repository, workspace.base_commit),
         true <- capture.result_tree in [base_tree, result_tree] do
      restoration_details(workspace, path, inspection.source_state_token)
    else
      _unavailable -> %{available: false}
    end
  end

  defp restoration_details(workspace, backup_path, source_state_token) do
    %{
      available: true,
      backup_path: backup_path,
      source_state_token: source_state_token,
      command:
        "twelvgaige workspace reconcile #{workspace.id} --write --yes --expected-epoch #{workspace.control_epoch} --action restore-backup"
    }
  end

  defp interrupted_apply_backup_path(%Operation{effects: effects}) do
    Enum.find_value(effects, fn effect ->
      if map_value(effect, :kind) in [:current_worktree_backup, :current_worktree_restore],
        do: map_value(effect, :backup_path),
        else: nil
    end)
  end

  defp export_resume_report(interrupted, workspace) do
    case export_destination(interrupted) do
      destination when is_binary(destination) ->
        %{
          available: true,
          destination: destination,
          command:
            "twelvgaige workspace reconcile #{workspace.id} --write --yes --expected-epoch #{workspace.control_epoch} --action resume-export"
        }

      _missing ->
        %{available: false}
    end
  end

  defp export_resume_commands(%{available: true, command: command}), do: [command]
  defp export_resume_commands(_report), do: []

  defp export_resume_available?(interrupted), do: is_binary(export_destination(interrupted))

  defp export_destination(%Operation{effects: effects}) do
    Enum.find_value(effects, fn effect ->
      if map_value(effect, :kind) in [:artifact_export_publish, :artifact_export_resume],
        do: map_value(effect, :path),
        else: nil
    end)
  end

  defp export_destination(_operation), do: nil

  defp export_source_request_id(%Operation{request_id: request_id, effects: effects}) do
    Enum.find_value(effects, request_id, fn effect ->
      if map_value(effect, :kind) == :artifact_export_resume,
        do: map_value(effect, :source_request_id),
        else: nil
    end)
  end

  defp cleanup_resume_report(interrupted, workspace) do
    if cleanup_resume_available?(interrupted) do
      %{
        available: true,
        path: workspace.path,
        command:
          "twelvgaige workspace reconcile #{workspace.id} --write --yes --expected-epoch #{workspace.control_epoch} --action resume-cleanup"
      }
    else
      %{available: false}
    end
  end

  defp cleanup_resume_commands(%{available: true, command: command}), do: [command]
  defp cleanup_resume_commands(_report), do: []

  defp cleanup_resume_available?(%Operation{kind: :cleanup}), do: true

  defp cleanup_resume_available?(%Operation{effects: effects}) do
    Enum.any?(effects, &(map_value(&1, :kind) == :managed_path_remove_resume))
  end

  defp review_discard_report(interrupted, workspace, state) do
    if review_discard_available?(interrupted, workspace, state) do
      destination = review_destination(interrupted)

      %{
        available: true,
        path: destination,
        command:
          "twelvgaige workspace reconcile #{workspace.id} --write --yes --expected-epoch #{workspace.control_epoch} --action discard-review"
      }
    else
      %{available: false}
    end
  end

  defp review_discard_commands(%{available: true, command: command}), do: [command]
  defp review_discard_commands(_report), do: []

  defp review_discard_available?(%Operation{} = interrupted, workspace, state) do
    destination = review_destination(interrupted)

    with :ok <- valid_review_destination(destination, workspace, state) do
      case File.lstat(destination) do
        {:error, :enoent} -> true
        {:ok, %{type: :directory}} -> review_tree_discardable?(destination, workspace)
        _other -> false
      end
    else
      {:error, _reason} -> false
    end
  end

  defp review_destination(%Operation{effects: effects}) do
    Enum.find_value(effects, fn effect ->
      if map_value(effect, :kind) in [
           :review_worktree_create,
           :verified_review_worktree_remove,
           :interrupted_review_discard
         ],
         do: map_value(effect, :path),
         else: nil
    end)
  end

  defp valid_review_destination(destination, workspace, state) when is_binary(destination) do
    expected = Path.join([state.root, "reviews", workspace.id]) |> Path.expand()

    if Path.expand(destination) == expected,
      do: :ok,
      else: {:error, :review_worktree_path_invalid}
  end

  defp valid_review_destination(_destination, _workspace, _state),
    do: {:error, :review_worktree_path_invalid}

  defp review_tree_discardable?(destination, workspace) do
    result_tree = workspace.result_manifest && workspace.result_manifest.result_tree

    with {:ok, capture} <-
           SourceRead.capture_worktree_result(
             destination,
             workspace.base_commit,
             artifact_base: workspace.base_commit
           ),
         {:ok, base_tree} <- SourceRead.resolve_tree(destination, workspace.base_commit) do
      capture.result_tree in [base_tree, result_tree]
    else
      {:error, _reason} -> false
    end
  end

  defp recommended_reconciliation_action(%{available: true}, _cleanup, _review),
    do: :resume_export

  defp recommended_reconciliation_action(_export, %{available: true}, _review),
    do: :resume_cleanup

  defp recommended_reconciliation_action(_export, _cleanup, %{available: true}),
    do: :discard_review

  defp recommended_reconciliation_action(_export, _cleanup, _review), do: :quarantine

  defp apply_workspace_operation(workspace_id, opts, state) do
    with {:ok, workspace} <- fetch_workspace(state, workspace_id),
         {:ok, result} <- Result.load(workspace, state.artifact_store) do
      case Keyword.get(opts, :target, :review_worktree) do
        target when target in [:review_worktree, "review-worktree", nil] ->
          with {:ok, check} <- ReviewWorktree.check(workspace, result, opts) do
            if Keyword.get(opts, :write?, false) do
              apply_review_write(workspace, result, check, opts, state)
            else
              {{:ok, check}, state}
            end
          else
            {:error, reason} -> {{:error, reason}, state}
          end

        target when target in [:current_worktree, "current-worktree"] ->
          if Keyword.get(opts, :write?, false) do
            apply_current_write(workspace, result, opts, state)
          else
            case DirectApply.check(workspace, result, opts) do
              {:ok, check} -> {{:ok, check}, state}
              {:error, reason} -> {{:error, reason}, state}
            end
          end

        _target ->
          {{:error, :workspace_apply_target_invalid}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp apply_current_write(workspace, result, opts, state) do
    expected_epoch = Keyword.get(opts, :expected_epoch)
    request_id = Keyword.get(opts, :request_id)
    backup_root = Path.join([state.root, "backups", workspace.id]) |> Path.expand()
    manifest = result.manifest

    intent = %{
      "kind" => "apply_current",
      "workspace_id" => workspace.id,
      "repository" => workspace.repository,
      "backup_root" => backup_root,
      "expected_epoch" => expected_epoch,
      "patch_digest" => map_value(manifest, :patch_digest),
      "result_tree" => map_value(manifest, :result_tree)
    }

    candidate =
      Operation.new(:apply_current, workspace.id, intent,
        request_id: request_id || "",
        expected_epoch: expected_epoch,
        now: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
      )

    cond do
      Keyword.get(opts, :yes?, false) != true ->
        {{:error, :workspace_apply_confirmation_required}, state}

      not is_integer(expected_epoch) ->
        {{:error, :workspace_expected_epoch_required}, state}

      not is_binary(request_id) or request_id == "" ->
        {{:error, :workspace_request_id_required}, state}

      true ->
        case operation_admission(candidate, state) do
          {:replay, operation} ->
            replay_apply(operation, state)

          {:error, reason} ->
            {{:error, reason}, state}

          :new ->
            with {:ok, _check} <- DirectApply.check(workspace, result, opts) do
              execute_direct_apply(candidate, workspace, result, backup_root, opts, state)
            else
              {:error, reason} -> {{:error, reason}, state}
            end
        end
    end
  end

  defp execute_direct_apply(operation, workspace, result, backup_root, opts, state) do
    with :ok <- expected_epoch(workspace, operation.expected_epoch),
         :ok <- persist_operation(operation, state) do
      state = put_in(state.operations[operation.request_id], operation)

      started =
        Operation.transition(operation, :side_effects_started, %{
          effects: [
            %{
              kind: :current_worktree_backup,
              root: backup_root,
              backup_path: DirectApply.backup_path(backup_root, operation.request_id)
            },
            %{kind: :current_worktree_patch, repository: workspace.repository}
          ]
        })

      with :ok <- persist_operation(started, state) do
        state = put_in(state.operations[started.request_id], started)

        direct_opts =
          opts
          |> Keyword.put(:request_id, operation.request_id)
          |> Keyword.put(:operation_id, operation.id)
          |> Keyword.put(:expected_epoch, operation.expected_epoch)
          |> Keyword.put(:git_audit_fun, git_audit_sink(state, opts))
          |> Keyword.put(:fault_checkpoint_fun, state.fault_checkpoint_fun)
          |> Keyword.put_new(:backup_retention_days, state.backup_retention_days)

        apply_fun = Keyword.get(opts, :direct_apply_fun, &DirectApply.apply/4)

        case apply_fun.(workspace, result, backup_root, direct_opts) do
          {:ok, report} ->
            commit_apply(started, workspace, report, state)

          {:error, reason} ->
            backup_path = DirectApply.backup_path(backup_root, operation.request_id)

            case DirectApply.recovery_evidence(
                   workspace,
                   backup_root,
                   operation.request_id,
                   opts
                 ) do
              {:ok, recovery} ->
                direct_apply_reconciliation(started, workspace, reason, recovery, state)

              {:error, _recovery_reason} ->
                fail_apply(started, workspace, backup_path, reason, state)
            end
        end
      else
        {:error, reason} -> {{:error, {:workspace_operation_persistence_failed, reason}}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp direct_apply_reconciliation(operation, workspace, reason, recovery, state) do
    reconciliation =
      Operation.transition(operation, :needs_reconciliation, %{
        error: %{failure: reason, recovery: recovery}
      })

    updated = %{
      workspace
      | state: :needs_reconciliation,
        quarantine_reason: {:workspace_apply_interrupted, operation.request_id},
        last_operation_id: operation.id,
        control_epoch: workspace.control_epoch + 1
    }

    _ = persist_workspace(updated, state)
    _ = persist_operation(reconciliation, state)

    next =
      state
      |> put_in([Access.key!(:workspaces), workspace.id], updated)
      |> put_in([Access.key!(:operations), reconciliation.request_id], reconciliation)

    {{:error, {:workspace_operation_needs_reconciliation, operation.request_id, reason}}, next}
  end

  defp apply_review_write(workspace, result, check, opts, state) do
    expected_epoch = Keyword.get(opts, :expected_epoch)
    request_id = Keyword.get(opts, :request_id)
    destination = Path.join([state.root, "reviews", workspace.id]) |> Path.expand()

    intent = %{
      "kind" => "apply_review",
      "workspace_id" => workspace.id,
      "repository" => workspace.repository,
      "destination" => destination,
      "expected_epoch" => expected_epoch,
      "patch_digest" => check.patch_digest,
      "result_tree" => check.result_tree
    }

    candidate =
      Operation.new(:apply_review, workspace.id, intent,
        request_id: request_id || "",
        expected_epoch: expected_epoch,
        now: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
      )
      |> Map.put(:effects, [%{kind: :review_worktree_create, path: destination}])

    cond do
      Keyword.get(opts, :yes?, false) != true ->
        {{:error, :workspace_apply_confirmation_required}, state}

      not is_integer(expected_epoch) ->
        {{:error, :workspace_expected_epoch_required}, state}

      not is_binary(request_id) or request_id == "" ->
        {{:error, :workspace_request_id_required}, state}

      true ->
        case operation_admission(candidate, state) do
          {:replay, operation} -> replay_apply(operation, state)
          {:error, reason} -> {{:error, reason}, state}
          :new -> execute_apply(candidate, workspace, result, destination, opts, state)
        end
    end
  end

  defp execute_apply(operation, workspace, result, destination, opts, state) do
    with :ok <- expected_epoch(workspace, operation.expected_epoch),
         :ok <- persist_operation(operation, state) do
      state = put_in(state.operations[operation.request_id], operation)

      started =
        Operation.transition(operation, :side_effects_started, %{
          effects: operation.effects
        })

      with :ok <- persist_operation(started, state) do
        state = put_in(state.operations[started.request_id], started)

        review_opts =
          opts
          |> Keyword.put(:request_id, operation.request_id)
          |> Keyword.put(:operation_id, operation.id)
          |> Keyword.put(:expected_epoch, operation.expected_epoch)
          |> Keyword.put(:git_audit_fun, git_audit_sink(state, opts))
          |> Keyword.put(:fault_checkpoint_fun, state.fault_checkpoint_fun)

        case ReviewWorktree.create(workspace, result, destination, review_opts) do
          {:ok, report} -> commit_apply(started, workspace, report, state)
          {:error, reason} -> fail_apply(started, workspace, destination, reason, state)
        end
      else
        {:error, reason} -> {{:error, {:workspace_operation_persistence_failed, reason}}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp commit_apply(operation, workspace, report, state) do
    updated = %{
      workspace
      | last_operation_id: operation.id,
        control_epoch: workspace.control_epoch + 1
    }

    completed =
      Operation.transition(operation, :completed, %{
        result: Map.put(report, :control_epoch, updated.control_epoch)
      })

    lifecycle = FaultMatrix.operation_lifecycle(operation)

    with :ok <- persist_lifecycle_workspace(updated, state, lifecycle, operation),
         :ok <- persist_operation(completed, state) do
      next =
        state
        |> put_in([Access.key!(:workspaces), workspace.id], updated)
        |> put_in([Access.key!(:operations), completed.request_id], completed)

      {{:ok, completed.result}, next}
    else
      {:error, reason} -> apply_reconciliation(operation, workspace, reason, state)
    end
  end

  defp fail_apply(operation, workspace, destination, reason, state) do
    if File.exists?(destination) do
      apply_reconciliation(operation, workspace, reason, state)
    else
      failed = Operation.transition(operation, :failed, %{error: reason})
      _ = persist_operation(failed, state)
      next = put_in(state.operations[failed.request_id], failed)
      {{:error, reason}, next}
    end
  end

  defp apply_reconciliation(operation, workspace, reason, state) do
    reconciliation = Operation.transition(operation, :needs_reconciliation, %{error: reason})

    updated = %{
      workspace
      | state: :needs_reconciliation,
        quarantine_reason: {:workspace_apply_interrupted, operation.request_id},
        last_operation_id: operation.id,
        control_epoch: workspace.control_epoch + 1
    }

    _ = persist_workspace(updated, state)
    _ = persist_operation(reconciliation, state)

    next =
      state
      |> put_in([Access.key!(:workspaces), workspace.id], updated)
      |> put_in([Access.key!(:operations), reconciliation.request_id], reconciliation)

    {{:error, {:workspace_operation_needs_reconciliation, operation.request_id, reason}}, next}
  end

  defp replay_apply(%Operation{status: :completed, result: result}, state),
    do: {{:ok, Map.put(result, :replayed, true)}, state}

  defp replay_apply(%Operation{request_id: id, status: status}, state),
    do: {{:error, {:workspace_operation_not_replayable, id, status}}, state}

  defp finalize_workspace_operation(workspace_id, opts, state) do
    with {:ok, workspace} <- fetch_workspace(state, workspace_id) do
      request_id = Keyword.get(opts, :request_id, "req_workspace_finalize_" <> random_id())

      expected_epoch =
        Keyword.get_lazy(opts, :expected_epoch, fn ->
          case Map.get(state.operations, request_id) do
            %Operation{expected_epoch: epoch} when is_integer(epoch) -> epoch
            _operation -> workspace.control_epoch
          end
        end)

      intent = %{
        "kind" => "finalize",
        "workspace_id" => workspace.id,
        "expected_epoch" => expected_epoch,
        "agent_execution" => Keyword.get(opts, :agent_execution, :completed),
        "test_verification" => Keyword.get(opts, :test_verification, :not_run)
      }

      candidate =
        Operation.new(:finalize, workspace.id, intent,
          request_id: request_id,
          expected_epoch: expected_epoch,
          now: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
        )

      case operation_admission(candidate, state) do
        {:replay, operation} ->
          replay_finalize(operation, state)

        {:error, reason} ->
          {{:error, reason}, state}

        :new ->
          with :ok <- finalizable(workspace),
               :ok <- expected_epoch(workspace, expected_epoch) do
            execute_finalize_operation(candidate, workspace, opts, state)
          else
            {:error, reason} -> {{:error, reason}, state}
          end
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp execute_finalize_operation(operation, workspace, opts, state) do
    with :ok <- persist_operation(operation, state) do
      state = put_in(state.operations[operation.request_id], operation)

      started =
        Operation.transition(operation, :side_effects_started, %{
          effects: [
            %{kind: :result_capture, workspace_id: workspace.id},
            %{kind: :artifact_publication, workspace_id: workspace.id}
          ]
        })

      with :ok <- persist_operation(started, state) do
        state = put_in(state.operations[started.request_id], started)

        finalize_opts =
          opts
          |> Keyword.put(:request_id, operation.request_id)
          |> Keyword.put(:operation_id, operation.id)
          |> Keyword.put(:expected_epoch, operation.expected_epoch)
          |> Keyword.put(:fault_checkpoint_fun, state.fault_checkpoint_fun)

        case finalize_workspace_record(workspace, finalize_opts, state) do
          {:ok, finalized, report} ->
            finalized = %{
              finalized
              | last_operation_id: operation.id,
                storage_reservation: released_storage(finalized.storage_reservation)
            }

            completed =
              Operation.transition(started, :completed, %{
                result: %{
                  workspace_id: workspace.id,
                  status: report.status,
                  manifest_digest: report.manifest.manifest_digest,
                  artifact_ref: report.artifact_ref,
                  control_epoch: finalized.control_epoch
                }
              })

            with :ok <-
                   persist_lifecycle_workspace(finalized, state, :finalize, operation),
                 :ok <- persist_operation(completed, state) do
              next =
                state
                |> put_in([Access.key!(:workspaces), workspace.id], finalized)
                |> update_in([Access.key!(:writer_leases)], &Map.delete(&1, workspace.id))
                |> put_in([Access.key!(:operations), completed.request_id], completed)
                |> release_storage(workspace.id)

              {{:ok, finalized, report}, next}
            else
              {:error, reason} ->
                finalize_reconciliation(started, workspace, reason, state)
            end

          {:error, reason} ->
            finalize_reconciliation(started, workspace, reason, state)
        end
      else
        {:error, reason} -> {{:error, {:workspace_operation_persistence_failed, reason}}, state}
      end
    else
      {:error, reason} -> {{:error, {:workspace_operation_persistence_failed, reason}}, state}
    end
  end

  defp finalize_reconciliation(operation, workspace, reason, state) do
    reconciliation = Operation.transition(operation, :needs_reconciliation, %{error: reason})

    workspace = %{
      workspace
      | state: :needs_reconciliation,
        quarantine_reason: {:workspace_finalization_interrupted, operation.request_id},
        last_operation_id: operation.id,
        control_epoch: workspace.control_epoch + 1
    }

    _ = persist_workspace(workspace, state)
    _ = persist_operation(reconciliation, state)

    next =
      state
      |> put_in([Access.key!(:workspaces), workspace.id], workspace)
      |> put_in([Access.key!(:operations), reconciliation.request_id], reconciliation)

    {{:error, {:workspace_operation_needs_reconciliation, operation.request_id, reason}}, next}
  end

  defp replay_finalize(%Operation{status: :completed, workspace_id: workspace_id}, state) do
    with {:ok, workspace} <- Map.fetch(state.workspaces, workspace_id),
         %ResultManifest{} = manifest <- workspace.result_manifest do
      report = %{
        status: if(manifest.no_change, do: :no_change, else: :changed),
        diff: nil,
        patch: nil,
        manifest: manifest,
        changed_paths: manifest.changed_paths,
        out_of_policy: manifest.out_of_policy,
        integrity: :verified,
        artifact_ref: workspace.result_artifact_ref,
        replayed: true
      }

      {{:ok, workspace, report}, state}
    else
      _missing -> {{:error, :workspace_operation_result_missing}, state}
    end
  end

  defp replay_finalize(%Operation{status: status, request_id: request_id}, state) do
    {{:error, {:workspace_operation_not_replayable, request_id, status}}, state}
  end

  defp fetch_workspace(state, workspace_id) do
    case Map.fetch(state.workspaces, workspace_id) do
      {:ok, workspace} -> {:ok, workspace}
      :error -> {:error, :workspace_not_found}
    end
  end

  defp expected_epoch(%{control_epoch: epoch}, epoch), do: :ok
  defp expected_epoch(_workspace, _expected), do: {:error, :workspace_control_epoch_conflict}

  defp cleanup_workspace_operation(workspace_id, opts, state) do
    with {:ok, workspace} <- fetch_workspace(state, workspace_id) do
      case replay_cleanup_request(workspace, opts, state) do
        :new -> cleanup_workspace_preflight(workspace, opts, state)
        {reply, next} -> {reply, next}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp cleanup_workspace_preflight(workspace, opts, state) do
    with :ok <- cleanup_candidate(workspace),
         :ok <- cleanup_recoverable(workspace),
         :ok <- exact_managed_path(workspace, state.root),
         {:ok, usage} <- managed_path_usage(workspace.path) do
      report = %{
        workspace_id: workspace.id,
        path: workspace.path,
        bytes: usage.bytes,
        entries: usage.entries,
        artifact_refs: workspace.artifact_refs,
        recoverable: true,
        dry_run: not Keyword.get(opts, :write, false),
        requires_confirmation: true,
        expected_epoch: workspace.control_epoch
      }

      if Keyword.get(opts, :write, false) do
        with true <-
               Keyword.get(opts, :yes, false) or
                 {:error, :workspace_cleanup_confirmation_required},
             :ok <- expected_epoch(workspace, Keyword.get(opts, :expected_epoch)) do
          execute_cleanup_request(workspace, report, opts, state)
        else
          {:error, reason} -> {{:error, reason}, state}
        end
      else
        {{:ok, report}, state}
      end
    else
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  defp replay_cleanup_request(workspace, opts, state) do
    request_id = Keyword.get(opts, :request_id)

    case {Keyword.get(opts, :write, false), request_id && Map.get(state.operations, request_id)} do
      {true, %Operation{kind: :cleanup, expected_epoch: expected_epoch}} ->
        requested_epoch = Keyword.get(opts, :expected_epoch)

        intent = %{
          "kind" => "cleanup",
          "workspace_id" => workspace.id,
          "path" => workspace.path,
          "expected_epoch" => requested_epoch,
          "artifact_refs" => workspace.artifact_refs
        }

        candidate =
          Operation.new(:cleanup, workspace.id, intent,
            request_id: request_id,
            expected_epoch: requested_epoch
          )

        if requested_epoch == expected_epoch do
          case operation_admission(candidate, state) do
            {:replay, operation} -> replay_cleanup(operation, state)
            {:error, reason} -> {{:error, reason}, state}
            :new -> :new
          end
        else
          {{:error, :workspace_idempotency_conflict}, state}
        end

      _other ->
        :new
    end
  end

  defp execute_cleanup_request(workspace, report, opts, state) do
    request_id = Keyword.get(opts, :request_id, "req_workspace_cleanup_" <> random_id())

    intent = %{
      "kind" => "cleanup",
      "workspace_id" => workspace.id,
      "path" => workspace.path,
      "expected_epoch" => workspace.control_epoch,
      "artifact_refs" => workspace.artifact_refs
    }

    candidate =
      Operation.new(:cleanup, workspace.id, intent,
        request_id: request_id,
        expected_epoch: workspace.control_epoch,
        now: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
      )

    case operation_admission(candidate, state) do
      {:replay, operation} -> replay_cleanup(operation, state)
      {:error, reason} -> {{:error, reason}, state}
      :new -> execute_cleanup_operation(candidate, workspace, report, state)
    end
  end

  defp execute_cleanup_operation(operation, workspace, report, state) do
    with :ok <- persist_operation(operation, state) do
      state = put_in(state.operations[operation.request_id], operation)

      started =
        Operation.transition(operation, :side_effects_started, %{
          effects: [%{kind: :remove_exact_managed_path, path: workspace.path}]
        })

      with :ok <- persist_operation(started, state),
           :ok <-
             FaultMatrix.around(
               fault_opts(state),
               FaultMatrix.operation_lifecycle(operation),
               :managed_path_remove,
               operation_metadata(operation),
               fn -> remove_exact_managed_path(workspace.path) end
             ) do
        deleted = %{
          workspace
          | state: :deleted,
            last_operation_id: operation.id,
            control_epoch: workspace.control_epoch + 1
        }

        completed_report = Map.merge(report, %{dry_run: false, deleted: true})

        completed =
          Operation.transition(started, :completed, %{
            result: %{
              workspace_id: workspace.id,
              deleted: true,
              path: workspace.path,
              bytes: report.bytes,
              control_epoch: deleted.control_epoch
            }
          })

        with :ok <-
               persist_lifecycle_workspace(
                 deleted,
                 state,
                 FaultMatrix.operation_lifecycle(operation),
                 operation
               ),
             :ok <- persist_operation(completed, state) do
          next =
            state
            |> put_in([Access.key!(:workspaces), deleted.id], deleted)
            |> update_in([Access.key!(:writer_leases)], &Map.delete(&1, deleted.id))
            |> put_in([Access.key!(:operations), completed.request_id], completed)

          {{:ok, completed_report}, next}
        else
          {:error, reason} -> cleanup_reconciliation(started, workspace, reason, state)
        end
      else
        {:error, reason} -> cleanup_reconciliation(started, workspace, reason, state)
      end
    else
      {:error, reason} -> {{:error, {:workspace_operation_persistence_failed, reason}}, state}
    end
  end

  defp cleanup_reconciliation(operation, workspace, reason, state) do
    reconciliation = Operation.transition(operation, :needs_reconciliation, %{error: reason})

    workspace = %{
      workspace
      | state: :needs_reconciliation,
        quarantine_reason: {:workspace_cleanup_interrupted, operation.request_id},
        last_operation_id: operation.id,
        control_epoch: workspace.control_epoch + 1
    }

    _ = persist_workspace(workspace, state)
    _ = persist_operation(reconciliation, state)

    next =
      state
      |> put_in([Access.key!(:workspaces), workspace.id], workspace)
      |> put_in([Access.key!(:operations), reconciliation.request_id], reconciliation)

    {{:error, {:workspace_operation_needs_reconciliation, operation.request_id, reason}}, next}
  end

  defp replay_cleanup(%Operation{status: :completed} = operation, state) do
    report = Map.merge(operation.result, %{dry_run: false, replayed: true})
    {{:ok, report}, state}
  end

  defp replay_cleanup(%Operation{status: status, request_id: request_id}, state) do
    {{:error, {:workspace_operation_not_replayable, request_id, status}}, state}
  end

  defp cleanup_candidate(%{state: state}) when state in [:reviewable, :quarantined, :retained],
    do: :ok

  defp cleanup_candidate(%{state: :deleted}), do: {:error, :workspace_already_deleted}
  defp cleanup_candidate(_workspace), do: {:error, :workspace_cleanup_active}

  defp cleanup_recoverable(%{result_manifest: %{no_change: true}}), do: :ok

  defp cleanup_recoverable(%{result_artifact_ref: %Twelvgaige.Artifact.Ref{}}),
    do: :ok

  defp cleanup_recoverable(_workspace), do: {:error, :workspace_cleanup_result_not_recoverable}

  defp exact_managed_path(workspace, root) do
    expected = Path.join(root, workspace.id) |> Path.expand()

    cond do
      workspace.path != expected -> {:error, :workspace_cleanup_path_mismatch}
      not within_root?(workspace.path, root) -> {:error, :workspace_cleanup_path_outside_root}
      true -> :ok
    end
  end

  defp managed_path_usage(path), do: managed_path_usage(path, 0, 0)

  defp managed_path_usage(_path, entries, _bytes) when entries > 1_000_000,
    do: {:error, :workspace_cleanup_scan_limit_exceeded}

  defp managed_path_usage(path, entries, bytes) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        with {:ok, names} <- File.ls(path) do
          Enum.reduce_while(names, {:ok, %{entries: entries + 1, bytes: bytes}}, fn name,
                                                                                    {:ok, acc} ->
            case managed_path_usage(Path.join(path, name), acc.entries, acc.bytes) do
              {:ok, next} -> {:cont, {:ok, next}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
          end)
        end

      {:ok, %{size: size}} ->
        {:ok, %{entries: entries + 1, bytes: bytes + size}}

      {:error, reason} ->
        {:error, {:workspace_cleanup_scan_failed, path, reason}}
    end
  end

  defp remove_exact_managed_path(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory}} ->
        case File.rm_rf(path) do
          {:ok, _paths} -> :ok
          {:error, reason, failed_path} -> {:error, {reason, failed_path}}
        end

      {:ok, _stat} ->
        {:error, :workspace_cleanup_target_not_directory}

      {:error, :enoent} ->
        {:error, :workspace_cleanup_target_missing}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp create_workspace_operation(repository, opts, state) do
    workspace_id = Keyword.get(opts, :workspace_id, Twelvgaige.ID.new(:workspace))
    request_id = Keyword.get(opts, :request_id, "req_workspace_create_" <> random_id())
    repository = Path.expand(repository)
    storage = storage_request(opts)

    intent = %{
      "kind" => "create",
      "workspace_id" => workspace_id,
      "repository" => repository,
      "transport" => Keyword.get(opts, :transport, :copy_snapshot),
      "base_ref" => Keyword.get(opts, :base_ref, "HEAD"),
      "source_mode" => Keyword.get(opts, :source_mode, :committed),
      "expected_source_state_token" => Keyword.get(opts, :expected_source_state_token),
      "include_untracked" => Keyword.get(opts, :include_untracked, false),
      "include_ignored" => Keyword.get(opts, :include_ignored, false),
      "writable" => Keyword.get(opts, :writable, true),
      "allowed_paths" => Keyword.get(opts, :allowed_paths, []),
      "storage" => storage
    }

    candidate =
      Operation.new(:create, workspace_id, intent,
        request_id: request_id,
        now: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
      )

    case operation_admission(candidate, state) do
      {:replay, operation} ->
        replay_create(operation, state)

      {:error, reason} ->
        {{:error, reason}, state}

      :new ->
        execute_create_operation(candidate, repository, storage, opts, state)

      {:retry, operation} ->
        operation =
          Operation.transition(operation, :intent_recorded, %{
            error: nil,
            result: nil,
            effects: [],
            now: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
          })

        execute_create_operation(operation, repository, storage, opts, state)
    end
  end

  defp execute_create_operation(operation, repository, storage, opts, state) do
    with {:ok, reservation, state} <- reserve_storage(operation.workspace_id, storage, state),
         :ok <- persist_operation(operation, state) do
      state = put_in(state.operations[operation.request_id], operation)

      started =
        Operation.transition(operation, :side_effects_started, %{
          effects: [
            %{kind: :managed_path_reserved, path: Path.join(state.root, operation.workspace_id)}
          ]
        })

      with :ok <- persist_operation(started, state) do
        state = put_in(state.operations[started.request_id], started)

        opts =
          opts
          |> Keyword.put(:workspace_id, operation.workspace_id)
          |> Keyword.put(:creation_operation_id, operation.id)
          |> Keyword.put(:storage_reservation, reservation)

        case FaultMatrix.around(
               fault_opts(state, opts),
               :create,
               :workspace_materialize,
               operation_metadata(operation),
               fn -> create_workspace(repository, opts, state) end
             ) do
          {{:ok, workspace}, next} ->
            workspace = %{
              workspace
              | creation_operation_id: operation.id,
                last_operation_id: operation.id,
                storage_reservation: reservation
            }

            completed =
              Operation.transition(started, :completed, %{
                result: %{
                  workspace_id: workspace.id,
                  control_epoch: workspace.control_epoch,
                  source_manifest_digest:
                    workspace.source_manifest && workspace.source_manifest.manifest_digest
                }
              })

            with :ok <-
                   persist_lifecycle_workspace(workspace, next, :create, operation),
                 :ok <- persist_operation(completed, next) do
              next =
                next
                |> put_in([Access.key!(:workspaces), workspace.id], workspace)
                |> put_in([Access.key!(:operations), completed.request_id], completed)

              {{:ok, workspace}, next}
            else
              {:error, reason} ->
                reconciliation =
                  Operation.transition(started, :needs_reconciliation, %{
                    error: {:workspace_create_commit_failed, reason}
                  })

                _ = persist_operation(reconciliation, next)
                next = put_in(next.operations[reconciliation.request_id], reconciliation)

                {{:error, {:workspace_operation_needs_reconciliation, request_id(operation)}},
                 next}
            end

          {{:error, reason}, next} ->
            failed_status =
              if managed_path_exists?(state.root, operation.workspace_id),
                do: :needs_reconciliation,
                else: :failed

            failed = Operation.transition(started, failed_status, %{error: reason})
            _ = persist_operation(failed, next)

            next =
              next
              |> put_in([Access.key!(:operations), failed.request_id], failed)
              |> release_storage(operation.workspace_id)

            {{:error, reason}, next}
        end
      else
        {:error, reason} ->
          {{:error, {:workspace_operation_persistence_failed, reason}},
           release_storage(state, operation.workspace_id)}
      end
    else
      {:error, {:workspace_storage_unavailable, _details} = reason} ->
        {{:error, reason}, state}

      {:error, reason} ->
        {{:error, {:workspace_operation_persistence_failed, reason}},
         release_storage(state, operation.workspace_id)}
    end
  end

  defp operation_admission(candidate, state) do
    if Operation.valid?(candidate) do
      existing_operation(candidate, state)
    else
      {:error, :workspace_request_id_invalid}
    end
  end

  defp existing_operation(candidate, state) do
    case Map.get(state.operations, candidate.request_id) do
      nil ->
        :new

      %{
        kind: :create,
        status: :failed,
        error: :workspace_create_interrupted_before_materialization,
        intent_digest: digest
      } = existing
      when candidate.kind == :create and digest == candidate.intent_digest ->
        {:retry, existing}

      %{kind: kind, intent_digest: digest} = existing
      when kind == candidate.kind and digest == candidate.intent_digest ->
        {:replay, existing}

      _existing ->
        {:error, :workspace_idempotency_conflict}
    end
  end

  defp replay_create(%Operation{status: :completed, workspace_id: workspace_id}, state) do
    case Map.fetch(state.workspaces, workspace_id) do
      {:ok, workspace} -> {{:ok, workspace}, state}
      :error -> {{:error, :workspace_operation_result_missing}, state}
    end
  end

  defp replay_create(%Operation{status: status, request_id: request_id}, state) do
    {{:error, {:workspace_operation_not_replayable, request_id, status}}, state}
  end

  defp managed_path_exists?(root, workspace_id) do
    case File.lstat(Path.join(root, workspace_id)) do
      {:ok, _stat} -> true
      {:error, _reason} -> false
    end
  end

  defp request_id(%Operation{request_id: request_id}), do: request_id

  defp storage_request(opts) do
    %{
      execution_bytes: Keyword.get(opts, :execution_reserve_bytes, @default_execution_reserve),
      result_bytes: Keyword.get(opts, :result_reserve_bytes, @default_result_reserve),
      verification_bytes:
        Keyword.get(opts, :verification_reserve_bytes, @default_verification_reserve)
    }
  end

  defp reserve_storage(workspace_id, request, state) do
    values = Map.values(request)

    if Enum.all?(values, &(is_integer(&1) and &1 >= 0)) do
      requested = Enum.sum(values)

      already_reserved =
        state.storage_reservations |> Map.values() |> Enum.map(& &1.total_bytes) |> Enum.sum()

      case state.disk_available_fun.(state.root) do
        {:ok, available} when is_integer(available) and available >= 0 ->
          required = already_reserved + requested + state.protected_finalization_bytes

          if available >= required do
            reservation = %{
              workspace_id: workspace_id,
              execution_bytes: request.execution_bytes,
              result_bytes: request.result_bytes,
              verification_bytes: request.verification_bytes,
              total_bytes: requested,
              protected_finalization_bytes: state.protected_finalization_bytes,
              available_at_admission: available,
              status: :reserved,
              created_at: Twelvgaige.Clock.utc_now()
            }

            {:ok, reservation, put_in(state.storage_reservations[workspace_id], reservation)}
          else
            {:error,
             {:workspace_storage_unavailable,
              %{
                available_bytes: available,
                requested_bytes: requested,
                active_reserved_bytes: already_reserved,
                protected_finalization_bytes: state.protected_finalization_bytes,
                required_bytes: required
              }}}
          end

        {:error, reason} ->
          {:error, {:workspace_storage_unavailable, %{probe_error: reason}}}

        other ->
          {:error, {:workspace_storage_unavailable, %{probe_error: other}}}
      end
    else
      {:error, {:workspace_storage_unavailable, %{reason: :reservation_invalid}}}
    end
  end

  defp release_storage(state, workspace_id) do
    %{state | storage_reservations: Map.delete(state.storage_reservations, workspace_id)}
  end

  defp released_storage(nil), do: nil
  defp released_storage(reservation), do: %{reservation | status: :released}

  defp create_workspace(repository, opts, state) do
    opts = Keyword.put_new(opts, :git_audit_fun, git_audit_sink(state, opts))
    transport = Keyword.get(opts, :transport, :copy_snapshot)
    interactive? = Keyword.get(opts, :interactive?, false)
    workspace_id = Keyword.get(opts, :workspace_id, Twelvgaige.ID.new(:workspace))

    with :ok <- valid_workspace_id(workspace_id),
         false <- Map.has_key?(state.workspaces, workspace_id),
         :ok <- admit_transport(transport, interactive?),
         path <- Path.join(state.root, workspace_id),
         {:ok, transport_info} <- create_transport(transport, repository, path, opts) do
      workspace =
        Workspace.new(
          id: workspace_id,
          round_id: Keyword.get(opts, :round_id),
          shot_id: Keyword.get(opts, :shot_id),
          attempt: Keyword.get(opts, :attempt),
          repository: repository,
          base_ref: Keyword.get(opts, :base_ref, "HEAD"),
          base_commit: transport_info.base_commit,
          source_mode: transport_info.source_mode,
          source_manifest: transport_info.source_manifest,
          input_tree: transport_info.input_tree,
          workspace_baseline_commit: transport_info.workspace_baseline_commit,
          creation_operation_id: Keyword.get(opts, :creation_operation_id),
          last_operation_id: Keyword.get(opts, :creation_operation_id),
          storage_reservation: Keyword.get(opts, :storage_reservation),
          transport: transport,
          path: path,
          writable: Keyword.get(opts, :writable, true),
          allowed_paths: Keyword.get(opts, :allowed_paths, []),
          created_at: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
        )

      case persist_workspace(workspace, state) do
        :ok ->
          {{:ok, workspace}, put_in(state.workspaces[workspace_id], workspace)}

        {:error, reason} ->
          _ = File.rm_rf(path)
          {{:error, {:workspace_persistence_failed, reason}}, state}
      end
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
        |> Keyword.put(:request_id, "req_workspace_set_create_#{set_id}_#{name}")
        |> Keyword.put(:creation_operation_id, "op_workspace_set_create_#{set_id}_#{name}")

      case create_workspace(repository, workspace_opts, current) do
        {{:ok, workspace}, next} ->
          owner_session_id = Keyword.fetch!(opts, :owner_session_id)

          workspace = %{
            workspace
            | owner_session_id: owner_session_id,
              state: :running,
              control_epoch: workspace.control_epoch + 1
          }

          case persist_workspace(workspace, next) do
            :ok ->
              next =
                next
                |> put_in([Access.key!(:workspaces), workspace.id], workspace)
                |> maybe_put_writer(workspace.id, owner_session_id, workspace.writable)

              {:cont, {:ok, Map.put(created, name, workspace), next, [workspace.path | paths]}}

            {:error, reason} ->
              {:halt, {:error, {:workspace_persistence_failed, reason}, current}}
          end

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
      operation_id =
        "op_workspace_set_finalize_#{Keyword.get(opts, :set_id, "set")}_#{workspace.id}"

      finalize_opts =
        opts
        |> Keyword.put(:request_id, operation_id)
        |> Keyword.put(:operation_id, operation_id)
        |> Keyword.put(:expected_epoch, workspace.control_epoch)

      case finalize_workspace(workspace, finalize_opts, current) do
        {:ok, finalized, report, next} ->
          {:cont,
           {:ok, Map.put(completed, name, finalized), Map.put(reports, name, report), next}}

        {:error, reason} ->
          {:halt, {:error, {:workspace_set_finalize_failed, name, reason}}}
      end
    end)
  end

  defp finalize_workspace(workspace, opts, state) do
    with :ok <- finalizable(workspace),
         {:ok, finalized, report} <- finalize_workspace_record(workspace, opts, state),
         :ok <- persist_workspace(finalized, state) do
      next =
        state
        |> put_in([Access.key!(:workspaces), workspace.id], finalized)
        |> update_in([Access.key!(:writer_leases)], &Map.delete(&1, workspace.id))

      {:ok, finalized, report, next}
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

  defp finalize_workspace_record(workspace, opts, state) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())

    git_opts =
      opts
      |> Keyword.put(:allowed_paths, workspace.allowed_paths)
      |> Keyword.put(:artifact_base, workspace.base_commit)

    with {:ok, authority} <- managed_authority(workspace, opts, :execution, state),
         {:ok, capture} <-
           FaultMatrix.around(
             opts,
             :capture,
             :result_tree_capture,
             lifecycle_metadata(workspace, opts),
             fn ->
               ManagedWorkspace.capture_result(
                 authority,
                 workspace.workspace_baseline_commit,
                 git_opts
               )
             end
           ),
         {:ok, head_commit} <- ManagedWorkspace.resolve_commit(authority, "HEAD", opts),
         {:ok, bundle} <-
           FaultMatrix.around(
             opts,
             :capture,
             :commit_bundle_capture,
             lifecycle_metadata(workspace, opts),
             fn ->
               ManagedWorkspace.capture_commit_bundle(
                 authority,
                 workspace.workspace_baseline_commit,
                 opts
               )
             end
           ),
         policy <- if(capture.out_of_policy == [], do: :compliant, else: :rejected),
         disposition <- if(policy == :compliant, do: :reviewable, else: :quarantined),
         outcomes <- %{
           agent_execution: Keyword.get(opts, :agent_execution, :completed),
           result_capture: :complete,
           artifact_integrity: :verified,
           test_verification: Keyword.get(opts, :test_verification, :not_run),
           policy_compliance: policy,
           workspace_disposition: disposition
         },
         {:ok, manifest} <-
           ResultManifest.new(%{
             workspace_id: workspace.id,
             source_base_commit: workspace.base_commit,
             workspace_baseline_commit: workspace.workspace_baseline_commit,
             result_tree: capture.result_tree,
             result_commit: head_commit,
             changed_paths: capture.changed_paths,
             patch: capture.patch,
             bundle: bundle,
             outcomes: outcomes,
             out_of_policy: capture.out_of_policy,
             no_change: capture.no_change,
             created_at: now
           }),
         {:ok, artifact_ref} <-
           FaultMatrix.around(
             opts,
             :finalize,
             :artifact_publish,
             lifecycle_metadata(workspace, opts),
             fn ->
               persist_result_artifact(manifest, capture.patch, bundle, workspace, now, state)
             end
           ) do
      manifest = %{manifest | artifact_ref: artifact_ref}

      finalized = %{
        workspace
        | dirty: not manifest.no_change,
          head_commit: head_commit,
          finalized_at: now,
          state: disposition,
          result_manifest: manifest,
          result_artifact_ref: artifact_ref,
          artifact_refs: append_artifact_ref(workspace.artifact_refs, artifact_ref),
          retention_expires_at:
            DateTime.add(
              now,
              Keyword.get(opts, :workspace_retention_days, state.workspace_retention_days),
              :day
            ),
          control_epoch: workspace.control_epoch + 1
      }

      {:ok, finalized,
       %{
         status: if(manifest.no_change, do: :no_change, else: :changed),
         diff: capture.patch,
         patch: capture.patch,
         manifest: manifest,
         changed_paths: capture.changed_paths,
         out_of_policy: capture.out_of_policy,
         integrity: :verified,
         artifact_ref: artifact_ref
       }}
    end
  end

  defp persist_result_artifact(
         _manifest,
         _patch,
         _bundle,
         _workspace,
         _now,
         %{artifact_store: nil}
       ),
       do: {:ok, nil}

  defp persist_result_artifact(manifest, patch, bundle, workspace, now, state) do
    ArtifactStore.put(
      %{manifest: ResultManifest.to_map(manifest), patch: patch, bundle: bundle},
      server: state.artifact_store,
      session_id: workspace.owner_session_id,
      round_id: workspace.round_id,
      media_type: "application/vnd.twelvgaige.workspace-result+erlang",
      retention_class: :raw,
      now: now
    )
  end

  defp append_artifact_ref(refs, nil), do: refs
  defp append_artifact_ref(refs, ref), do: Enum.uniq(refs ++ [ref])

  defp quiesceable(%{state: state}) when state in [:ready, :leased, :running], do: :ok
  defp quiesceable(%{state: :quiesced}), do: :ok
  defp quiesceable(_workspace), do: {:error, :workspace_not_quiesceable}

  defp finalizable(%{state: state}) when state in [:ready, :quiesced], do: :ok
  defp finalizable(_workspace), do: {:error, :workspace_writer_not_quiesced}

  defp validate_quiescence(evidence) when is_map(evidence) do
    stopped? = Map.get(evidence, :runtime_stopped, Map.get(evidence, "runtime_stopped"))
    stopped_at = Map.get(evidence, :stopped_at, Map.get(evidence, "stopped_at"))
    runtime_identity = Map.get(evidence, :runtime_identity, Map.get(evidence, "runtime_identity"))

    if stopped? == true and match?(%DateTime{}, stopped_at) and
         is_binary(runtime_identity) and runtime_identity != "" do
      {:ok,
       %{
         runtime_stopped: true,
         stopped_at: stopped_at,
         runtime_identity: runtime_identity
       }}
    else
      {:error, :workspace_quiescence_evidence_invalid}
    end
  end

  defp validate_quiescence(_evidence), do: {:error, :workspace_quiescence_evidence_invalid}

  defp persist_operation(_operation, %{operations_store: nil}), do: :ok

  defp persist_operation(operation, state) do
    store_opts = [
      server: state.operations_store,
      retention_class: :security,
      now: operation.updated_at
    ]

    store_opts =
      if Operation.terminal?(operation),
        do: store_opts,
        else: Keyword.put(store_opts, :hold_until, @far_future)

    case {FaultMatrix.operation_lifecycle(operation), FaultMatrix.operation_boundary(operation)} do
      {nil, _boundary} ->
        OperationsStore.put(:workspace_operation, operation.request_id, operation, store_opts)

      {_lifecycle, nil} ->
        OperationsStore.put(:workspace_operation, operation.request_id, operation, store_opts)

      {lifecycle, boundary} ->
        FaultMatrix.around(
          fault_opts(state),
          lifecycle,
          boundary,
          operation_metadata(operation),
          fn ->
            OperationsStore.put(
              :workspace_operation,
              operation.request_id,
              operation,
              store_opts
            )
          end
        )
    end
  end

  defp recover_operations(%{operations_store: nil} = state), do: {:ok, state}

  defp recover_operations(state) do
    case OperationsStore.list(:workspace_operation, server: state.operations_store) do
      {:ok, records} ->
        Enum.reduce_while(records, {:ok, state}, fn record, {:ok, current} ->
          case record.value do
            %Operation{} = operation ->
              if Operation.valid?(operation) do
                operation = recover_operation(operation, current)

                case persist_operation(operation, current) do
                  :ok ->
                    {:cont, {:ok, put_in(current.operations[operation.request_id], operation)}}

                  {:error, reason} ->
                    {:halt, {:error, {:workspace_operation_recovery_persistence_failed, reason}}}
                end
              else
                {:halt, {:error, :workspace_operation_record_invalid}}
              end

            _invalid ->
              {:halt, {:error, :workspace_operation_record_invalid}}
          end
        end)

      {:error, reason} ->
        {:error, {:workspace_operation_recovery_store_failed, reason}}
    end
  end

  defp recover_operation(%Operation{} = operation, state) do
    cond do
      Operation.terminal?(operation) ->
        operation

      operation.kind == :create and
          not managed_path_exists?(state.root, operation.workspace_id) ->
        Operation.transition(operation, :failed, %{
          error: :workspace_create_interrupted_before_materialization
        })

      true ->
        Operation.transition(operation, :needs_reconciliation, %{
          error: :workspace_operation_interrupted
        })
    end
  end

  defp persist_workspace(_workspace, %{operations_store: nil}), do: :ok

  defp persist_workspace(workspace, state) do
    hold_until =
      if workspace.state in [:reviewable, :retained, :deleted], do: nil, else: @far_future

    store_opts = [
      server: state.operations_store,
      retention_class: :raw,
      now: workspace.finalized_at || workspace.created_at
    ]

    store_opts =
      if hold_until, do: Keyword.put(store_opts, :hold_until, hold_until), else: store_opts

    OperationsStore.put(:workspace_record, workspace.id, workspace, store_opts)
  end

  defp recover_workspaces(%{operations_store: nil} = state, _opts), do: {:ok, state}

  defp recover_workspaces(state, opts) do
    case OperationsStore.list(:workspace_record, server: state.operations_store) do
      {:ok, records} ->
        records
        |> Enum.reduce_while({:ok, %{}, %{}, %{}}, fn record,
                                                      {:ok, workspaces, leases, reservations} ->
          case recover_workspace(record.value, state, opts) do
            {:ok, workspace, lease?} ->
              leases =
                if lease? and workspace.owner_session_id,
                  do: Map.put(leases, workspace.id, workspace.owner_session_id),
                  else: leases

              reservations =
                case workspace.storage_reservation do
                  %{status: :reserved} = reservation
                  when workspace.state not in [:reviewable, :retained, :deleted] ->
                    Map.put(reservations, workspace.id, reservation)

                  _reservation ->
                    reservations
                end

              {:cont, {:ok, Map.put(workspaces, workspace.id, workspace), leases, reservations}}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, workspaces, leases, reservations} ->
            {:ok,
             %{
               state
               | workspaces: workspaces,
                 writer_leases: leases,
                 storage_reservations: reservations
             }}

          {:error, reason} ->
            {:error, {:workspace_recovery_failed, reason}}
        end

      {:error, reason} ->
        {:error, {:workspace_recovery_store_failed, reason}}
    end
  end

  defp recover_workspace(%Workspace{} = stored, state, opts) do
    workspace = migrate_workspace(stored, opts)
    {workspace, lease?} = reconcile_workspace(workspace, state, opts)

    case persist_workspace(workspace, state) do
      :ok -> {:ok, workspace, lease?}
      {:error, reason} -> {:error, {:workspace_recovery_persistence_failed, workspace.id, reason}}
    end
  end

  defp recover_workspace(_stored, _state, _opts),
    do: {:error, :workspace_record_invalid}

  defp migrate_workspace(%Workspace{} = stored, opts) do
    attrs = Map.from_struct(stored)

    baseline =
      Map.get(attrs, :workspace_baseline_commit) ||
        case SourceRead.resolve_commit(stored.path, "HEAD", opts) do
          {:ok, commit} -> commit
          {:error, _reason} -> stored.base_commit
        end

    attrs
    |> Map.put(:workspace_baseline_commit, baseline)
    |> Map.put(:schema_version, 2)
    |> Workspace.new()
  end

  defp reconcile_workspace(%Workspace{state: :deleted} = workspace, state, _opts) do
    case interrupted_operation(state, workspace.id) do
      nil ->
        {workspace, false}

      interrupted ->
        {%{
           workspace
           | state: :needs_reconciliation,
             quarantine_reason: {:workspace_operation_interrupted, interrupted.request_id},
             last_operation_id: interrupted.id,
             control_epoch: workspace.control_epoch + 1
         }, false}
    end
  end

  defp reconcile_workspace(workspace, state, opts) do
    reason = workspace_drift(workspace, state.root, opts)
    interrupted = interrupted_operation(state, workspace.id)

    cond do
      interrupted ->
        {%{
           workspace
           | state: :needs_reconciliation,
             quarantine_reason: {:workspace_operation_interrupted, interrupted.request_id},
             last_operation_id: interrupted.id,
             control_epoch: workspace.control_epoch + 1
         }, true}

      reason ->
        {%{
           workspace
           | state: :quarantined,
             quarantine_reason: reason,
             control_epoch: workspace.control_epoch + 1
         }, true}

      workspace.state in [:running, :leased, :stopping, :quiesced, :finalizing] ->
        {%{
           workspace
           | state: :quarantined,
             quarantine_reason: :workspace_restart_writer_unknown,
             control_epoch: workspace.control_epoch + 1
         }, true}

      workspace.state == :quarantined ->
        {workspace, not is_nil(workspace.owner_session_id)}

      true ->
        {workspace, false}
    end
  end

  defp interrupted_operation(state, workspace_id) do
    state.operations
    |> Map.values()
    |> Enum.filter(fn operation ->
      operation.workspace_id == workspace_id and operation.status == :needs_reconciliation
    end)
    |> Enum.max_by(
      & &1.updated_at,
      fn left, right -> DateTime.compare(left, right) != :lt end,
      fn -> nil end
    )
  end

  defp workspace_drift(workspace, root, opts) do
    cond do
      not within_root?(workspace.path, root) ->
        :workspace_path_outside_managed_root

      not File.dir?(workspace.path) ->
        :workspace_path_missing

      workspace.transport == :copy_snapshot ->
        expected = Path.join(workspace.path, ".git") |> Path.expand()

        case SourceRead.common_dir(workspace.path, opts) do
          {:ok, actual} ->
            if(same_file?(expected, actual), do: nil, else: :workspace_git_common_dir_drift)

          {:error, _reason} ->
            :workspace_git_unreadable
        end

      true ->
        nil
    end
  end

  defp within_root?(path, root) do
    relative = Path.relative_to(Path.expand(path), Path.expand(root))

    relative != ".." and not String.starts_with?(relative, "../") and
      Path.type(relative) != :absolute
  end

  defp same_file?(left, right) do
    with {:ok, left_stat} <- File.stat(left),
         {:ok, right_stat} <- File.stat(right) do
      left_stat.type == right_stat.type and left_stat.inode == right_stat.inode and
        left_stat.major_device == right_stat.major_device and
        left_stat.minor_device == right_stat.minor_device
    else
      _error -> false
    end
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

  defp create_transport(:copy_snapshot, repository, path, opts) do
    with {:ok, capture} <- SourceCapture.capture(repository, path, opts) do
      {:ok,
       %{
         base_commit: capture.manifest.base_commit,
         source_mode: capture.manifest.source_mode,
         source_manifest: capture.manifest,
         input_tree: capture.manifest.input_tree,
         workspace_baseline_commit: capture.workspace_baseline_commit
       }}
    end
  end

  defp create_transport(:bind_worktree, repository, path, opts) do
    with {:ok, commit} <-
           SourceRead.resolve_commit(repository, Keyword.get(opts, :base_ref, "HEAD"), opts),
         {:ok, authority} <- creation_registration_authority(repository, path, opts),
         :ok <- ManagedWorkspace.create_worktree(authority, path, commit, opts),
         {:ok, tree} <- SourceRead.resolve_tree(path, commit, opts) do
      {:ok,
       %{
         base_commit: commit,
         source_mode: :committed,
         source_manifest: nil,
         input_tree: tree,
         workspace_baseline_commit: commit
       }}
    end
  end

  defp managed_authority(workspace, opts, scope, state) do
    ManagedWorkspace.authorize(workspace,
      expected_epoch: Keyword.get(opts, :expected_epoch),
      lease: Keyword.get(opts, :request_id),
      operation_id: Keyword.get(opts, :operation_id),
      request_id: Keyword.get(opts, :request_id),
      audit_fun: git_audit_sink(state, opts),
      scope: scope
    )
  end

  defp creation_registration_authority(repository, path, opts) do
    operation_id = Keyword.get(opts, :creation_operation_id)

    ManagedWorkspace.authorize(
      %{
        id: Keyword.get(opts, :workspace_id),
        path: Path.expand(repository),
        control_epoch: 0
      },
      root: Path.expand(repository),
      target_path: Path.expand(path),
      expected_epoch: 0,
      lease: operation_id,
      operation_id: operation_id,
      request_id: Keyword.get(opts, :request_id),
      audit_fun: Keyword.get(opts, :git_audit_fun),
      scope: :review_registration
    )
  end

  defp git_audit_sink(state, opts) do
    case Keyword.get(opts, :git_audit_fun) do
      sink when is_function(sink, 1) ->
        sink

      _sink when is_nil(state.operations_store) ->
        fn _event -> :ok end

      _sink ->
        fn event ->
          OperationsStore.put(
            :workspace_git_mutation,
            event.event_id,
            event,
            server: state.operations_store,
            retention_class: :security,
            now: event.occurred_at
          )
        end
    end
  end

  defp persist_lifecycle_workspace(workspace, state, lifecycle, operation)
       when is_atom(lifecycle) do
    FaultMatrix.around(
      fault_opts(state),
      lifecycle,
      :workspace_record_persist,
      operation_metadata(operation),
      fn -> persist_workspace(workspace, state) end
    )
  end

  defp fault_opts(state, opts \\ []) do
    Keyword.put(opts, :fault_checkpoint_fun, state.fault_checkpoint_fun)
  end

  defp operation_metadata(operation) do
    %{
      operation_id: operation.id,
      request_id: operation.request_id,
      workspace_id: operation.workspace_id
    }
  end

  defp lifecycle_metadata(workspace, opts) do
    %{
      operation_id: Keyword.get(opts, :operation_id),
      request_id: Keyword.get(opts, :request_id),
      workspace_id: workspace.id
    }
  end

  defp bindable(%{state: :ready}, _session_id), do: :ok

  defp bindable(%{state: :running}, _session_id), do: :ok

  defp bindable(_workspace, _session_id), do: {:error, :workspace_not_bindable}

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

  defp map_value(map, key, default \\ nil)

  defp map_value(map, key, default) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp map_value(_value, _key, default), do: default
end
