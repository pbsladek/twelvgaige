defmodule Twelvgaige.Workspace.Git.SourceRead do
  @moduledoc """
  Capability-scoped Git access for developer-owned source repositories.

  This interface exposes inspection and copy operations only. It deliberately
  has no operation that can update the source worktree, index, refs, config, or
  worktree registrations.
  """

  alias Twelvgaige.Workspace.Git
  alias Twelvgaige.Workspace.Git.MutationAudit

  @type opts :: keyword()

  @spec version(opts()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer()}} | {:error, term()}
  def version(opts \\ []), do: Git.version(opts)

  @spec read(Path.t(), [String.t()], opts()) :: {:ok, binary()} | {:error, term()}
  def read(repository, args, opts \\ []), do: Git.source_read(canonical(repository), args, opts)

  @spec resolve_commit(Path.t(), String.t(), opts()) :: {:ok, String.t()} | {:error, term()}
  def resolve_commit(repository, ref, opts \\ []),
    do: Git.resolve_commit(canonical(repository), ref, opts)

  @spec resolve_tree(Path.t(), String.t(), opts()) :: {:ok, String.t()} | {:error, term()}
  def resolve_tree(repository, ref, opts \\ []),
    do: Git.resolve_tree(canonical(repository), ref, opts)

  @spec common_dir(Path.t(), opts()) :: {:ok, Path.t()} | {:error, term()}
  def common_dir(repository, opts \\ []), do: Git.common_dir(canonical(repository), opts)

  @spec index_path(Path.t(), opts()) :: {:ok, Path.t()} | {:error, term()}
  def index_path(repository, opts \\ []), do: Git.index_path(canonical(repository), opts)

  @spec diff(Path.t(), opts()) :: {:ok, binary()} | {:error, term()}
  def diff(repository, opts \\ []), do: Git.diff(canonical(repository), opts)

  @spec status(Path.t(), opts()) :: {:ok, binary()} | {:error, term()}
  def status(repository, opts \\ []), do: Git.status(canonical(repository), opts)

  @spec staged_patch(Path.t(), String.t(), opts()) :: {:ok, binary()} | {:error, term()}
  def staged_patch(repository, base_commit, opts \\ []),
    do: Git.staged_patch(canonical(repository), base_commit, opts)

  @spec check_patch(Path.t(), binary(), opts()) :: :ok | {:error, term()}
  def check_patch(repository, patch, opts \\ []),
    do: Git.check_patch(canonical(repository), patch, opts)

  @doc "Captures a worktree result through an isolated temporary object directory."
  @spec capture_worktree_result(Path.t(), String.t(), opts()) ::
          {:ok, map()} | {:error, term()}
  def capture_worktree_result(repository, workspace_baseline, opts \\ []) do
    opts = Keyword.put(opts, :persist_objects?, false)
    Git.capture_result(canonical(repository), workspace_baseline, opts)
  end

  @doc "Copies source into a registered destination without mutating source Git state."
  @spec copy_snapshot(Path.t(), Path.t(), String.t(), opts()) :: :ok | {:error, term()}
  def copy_snapshot(repository, destination, commit, opts \\ []) do
    with :ok <- creation_identity(opts),
         {:ok, audit} <- creation_audit(opts) do
      opts =
        opts
        |> Keyword.put(:require_mutation_audit?, true)
        |> Keyword.put(:git_mutation_audit, audit)

      Git.create_snapshot(
        canonical(repository),
        canonical(destination),
        commit,
        [],
        opts
      )
    end
  end

  defp creation_audit(opts) do
    operation_id = Keyword.get(opts, :creation_operation_id)

    MutationAudit.new(
      %{
        workspace_id: Keyword.get(opts, :workspace_id),
        operation_id: operation_id,
        request_id: Keyword.get(opts, :request_id),
        lease: operation_id,
        control_epoch: 0,
        scope: :snapshot_creation
      },
      Keyword.get(opts, :git_audit_fun)
    )
  end

  defp creation_identity(opts) do
    workspace_id = Keyword.get(opts, :workspace_id)
    operation_id = Keyword.get(opts, :creation_operation_id)

    if present?(workspace_id) and present?(operation_id),
      do: :ok,
      else: {:error, :git_snapshot_registration_required}
  end

  defp canonical(path), do: Path.expand(path)
  defp present?(value), do: is_binary(value) and value != ""
end
