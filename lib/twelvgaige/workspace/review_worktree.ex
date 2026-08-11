defmodule Twelvgaige.Workspace.ReviewWorktree do
  @moduledoc "Checks and creates isolated detached review worktrees."

  alias Twelvgaige.Lifecycle.FaultMatrix
  alias Twelvgaige.Workspace.Git.ManagedWorkspace
  alias Twelvgaige.Workspace.Git.SourceRead

  def check(workspace, result, opts \\ []) do
    repository = workspace.repository
    manifest = result.manifest
    base = field(manifest, :source_base_commit)

    with true <- File.dir?(repository),
         {:ok, head} <- SourceRead.resolve_commit(repository, "HEAD", opts),
         true <- head == base,
         {:ok, status} <- SourceRead.status(repository, opts),
         true <- status == "",
         :ok <- SourceRead.check_patch(repository, result.patch, opts) do
      {:ok,
       %{
         workspace_id: workspace.id,
         repository: repository,
         base_commit: base,
         result_tree: field(manifest, :result_tree),
         patch_digest: field(manifest, :patch_digest),
         target: "review-worktree",
         dry_run: true,
         applicable: true,
         expected_epoch: workspace.control_epoch
       }}
    else
      false -> {:error, :workspace_apply_target_drifted_or_dirty}
      {:error, _reason} = error -> error
    end
  end

  def create(workspace, result, destination, opts \\ []) do
    with {:ok, report} <- check(workspace, result, opts),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.chmod(Path.dirname(destination), 0o700),
         {:ok, registration} <- registration_authority(workspace, destination, opts),
         :ok <-
           FaultMatrix.around(
             opts,
             :review_apply,
             :review_registration,
             lifecycle_metadata(workspace, opts),
             fn ->
               ManagedWorkspace.create_worktree(
                 registration,
                 destination,
                 report.base_commit,
                 opts
               )
             end
           ),
         {:ok, review} <- review_authority(workspace, destination, opts),
         :ok <-
           FaultMatrix.around(
             opts,
             :review_apply,
             :review_patch_apply,
             lifecycle_metadata(workspace, opts),
             fn -> ManagedWorkspace.apply_patch(review, result.patch, opts) end
           ),
         {:ok, capture} <-
           FaultMatrix.around(
             opts,
             :review_apply,
             :review_result_verify,
             lifecycle_metadata(workspace, opts),
             fn ->
               ManagedWorkspace.capture_result(
                 review,
                 report.base_commit,
                 Keyword.put(opts, :artifact_base, report.base_commit)
               )
             end
           ),
         true <- capture.result_tree == report.result_tree do
      {:ok,
       report
       |> Map.merge(%{
         dry_run: false,
         path: Path.expand(destination),
         common_git_directory_shared: true,
         verified_result_tree: capture.result_tree
       })}
    else
      false -> {:error, :workspace_apply_result_tree_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp registration_authority(workspace, destination, opts) do
    ManagedWorkspace.authorize(workspace,
      root: workspace.repository,
      target_path: Path.expand(destination),
      expected_epoch: Keyword.get(opts, :expected_epoch),
      lease: Keyword.get(opts, :request_id),
      operation_id: Keyword.get(opts, :operation_id),
      request_id: Keyword.get(opts, :request_id),
      audit_fun: Keyword.get(opts, :git_audit_fun),
      scope: :review_registration
    )
  end

  defp review_authority(workspace, destination, opts) do
    ManagedWorkspace.authorize(workspace,
      root: Path.expand(destination),
      expected_epoch: Keyword.get(opts, :expected_epoch),
      lease: Keyword.get(opts, :request_id),
      operation_id: Keyword.get(opts, :operation_id),
      request_id: Keyword.get(opts, :request_id),
      audit_fun: Keyword.get(opts, :git_audit_fun),
      scope: :review_worktree
    )
  end

  defp lifecycle_metadata(workspace, opts) do
    %{
      operation_id: Keyword.get(opts, :operation_id),
      request_id: Keyword.get(opts, :request_id),
      workspace_id: workspace.id
    }
  end

  defp field(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
