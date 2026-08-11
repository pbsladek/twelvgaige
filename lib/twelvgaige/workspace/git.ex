defmodule Twelvgaige.Workspace.Git do
  @moduledoc "Typed, policy-neutral Git operations for source and managed workspaces."

  import Bitwise

  alias Twelvgaige.Tool.CommandRunner
  alias Twelvgaige.Workspace.Canonical
  alias Twelvgaige.Workspace.Git.MutationAudit

  @default_timeout_ms 30_000
  @default_max_output_bytes 16 * 1_024 * 1_024
  @default_max_result_file_bytes 100 * 1_024 * 1_024
  @default_max_result_bytes 2 * 1_024 * 1_024 * 1_024
  @default_max_result_files 100_000
  @default_max_bundle_bytes 512 * 1_024 * 1_024
  @object_batch_size 128
  @index_batch_size 128
  @source_read_commands ~w(rev-parse status symbolic-ref config ls-files ls-tree show worktree diff)
  @read_command_classes %{
    "rev-parse" => :rev_parse,
    "status" => :status,
    "symbolic-ref" => :symbolic_ref,
    "ls-files" => :ls_files,
    "ls-tree" => :ls_tree,
    "show" => :show,
    "diff" => :diff,
    "merge-base" => :merge_base,
    "cat-file" => :cat_file,
    "rev-list" => :rev_list
  }
  @mutation_command_classes %{
    "clone" => :clone,
    "checkout" => :checkout,
    "commit-tree" => :commit_tree,
    "update-ref" => :update_ref,
    "reset" => :reset,
    "read-tree" => :read_tree,
    "write-tree" => :write_tree,
    "update-index" => :update_index
  }

  @spec version(keyword()) ::
          {:ok, {non_neg_integer(), non_neg_integer(), non_neg_integer()}} | {:error, term()}
  def version(opts \\ []) do
    with {:ok, output} <- run(["--version"], opts),
         [major, minor, patch | _rest] <-
           Regex.run(~r/^git version (\d+)\.(\d+)\.(\d+)/, String.trim(output),
             capture: :all_but_first
           ) do
      {:ok, {String.to_integer(major), String.to_integer(minor), String.to_integer(patch)}}
    else
      nil -> {:error, :git_version_invalid}
      {:error, _reason} = error -> error
      _invalid -> {:error, :git_version_invalid}
    end
  end

  @doc "Runs one allowlisted, non-mutating Git source operation in the neutral environment."
  @spec source_read(Path.t(), [String.t()], keyword()) :: {:ok, binary()} | {:error, term()}
  def source_read(repository, args, opts \\ [])

  def source_read(repository, [command | _rest] = args, opts)
      when command in @source_read_commands do
    if source_read_args?(args),
      do: run(["-C", repository | args], opts),
      else: {:error, :git_source_read_operation_denied}
  end

  def source_read(_repository, _args, _opts), do: {:error, :git_source_read_operation_denied}

  @spec resolve_commit(Path.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_commit(repository, ref, opts \\ []) do
    case run(["-C", repository, "rev-parse", "--verify", "#{ref}^{commit}"], opts) do
      {:ok, output} -> {:ok, trim_line(output)}
      {:error, reason} -> {:error, {:git_ref_unresolved, reason}}
    end
  end

  @spec resolve_tree(Path.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def resolve_tree(repository, ref, opts \\ []) do
    case run(["-C", repository, "rev-parse", "--verify", "#{ref}^{tree}"], opts) do
      {:ok, output} -> {:ok, trim_line(output)}
      {:error, reason} -> {:error, {:git_tree_unresolved, reason}}
    end
  end

  @spec common_dir(Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def common_dir(repository, opts \\ []) do
    case run(["-C", repository, "rev-parse", "--path-format=absolute", "--git-common-dir"], opts) do
      {:ok, output} -> {:ok, output |> trim_line() |> Path.expand(repository)}
      {:error, reason} -> {:error, {:git_common_dir_unresolved, reason}}
    end
  end

  @spec index_path(Path.t(), keyword()) :: {:ok, Path.t()} | {:error, term()}
  def index_path(repository, opts \\ []) do
    case source_read(
           repository,
           ["rev-parse", "--path-format=absolute", "--git-path", "index"],
           opts
         ) do
      {:ok, output} -> {:ok, output |> trim_line() |> Path.expand(repository)}
      {:error, reason} -> {:error, {:git_index_path_unresolved, reason}}
    end
  end

  @spec create_worktree(Path.t(), Path.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def create_worktree(repository, destination, commit, opts \\ []) do
    with :ok <- ensure_absent(destination),
         {:ok, _output} <-
           run(["-C", repository, "worktree", "add", "--detach", destination, commit], opts) do
      :ok
    end
  end

  @spec remove_worktree(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def remove_worktree(repository, destination, opts \\ []) do
    case run(["-C", repository, "worktree", "remove", destination], opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Removes a worktree only after its tree was independently verified by the caller."
  @spec remove_verified_worktree(Path.t(), Path.t(), keyword()) :: :ok | {:error, term()}
  def remove_verified_worktree(repository, destination, opts \\ []) do
    case run(["-C", repository, "worktree", "remove", "--force", destination], opts) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Creates a private committed-source snapshot with no shared object storage."
  @spec create_snapshot(Path.t(), Path.t(), String.t(), [String.t()], keyword()) ::
          :ok | {:error, term()}
  def create_snapshot(repository, destination, commit, _allowed_paths, opts \\ []) do
    template = temporary_path(Path.dirname(destination), ".git-template")

    result =
      with :ok <- ensure_absent(destination),
           :ok <- File.mkdir(template),
           :ok <- File.chmod(template, 0o700),
           {:ok, _output} <-
             run(
               [
                 "clone",
                 "--quiet",
                 "--no-checkout",
                 "--no-local",
                 "--no-hardlinks",
                 "--no-tags",
                 "--template=#{template}",
                 repository,
                 destination
               ],
               Keyword.put(opts, :timeout_ms, Keyword.get(opts, :snapshot_timeout_ms, 120_000))
             ),
           {:ok, _output} <-
             run(["-C", destination, "checkout", "--quiet", "--detach", commit], opts),
           :ok <- sanitize_snapshot(destination, opts),
           :ok <- protect_tree(destination) do
        :ok
      end

    _ = File.rm_rf(template)

    if match?({:error, _reason}, result), do: File.rm_rf(destination)
    result
  end

  @spec diff(Path.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def diff(path, opts \\ []),
    do: run(["-C", path, "diff", "--binary", "--no-ext-diff", "--no-textconv", "HEAD"], opts)

  @spec status(Path.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def status(path, opts \\ []),
    do: run(["-C", path, "status", "--porcelain=v2", "-z", "--untracked-files=all"], opts)

  @spec staged_patch(Path.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, term()}
  def staged_patch(repository, base_commit, opts \\ []) do
    source_read(
      repository,
      [
        "diff",
        "--cached",
        "--binary",
        "--full-index",
        "--no-ext-diff",
        "--no-textconv",
        base_commit
      ],
      Keyword.put(
        opts,
        :max_output_bytes,
        Keyword.get(opts, :max_overlay_bytes, 256 * 1_024 * 1_024)
      )
    )
  end

  @spec apply_private_patch(Path.t(), binary(), keyword()) :: :ok | {:error, term()}
  def apply_private_patch(workspace, patch, opts \\ [])

  def apply_private_patch(_workspace, "", _opts), do: :ok

  def apply_private_patch(workspace, patch, opts) when is_binary(patch) do
    with {:ok, temporary} <- create_capture_dir(opts) do
      patch_path = Path.join(temporary, "source-overlay.patch")

      result =
        with :ok <- File.write(patch_path, patch, [:binary]),
             :ok <- File.chmod(patch_path, 0o600),
             {:ok, _output} <-
               run(
                 [
                   "-C",
                   workspace,
                   "apply",
                   "--index",
                   "--binary",
                   "--whitespace=nowarn",
                   patch_path
                 ],
                 opts
               ) do
          :ok
        end

      _ = File.rm_rf(temporary)
      result
    end
  end

  @doc "Checks patch applicability without changing the worktree or index."
  @spec check_patch(Path.t(), binary(), keyword()) :: :ok | {:error, term()}
  def check_patch(_repository, "", _opts), do: :ok

  def check_patch(repository, patch, opts) when is_binary(patch) do
    temporary = temporary_path(System.tmp_dir!(), "twelvgaige-apply-check")
    patch_path = Path.join(temporary, "result.patch")

    result =
      with :ok <- File.mkdir(temporary),
           :ok <- File.chmod(temporary, 0o700),
           :ok <- File.write(patch_path, patch, [:binary, :exclusive]),
           :ok <- File.chmod(patch_path, 0o600),
           {:ok, _output} <-
             run(
               [
                 "-C",
                 repository,
                 "-c",
                 "core.hooksPath=/dev/null",
                 "apply",
                 "--check",
                 "--binary",
                 "--whitespace=nowarn",
                 patch_path
               ],
               opts
             ) do
        :ok
      end

    _ = File.rm_rf(temporary)
    result
  end

  @spec create_input_baseline(Path.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_input_baseline(workspace, source_base, input_tree, source_token, opts \\ []) do
    with {:ok, base_tree} <- resolve_tree(workspace, source_base, opts) do
      if base_tree == input_tree do
        {:ok, source_base}
      else
        env = [
          {"GIT_AUTHOR_NAME", "Twelvgaige Source Capture"},
          {"GIT_AUTHOR_EMAIL", "source@localhost"},
          {"GIT_AUTHOR_DATE", "2000-01-01T00:00:00Z"},
          {"GIT_COMMITTER_NAME", "Twelvgaige Source Capture"},
          {"GIT_COMMITTER_EMAIL", "source@localhost"},
          {"GIT_COMMITTER_DATE", "2000-01-01T00:00:00Z"}
        ]

        commit_opts = Keyword.update(opts, :git_env, env, &(env ++ &1))

        with {:ok, output} <-
               run(
                 [
                   "-C",
                   workspace,
                   "commit-tree",
                   input_tree,
                   "-p",
                   source_base,
                   "-m",
                   "Twelvgaige input #{source_token}"
                 ],
                 commit_opts
               ),
             commit <- trim_line(output),
             {:ok, _output} <-
               run(
                 ["-C", workspace, "update-ref", "--no-deref", "HEAD", commit, source_base],
                 opts
               ),
             {:ok, _output} <-
               run(["-C", workspace, "reset", "--mixed", "--quiet", commit], opts) do
          {:ok, commit}
        end
      end
    end
  end

  @doc "Builds and verifies the complete result tree without invoking Git content filters."
  @spec capture_result(Path.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def capture_result(path, workspace_baseline, opts \\ []) do
    with {:ok, capture_dir} <- create_capture_dir(opts),
         {:ok, capture_opts} <- capture_object_opts(path, capture_dir, opts),
         result <- capture_result_in(path, workspace_baseline, capture_dir, capture_opts) do
      _ = File.rm_rf(capture_dir)
      result
    end
  end

  @doc "Captures a self-contained, verified bundle when HEAD contains commits after the baseline."
  @spec capture_commit_bundle(Path.t(), String.t(), keyword()) ::
          {:ok, binary() | nil} | {:error, term()}
  def capture_commit_bundle(path, workspace_baseline, opts \\ []) do
    with {:ok, head} <- resolve_commit(path, "HEAD", opts) do
      if head == workspace_baseline do
        {:ok, nil}
      else
        do_capture_commit_bundle(path, workspace_baseline, head, opts)
      end
    end
  end

  defp do_capture_commit_bundle(path, workspace_baseline, head, opts) do
    with {:ok, _output} <-
           run(["-C", path, "merge-base", "--is-ancestor", workspace_baseline, head], opts),
         {:ok, capture_dir} <- create_capture_dir(opts) do
      bundle_path = Path.join(capture_dir, "result.bundle")

      result =
        with {:ok, _output} <-
               run(
                 ["-C", path, "bundle", "create", bundle_path, "HEAD"],
                 Keyword.put(opts, :timeout_ms, Keyword.get(opts, :bundle_timeout_ms, 60_000))
               ),
             {:ok, %{type: :regular, size: bytes}} <- File.lstat(bundle_path),
             :ok <- bundle_size(bytes, opts),
             {:ok, _output} <-
               run(
                 ["-C", path, "bundle", "verify", bundle_path],
                 Keyword.put(opts, :max_output_bytes, 1_024 * 1_024)
               ),
             {:ok, bundle} <- File.read(bundle_path) do
          {:ok, bundle}
        else
          {:ok, _stat} -> {:error, :workspace_bundle_not_regular}
          {:error, reason} -> {:error, {:workspace_bundle_capture_failed, reason}}
        end

      _ = File.rm_rf(capture_dir)
      result
    else
      {:error, reason} -> {:error, {:workspace_bundle_capture_failed, reason}}
    end
  end

  defp bundle_size(bytes, opts) do
    if bytes <= Keyword.get(opts, :max_bundle_bytes, @default_max_bundle_bytes),
      do: :ok,
      else: {:error, :workspace_bundle_too_large}
  end

  defp capture_result_in(path, workspace_baseline, capture_dir, opts) do
    artifact_base = Keyword.get(opts, :artifact_base, workspace_baseline)
    index_path = Path.join(capture_dir, "result.index")
    index_opts = with_git_env(opts, "GIT_INDEX_FILE", index_path)

    with {:ok, _output} <- run(["-C", path, "read-tree", "--empty"], index_opts),
         {:ok, entries} <- scan_workspace(path, capture_dir, opts),
         :ok <- populate_index(path, entries, index_opts, capture_dir, opts),
         {:ok, result_tree_output} <- run(["-C", path, "write-tree"], index_opts),
         result_tree <- trim_line(result_tree_output),
         {:ok, workspace_baseline_tree} <- resolve_tree(path, workspace_baseline, opts),
         {:ok, changed_paths} <- changed_paths(path, artifact_base, result_tree, entries, opts),
         {:ok, patch} <- result_patch(path, artifact_base, result_tree, opts),
         :ok <- verify_patch(path, artifact_base, result_tree, patch, capture_dir, opts) do
      out_of_policy = out_of_policy(changed_paths, Keyword.get(opts, :allowed_paths, []))

      {:ok,
       %{
         result_tree: result_tree,
         patch: patch,
         changed_paths: changed_paths,
         out_of_policy: out_of_policy,
         no_change: workspace_baseline_tree == result_tree,
         integrity: :verified
       }}
    end
  end

  defp sanitize_snapshot(destination, opts) do
    hooks = Path.join([destination, ".git", "twelvgaige-hooks"])

    commands = [
      ["-C", destination, "remote", "remove", "origin"],
      ["-C", destination, "config", "user.name", "Twelvgaige Workspace"],
      ["-C", destination, "config", "user.email", "workspace@localhost"],
      ["-C", destination, "config", "core.hooksPath", hooks],
      ["-C", destination, "config", "credential.helper", ""],
      ["-C", destination, "config", "maintenance.auto", "false"],
      ["-C", destination, "config", "gc.auto", "0"],
      ["-C", destination, "config", "core.fsmonitor", "false"],
      ["-C", destination, "config", "core.autocrlf", "false"]
    ]

    with :ok <- File.mkdir_p(hooks),
         :ok <- File.chmod(hooks, 0o700) do
      Enum.reduce_while(commands, :ok, fn args, :ok ->
        case run(args, opts) do
          {:ok, _output} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:snapshot_git_config_failed, reason}}}
        end
      end)
    end
  end

  defp scan_workspace(path, capture_dir, opts) do
    limits = %{
      files: Keyword.get(opts, :max_result_files, @default_max_result_files),
      file_bytes: Keyword.get(opts, :max_result_file_bytes, @default_max_result_file_bytes),
      total_bytes: Keyword.get(opts, :max_result_bytes, @default_max_result_bytes)
    }

    case walk(path, "", capture_dir, [], 0, limits) do
      {:ok, entries, _bytes} -> {:ok, Enum.reverse(entries)}
      {:error, _reason} = error -> error
    end
  end

  defp walk(directory, relative, capture_dir, entries, total_bytes, limits) do
    with {:ok, names} <- File.ls(directory) do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, entries, total_bytes}, fn name, {:ok, acc, bytes} ->
        child_relative = if relative == "", do: name, else: Path.join(relative, name)
        child = Path.join(directory, name)

        cond do
          relative == "" and name == ".git" ->
            {:cont, {:ok, acc, bytes}}

          child == capture_dir ->
            {:cont, {:ok, acc, bytes}}

          true ->
            case scan_entry(child, child_relative, capture_dir, acc, bytes, limits) do
              {:ok, next_acc, next_bytes} -> {:cont, {:ok, next_acc, next_bytes}}
              {:error, reason} -> {:halt, {:error, reason}}
            end
        end
      end)
    end
  end

  defp scan_entry(path, relative, capture_dir, entries, total_bytes, limits) do
    with {:ok, stat} <- File.lstat(path) do
      case stat.type do
        :directory ->
          if Path.basename(path) == ".git",
            do: {:error, {:workspace_nested_git_repository, relative}},
            else: walk(path, relative, capture_dir, entries, total_bytes, limits)

        :regular ->
          add_entry(path, relative, stat, File.read(path), entries, total_bytes, limits)

        :symlink ->
          add_entry(path, relative, stat, File.read_link(path), entries, total_bytes, limits)

        type ->
          {:error, {:workspace_special_file_unsupported, relative, type}}
      end
    end
  end

  defp add_entry(path, relative, stat, content_result, entries, total_bytes, limits) do
    with {:ok, content} <- content_result,
         :ok <- within_file_limit(byte_size(content), limits),
         :ok <- within_total_limit(total_bytes + byte_size(content), limits),
         :ok <- within_file_count(length(entries) + 1, limits),
         {:ok, digest} <- Canonical.digest_bytes("workspace-file", 1, content) do
      mode = entry_mode(stat)

      {:ok,
       [
         %{
           path: relative,
           absolute_path: path,
           mode: mode,
           bytes: byte_size(content),
           digest: digest,
           content: if(stat.type == :symlink, do: content, else: nil)
         }
         | entries
       ], total_bytes + byte_size(content)}
    end
  end

  defp populate_index(path, entries, index_opts, capture_dir, opts) do
    with {:ok, hashed_entries} <- hash_entries(path, entries, capture_dir, opts) do
      hashed_entries
      |> Enum.chunk_every(@index_batch_size)
      |> Enum.reduce_while(:ok, fn batch, :ok ->
        cache_entries =
          Enum.flat_map(batch, fn {entry, oid} ->
            ["--cacheinfo", "#{entry.mode},#{oid},#{entry.path}"]
          end)

        case run(["-C", path, "update-index", "--add" | cache_entries], index_opts) do
          {:ok, _output} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:workspace_index_update_failed, reason}}}
        end
      end)
    end
  end

  defp hash_entries(path, entries, capture_dir, opts) do
    {regular, materialized} = Enum.split_with(entries, &is_nil(&1.content))

    with {:ok, regular_hashed} <- hash_regular_entries(path, regular, opts),
         {:ok, materialized_hashed} <-
           hash_materialized_entries(path, materialized, capture_dir, opts) do
      oids =
        Map.new(regular_hashed ++ materialized_hashed, fn {entry, oid} -> {entry.path, oid} end)

      if map_size(oids) == length(entries) do
        {:ok, Enum.map(entries, &{&1, Map.fetch!(oids, &1.path)})}
      else
        {:error, :workspace_blob_hash_count_mismatch}
      end
    end
  end

  defp hash_regular_entries(path, entries, opts) do
    entries
    |> Enum.chunk_every(@object_batch_size)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, acc} ->
      files = Enum.map(batch, & &1.absolute_path)

      case run(["-C", path, "hash-object", "-w", "--no-filters", "--" | files], opts) do
        {:ok, output} ->
          oids = output |> String.split("\n", trim: true)

          if length(oids) == length(batch) do
            next =
              Enum.reduce(Enum.zip(batch, oids), acc, fn hashed, items -> [hashed | items] end)

            {:cont, {:ok, next}}
          else
            {:halt, {:error, :workspace_blob_hash_count_mismatch}}
          end

        {:error, reason} ->
          {:halt, {:error, {:workspace_blob_hash_failed, reason}}}
      end
    end)
    |> case do
      {:ok, hashed} -> {:ok, Enum.reverse(hashed)}
      {:error, _reason} = error -> error
    end
  end

  defp hash_materialized_entries(path, entries, capture_dir, opts) do
    entries
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {entry, index}, {:ok, acc} ->
      case hash_materialized_entry(path, entry, capture_dir, index, opts) do
        {:ok, oid} -> {:cont, {:ok, [{entry, oid} | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, hashed} -> {:ok, Enum.reverse(hashed)}
      {:error, _reason} = error -> error
    end
  end

  defp hash_materialized_entry(path, %{content: content}, capture_dir, index, opts) do
    temporary = Path.join(capture_dir, "materialized-#{index}")

    with :ok <- File.write(temporary, content, [:binary]),
         :ok <- File.chmod(temporary, 0o600),
         {:ok, output} <-
           run(["-C", path, "hash-object", "-w", "--no-filters", "--", temporary], opts) do
      {:ok, trim_line(output)}
    else
      {:error, reason} -> {:error, {:workspace_blob_hash_failed, reason}}
    end
  end

  defp changed_paths(path, baseline, result_tree, entries, opts) do
    args = [
      "-C",
      path,
      "diff",
      "--name-status",
      "-z",
      "--find-renames",
      "--no-ext-diff",
      "--no-textconv",
      baseline,
      result_tree
    ]

    with {:ok, output} <- run(args, Keyword.put(opts, :binary, true)) do
      entry_map = Map.new(entries, &{&1.path, &1})
      parse_name_status(split_nul(output), entry_map)
    end
  end

  defp parse_name_status(tokens, entry_map), do: parse_name_status(tokens, entry_map, [])
  defp parse_name_status([], _entry_map, acc), do: {:ok, Enum.reverse(acc)}
  defp parse_name_status([""], _entry_map, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_name_status([<<kind, _score::binary>> = status, old_path, new_path | rest], map, acc)
       when kind in [?R, ?C] do
    entry = Map.get(map, new_path)

    change = %{
      "status" => status_name(kind),
      "similarity" => status,
      "old_path" => Canonical.path(old_path),
      "new_path" => Canonical.path(new_path),
      "new_mode" => entry && entry.mode,
      "bytes" => entry && entry.bytes,
      "digest" => entry && entry.digest
    }

    parse_name_status(rest, map, [change | acc])
  end

  defp parse_name_status([<<kind, _rest::binary>>, changed_path | rest], map, acc)
       when kind in [?A, ?M, ?D, ?T, ?U, ?X, ?B] do
    entry = Map.get(map, changed_path)

    change = %{
      "status" => status_name(kind),
      "path" => Canonical.path(changed_path),
      "new_mode" => entry && entry.mode,
      "bytes" => entry && entry.bytes,
      "digest" => entry && entry.digest
    }

    parse_name_status(rest, map, [change | acc])
  end

  defp parse_name_status(_tokens, _entry_map, _acc),
    do: {:error, :workspace_git_name_status_invalid}

  defp result_patch(path, baseline, result_tree, opts) do
    run(
      [
        "-C",
        path,
        "diff",
        "--binary",
        "--full-index",
        "--find-renames",
        "--no-ext-diff",
        "--no-textconv",
        baseline,
        result_tree
      ],
      opts
      |> Keyword.put(:binary, true)
      |> Keyword.put(:max_output_bytes, Keyword.get(opts, :max_patch_bytes, 256 * 1_024 * 1_024))
    )
  end

  defp verify_patch(path, baseline, result_tree, "", _capture_dir, _opts) do
    with {:ok, baseline_tree} <- resolve_tree(path, baseline) do
      if baseline_tree == result_tree,
        do: :ok,
        else: {:error, :workspace_empty_patch_tree_mismatch}
    end
  end

  defp verify_patch(path, baseline, result_tree, patch, capture_dir, opts) do
    patch_path = Path.join(capture_dir, "result.patch")
    verify_index = Path.join(capture_dir, "verify.index")
    verify_opts = with_git_env(opts, "GIT_INDEX_FILE", verify_index)

    with :ok <- File.write(patch_path, patch, [:binary]),
         :ok <- File.chmod(patch_path, 0o600),
         {:ok, _output} <- run(["-C", path, "read-tree", baseline], verify_opts),
         {:ok, _output} <-
           run(
             ["-C", path, "apply", "--cached", "--binary", "--whitespace=nowarn", patch_path],
             verify_opts
           ),
         {:ok, verified_output} <- run(["-C", path, "write-tree"], verify_opts) do
      if trim_line(verified_output) == result_tree,
        do: :ok,
        else: {:error, :workspace_patch_tree_mismatch}
    else
      {:error, reason} -> {:error, {:workspace_patch_verification_failed, reason}}
    end
  end

  defp out_of_policy(_changed_paths, []), do: []

  defp out_of_policy(changed_paths, allowed_paths) do
    allowed = Enum.map(allowed_paths, &normalize_allowed_path/1)

    Enum.reject(changed_paths, fn change ->
      change
      |> change_paths()
      |> Enum.all?(&path_allowed?(&1, allowed))
    end)
  end

  defp change_paths(%{"path" => path}), do: [decode_path!(path)]

  defp change_paths(%{"old_path" => old_path, "new_path" => new_path}),
    do: [decode_path!(old_path), decode_path!(new_path)]

  defp path_allowed?(path, allowed) do
    Enum.any?(allowed, fn prefix -> path == prefix or starts_with_path?(path, prefix) end)
  end

  defp starts_with_path?(path, prefix), do: String.starts_with?(path, prefix <> "/")

  defp normalize_allowed_path(path) do
    path
    |> String.trim()
    |> String.trim_leading("./")
    |> String.trim_trailing("/")
  end

  defp decode_path!(encoded) do
    {:ok, path} = Canonical.decode_path(encoded)
    path
  end

  defp status_name(?A), do: "added"
  defp status_name(?M), do: "modified"
  defp status_name(?D), do: "deleted"
  defp status_name(?R), do: "renamed"
  defp status_name(?C), do: "copied"
  defp status_name(?T), do: "type_changed"
  defp status_name(?U), do: "unmerged"
  defp status_name(?X), do: "unknown"
  defp status_name(?B), do: "broken"

  defp entry_mode(%File.Stat{type: :symlink}), do: "120000"

  defp entry_mode(%File.Stat{mode: mode}) do
    if (mode &&& 0o111) == 0, do: "100644", else: "100755"
  end

  defp within_file_limit(bytes, %{file_bytes: limit}) when bytes <= limit, do: :ok
  defp within_file_limit(_bytes, _limits), do: {:error, :workspace_result_file_too_large}
  defp within_total_limit(bytes, %{total_bytes: limit}) when bytes <= limit, do: :ok
  defp within_total_limit(_bytes, _limits), do: {:error, :workspace_result_too_large}
  defp within_file_count(count, %{files: limit}) when count <= limit, do: :ok
  defp within_file_count(_count, _limits), do: {:error, :workspace_result_too_many_files}

  defp capture_object_opts(path, capture_dir, opts) do
    if Keyword.get(opts, :persist_objects?, false),
      do: {:ok, opts},
      else: isolated_capture_object_opts(path, capture_dir, opts)
  end

  defp isolated_capture_object_opts(path, capture_dir, opts) do
    object_directory = Path.join(capture_dir, "objects")

    with {:ok, output} <-
           run(["-C", path, "rev-parse", "--path-format=absolute", "--git-path", "objects"], opts),
         alternate <- output |> trim_line() |> Path.expand(path),
         :ok <- File.mkdir(object_directory),
         :ok <- File.chmod(object_directory, 0o700) do
      capture_opts =
        opts
        |> with_git_env("GIT_OBJECT_DIRECTORY", object_directory)
        |> with_git_env("GIT_ALTERNATE_OBJECT_DIRECTORIES", alternate)

      {:ok, capture_opts}
    else
      {:error, reason} -> {:error, {:workspace_object_directory_unavailable, reason}}
    end
  end

  defp create_capture_dir(opts) do
    parent = Keyword.get(opts, :temporary_root, System.tmp_dir!()) |> Path.expand()
    path = temporary_path(parent, "twelvgaige-capture")

    with :ok <- File.mkdir_p(parent),
         :ok <- File.mkdir(path),
         :ok <- File.chmod(path, 0o700) do
      {:ok, path}
    end
  end

  defp temporary_path(parent, prefix) do
    suffix = System.unique_integer([:positive, :monotonic])
    Path.join(parent, "#{prefix}-#{suffix}")
  end

  defp ensure_absent(path) do
    if File.exists?(path), do: {:error, :workspace_path_exists}, else: :ok
  end

  defp protect_tree(root) do
    with {:ok, stat} <- File.lstat(root) do
      case stat.type do
        :directory ->
          with :ok <- File.chmod(root, 0o700),
               {:ok, names} <- File.ls(root) do
            Enum.reduce_while(names, :ok, fn name, :ok ->
              case protect_tree(Path.join(root, name)) do
                :ok -> {:cont, :ok}
                {:error, reason} -> {:halt, {:error, reason}}
              end
            end)
          end

        :regular ->
          owner_mode = stat.mode &&& 0o700
          File.chmod(root, owner_mode)

        :symlink ->
          :ok

        type ->
          {:error, {:workspace_special_file_unsupported, root, type}}
      end
    end
  end

  defp run(args, opts) do
    with {:ok, audit} <- begin_mutation_audit(args, opts) do
      result = run_command(args, opts)

      case finish_mutation_audit(audit, result) do
        :ok -> result
        {:error, _reason} = error -> error
      end
    end
  end

  defp run_command(args, opts) do
    case Keyword.get(opts, :command_runner) do
      runner when is_function(runner, 3) ->
        normalize_runner_result(runner.("git", args, system_command_opts(opts)))

      nil ->
        runner_opts = [
          timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
          max_output_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes),
          env: neutral_env(opts),
          scrub_env?: true
        ]

        case CommandRunner.run("git", args, runner_opts) do
          {:ok, %{status: 0, stdout: output}} ->
            {:ok, output}

          {:ok, result} ->
            {:error, %{status: result.status, output: result.stdout <> result.stderr}}

          {:error, reason} ->
            {:error, reason}
        end
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp begin_mutation_audit(args, opts) do
    case command_policy(args) do
      {:mutation, command_class} ->
        begin_required_mutation_audit(command_class, opts)

      {:read, _command_class} ->
        {:ok, nil}

      :unknown ->
        if Keyword.get(opts, :require_mutation_audit?, false),
          do: {:error, :git_managed_command_unclassified},
          else: {:ok, nil}
    end
  end

  defp begin_required_mutation_audit(command_class, opts) do
    if Keyword.get(opts, :require_mutation_audit?, false) do
      case Keyword.get(opts, :git_mutation_audit) do
        %MutationAudit{} = audit ->
          with {:ok, mutation_id} <- MutationAudit.intent(audit, command_class),
               do: {:ok, {audit, mutation_id, command_class}}

        _audit ->
          {:error, :git_mutation_audit_required}
      end
    else
      {:ok, nil}
    end
  end

  defp finish_mutation_audit(nil, _result), do: :ok

  defp finish_mutation_audit({audit, mutation_id, command_class}, result),
    do: MutationAudit.terminal(audit, mutation_id, command_class, result)

  defp command_policy(args) do
    args
    |> command_args()
    |> classify_command()
  end

  defp command_args(["-C", _path | rest]), do: command_args(rest)
  defp command_args(["-c", _setting | rest]), do: command_args(rest)
  defp command_args(["--no-pager" | rest]), do: command_args(rest)
  defp command_args(args), do: args

  defp classify_command(["--version" | _rest]), do: {:read, :version}

  defp classify_command([command | _rest])
       when command in [
              "rev-parse",
              "status",
              "symbolic-ref",
              "ls-files",
              "ls-tree",
              "show",
              "diff",
              "merge-base",
              "cat-file",
              "rev-list"
            ],
       do: {:read, Map.fetch!(@read_command_classes, command)}

  defp classify_command(["worktree", "list" | _rest]), do: {:read, :worktree_list}
  defp classify_command(["worktree", "add" | _rest]), do: {:mutation, :worktree_add}
  defp classify_command(["worktree", "remove" | _rest]), do: {:mutation, :worktree_remove}
  defp classify_command(["bundle", "verify" | _rest]), do: {:read, :bundle_verify}
  defp classify_command(["bundle", "create" | _rest]), do: {:mutation, :bundle_create}

  defp classify_command(["hash-object" | rest]),
    do: if("-w" in rest, do: {:mutation, :hash_object_write}, else: {:read, :hash_object})

  defp classify_command(["apply" | rest]) do
    if "--check" in rest and "--index" not in rest and "--cached" not in rest,
      do: {:read, :apply_check},
      else: {:mutation, :apply}
  end

  defp classify_command(["config" | rest]) do
    if source_read_args?(["config" | rest]),
      do: {:read, :config_read},
      else: {:mutation, :config_write}
  end

  defp classify_command(["remote", "remove" | _rest]), do: {:mutation, :remote_remove}
  defp classify_command(["remote", "get-url" | _rest]), do: {:read, :remote_get_url}

  defp classify_command([command | _rest])
       when command in [
              "clone",
              "checkout",
              "commit-tree",
              "update-ref",
              "reset",
              "read-tree",
              "write-tree",
              "update-index"
            ],
       do: {:mutation, Map.fetch!(@mutation_command_classes, command)}

  defp classify_command(_args), do: :unknown

  defp normalize_runner_result({:ok, output}) when is_binary(output), do: {:ok, output}
  defp normalize_runner_result({:error, _reason} = error), do: error
  defp normalize_runner_result({output, 0}) when is_binary(output), do: {:ok, output}
  defp normalize_runner_result({output, status}), do: {:error, %{status: status, output: output}}

  defp system_command_opts(opts),
    do: [stderr_to_stdout: true, env: neutral_env(opts)]

  defp neutral_env(opts) do
    overrides =
      Keyword.get(opts, :git_env, []) |> Map.new(fn {key, value} -> {to_string(key), value} end)

    neutral_home = Keyword.get(opts, :git_home, System.tmp_dir!())

    %{
      "LC_ALL" => "C",
      "LANG" => "C",
      "HOME" => neutral_home,
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_CONFIG_GLOBAL" => Path.join(neutral_home, ".twelvgaige-empty-gitconfig"),
      "GIT_TERMINAL_PROMPT" => "0",
      "GIT_OPTIONAL_LOCKS" => "0",
      "GIT_PAGER" => "cat",
      "GIT_EDITOR" => "true",
      "GIT_SEQUENCE_EDITOR" => "true",
      "GIT_ASKPASS" => "true",
      "GIT_LITERAL_PATHSPECS" => "1"
    }
    |> Map.merge(overrides)
    |> Enum.map(fn {key, value} -> {key, to_string(value)} end)
  end

  defp with_git_env(opts, key, value) do
    env = Keyword.get(opts, :git_env, []) |> Keyword.put(git_env_key(key), value)
    Keyword.put(opts, :git_env, env)
  end

  defp git_env_key("GIT_INDEX_FILE"), do: :GIT_INDEX_FILE
  defp git_env_key("GIT_OBJECT_DIRECTORY"), do: :GIT_OBJECT_DIRECTORY
  defp git_env_key("GIT_ALTERNATE_OBJECT_DIRECTORIES"), do: :GIT_ALTERNATE_OBJECT_DIRECTORIES

  defp split_nul(binary), do: :binary.split(binary, <<0>>, [:global])

  defp source_read_args?(["worktree", "list" | _rest]), do: true
  defp source_read_args?(["worktree" | _rest]), do: false

  defp source_read_args?(["config" | rest]) do
    Enum.any?(rest, &(&1 in ["--get", "--get-all", "--get-regexp", "--bool", "--list"])) and
      Enum.all?(
        rest,
        &(&1 not in [
            "--add",
            "--replace-all",
            "--unset",
            "--unset-all",
            "--remove-section",
            "--rename-section"
          ])
      )
  end

  defp source_read_args?([command | _rest]), do: command in @source_read_commands

  defp trim_line(binary) do
    binary
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end
end
