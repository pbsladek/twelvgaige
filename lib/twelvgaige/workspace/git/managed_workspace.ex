defmodule Twelvgaige.Workspace.Git.ManagedWorkspace do
  @moduledoc """
  Capability-scoped Git access for registered mutation targets.

  Every operation takes an opaque authority minted from a durable workspace
  record and operation lease. The authority is bound to the canonical root,
  filesystem identity, workspace identity, control epoch, and operation.
  """

  alias Twelvgaige.Workspace.Git
  alias Twelvgaige.Workspace.Git.MutationAudit

  @scopes [:execution, :review_worktree, :review_registration, :direct_apply]

  defmodule Authority do
    @moduledoc false

    @enforce_keys [
      :workspace_id,
      :root,
      :path_identity,
      :scope,
      :lease,
      :operation_id,
      :control_epoch,
      :audit,
      :seal
    ]
    defstruct [
      :workspace_id,
      :root,
      :path_identity,
      :scope,
      :lease,
      :operation_id,
      :request_id,
      :control_epoch,
      :target_path,
      :audit,
      :seal
    ]
  end

  @opaque t :: %Authority{}

  @spec authorize(map(), keyword()) :: {:ok, t()} | {:error, term()}
  def authorize(workspace, opts) when is_map(workspace) and is_list(opts) do
    root = Keyword.get(opts, :root, value(workspace, :path))
    workspace_id = value(workspace, :id, value(workspace, :workspace_id))
    control_epoch = value(workspace, :control_epoch)
    expected_epoch = Keyword.get(opts, :expected_epoch)
    scope = Keyword.get(opts, :scope, :execution)
    lease = Keyword.get(opts, :lease)
    operation_id = Keyword.get(opts, :operation_id)
    request_id = Keyword.get(opts, :request_id)
    target_path = Keyword.get(opts, :target_path)
    audit_fun = Keyword.get(opts, :audit_fun)

    with :ok <- present(workspace_id, :git_workspace_identity_required),
         :ok <- canonical_root(root),
         :ok <- scope(scope),
         :ok <- present(lease, :git_workspace_lease_required),
         :ok <- present(operation_id, :git_workspace_operation_required),
         :ok <- epoch(control_epoch, expected_epoch),
         :ok <- canonical_target(target_path),
         {:ok, path_identity} <- path_identity(root),
         {:ok, audit} <-
           MutationAudit.new(
             %{
               workspace_id: workspace_id,
               operation_id: operation_id,
               request_id: request_id,
               lease: lease,
               control_epoch: control_epoch,
               scope: scope
             },
             audit_fun
           ) do
      {:ok,
       %Authority{
         workspace_id: workspace_id,
         root: root,
         path_identity: path_identity,
         scope: scope,
         lease: lease,
         operation_id: operation_id,
         request_id: request_id,
         control_epoch: control_epoch,
         target_path: target_path,
         audit: audit,
         seal: make_ref()
       }}
    end
  end

  def authorize(_workspace, _opts), do: {:error, :git_workspace_authority_invalid}

  @spec validate(t()) :: :ok | {:error, term()}
  def validate(%Authority{seal: seal} = authority) when is_reference(seal) do
    with :ok <- canonical_root(authority.root),
         :ok <- scope(authority.scope),
         :ok <- present(authority.workspace_id, :git_workspace_identity_required),
         :ok <- present(authority.lease, :git_workspace_lease_required),
         :ok <- present(authority.operation_id, :git_workspace_operation_required),
         {:ok, identity} <- path_identity(authority.root),
         true <- identity == authority.path_identity do
      :ok
    else
      false -> {:error, :git_workspace_path_identity_changed}
      {:error, _reason} = error -> error
    end
  end

  def validate(_authority), do: {:error, :git_workspace_authority_invalid}

  @spec identity(t()) :: {:ok, map()} | {:error, term()}
  def identity(%Authority{} = authority) do
    with :ok <- validate(authority) do
      {:ok,
       %{
         workspace_id: authority.workspace_id,
         scope: authority.scope,
         operation_id: authority.operation_id,
         request_id: authority.request_id,
         control_epoch: authority.control_epoch,
         path_identity: authority.path_identity
       }}
    end
  end

  def identity(_authority), do: {:error, :git_workspace_authority_invalid}

  @spec root(t()) :: {:ok, Path.t()} | {:error, term()}
  def root(%Authority{} = authority) do
    with :ok <- validate(authority), do: {:ok, authority.root}
  end

  def root(_authority), do: {:error, :git_workspace_authority_invalid}

  @spec resolve_commit(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_commit(authority, ref, opts \\ []),
    do: read(authority, &Git.resolve_commit(&1, ref, git_opts(authority, opts)))

  @spec resolve_tree(t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_tree(authority, ref, opts \\ []),
    do: read(authority, &Git.resolve_tree(&1, ref, git_opts(authority, opts)))

  @spec common_dir(t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def common_dir(authority, opts \\ []),
    do: read(authority, &Git.common_dir(&1, git_opts(authority, opts)))

  @spec index_path(t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def index_path(authority, opts \\ []),
    do: read(authority, &Git.index_path(&1, git_opts(authority, opts)))

  @spec status(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def status(authority, opts \\ []),
    do: read(authority, &Git.status(&1, git_opts(authority, opts)))

  @spec diff(t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def diff(authority, opts \\ []),
    do: read(authority, &Git.diff(&1, git_opts(authority, opts)))

  @spec check_patch(t(), binary(), keyword()) :: :ok | {:error, term()}
  def check_patch(authority, patch, opts \\ []),
    do: read(authority, &Git.check_patch(&1, patch, git_opts(authority, opts)))

  @spec apply_patch(t(), binary(), keyword()) :: :ok | {:error, term()}
  def apply_patch(authority, patch, opts \\ []) do
    mutate(authority, [:execution, :review_worktree, :direct_apply], fn root ->
      Git.apply_private_patch(root, patch, git_opts(authority, opts))
    end)
  end

  @spec create_input_baseline(t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_input_baseline(authority, source_base, input_tree, source_token, opts \\ []) do
    mutate(authority, [:execution], fn root ->
      Git.create_input_baseline(
        root,
        source_base,
        input_tree,
        source_token,
        git_opts(authority, opts)
      )
    end)
  end

  @spec capture_result(t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def capture_result(authority, workspace_baseline, opts \\ []) do
    mutate(authority, [:execution, :review_worktree, :direct_apply], fn root ->
      Git.capture_result(root, workspace_baseline, git_opts(authority, opts))
    end)
  end

  @spec capture_commit_bundle(t(), String.t(), keyword()) ::
          {:ok, binary() | nil} | {:error, term()}
  def capture_commit_bundle(authority, workspace_baseline, opts \\ []) do
    mutate(authority, [:execution], fn root ->
      Git.capture_commit_bundle(root, workspace_baseline, git_opts(authority, opts))
    end)
  end

  @spec create_worktree(t(), Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_worktree(authority, destination, commit, opts \\ []) do
    with :ok <- target(authority, destination) do
      mutate(authority, [:review_registration], fn repository ->
        Git.create_worktree(repository, destination, commit, git_opts(authority, opts))
      end)
    end
  end

  @spec remove_worktree(t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def remove_worktree(authority, destination, opts \\ []) do
    with :ok <- target(authority, destination) do
      mutate(authority, [:review_registration], fn repository ->
        Git.remove_worktree(repository, destination, git_opts(authority, opts))
      end)
    end
  end

  @spec remove_verified_worktree(t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def remove_verified_worktree(authority, destination, opts \\ []) do
    with :ok <- target(authority, destination) do
      mutate(authority, [:review_registration], fn repository ->
        Git.remove_verified_worktree(
          repository,
          destination,
          git_opts(authority, opts)
        )
      end)
    end
  end

  defp read(authority, operation) do
    with :ok <- validate(authority), do: operation.(authority.root)
  end

  defp mutate(authority, scopes, operation) do
    with :ok <- validate(authority),
         true <- authority.scope in scopes do
      operation.(authority.root)
    else
      false -> {:error, :git_workspace_scope_denied}
      {:error, _reason} = error -> error
    end
  end

  defp git_opts(%Authority{} = authority, opts) do
    opts
    |> Keyword.put(:require_mutation_audit?, true)
    |> Keyword.put(:git_mutation_audit, authority.audit)
  end

  defp target(%Authority{} = authority, destination) do
    destination = Path.expand(destination)

    cond do
      authority.scope != :review_registration ->
        {:error, :git_workspace_scope_denied}

      not is_binary(authority.target_path) ->
        {:error, :git_workspace_target_required}

      Path.expand(authority.target_path) != destination ->
        {:error, :git_workspace_target_mismatch}

      true ->
        :ok
    end
  end

  defp target(_authority, _destination), do: {:error, :git_workspace_authority_invalid}

  defp path_identity(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory} = stat} ->
        {:ok, %{device: {stat.major_device, stat.minor_device}, inode: stat.inode}}

      {:ok, %{type: type}} ->
        {:error, {:git_workspace_root_type_invalid, type}}

      {:error, reason} ->
        {:error, {:git_workspace_root_unavailable, reason}}
    end
  end

  defp canonical_root(root) when is_binary(root) do
    if Path.type(root) == :absolute and Path.expand(root) == root,
      do: :ok,
      else: {:error, :git_workspace_root_not_canonical}
  end

  defp canonical_root(_root), do: {:error, :git_workspace_root_required}

  defp canonical_target(nil), do: :ok

  defp canonical_target(target) when is_binary(target) do
    if Path.type(target) == :absolute and Path.expand(target) == target,
      do: :ok,
      else: {:error, :git_workspace_target_not_canonical}
  end

  defp canonical_target(_target), do: {:error, :git_workspace_target_not_canonical}

  defp scope(scope) when scope in @scopes, do: :ok
  defp scope(_scope), do: {:error, :git_workspace_scope_invalid}

  defp epoch(epoch, epoch) when is_integer(epoch) and epoch >= 0, do: :ok

  defp epoch(epoch, expected) when is_integer(epoch) and is_integer(expected),
    do: {:error, :git_workspace_control_epoch_conflict}

  defp epoch(_epoch, _expected), do: {:error, :git_workspace_control_epoch_required}

  defp present(value, _error) when is_binary(value) and value != "", do: :ok
  defp present(_value, error), do: {:error, error}

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
