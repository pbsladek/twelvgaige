defmodule Twelvgaige.Workspace.RepositoryInspection do
  @moduledoc "Read-only repository preflight and source-state identity."

  import Bitwise
  import Kernel, except: [inspect: 1]

  alias Twelvgaige.Workspace.Canonical
  alias Twelvgaige.Workspace.Git.SourceRead, as: Git

  @schema_version 1
  @encoding_version 1
  @max_nested_scan_entries 100_000
  @minimum_git_version {2, 39, 0}

  @enforce_keys [
    :root,
    :git_version,
    :common_dir,
    :local_identity,
    :logical_identity,
    :object_format,
    :head,
    :base_commit,
    :branch,
    :dirtiness,
    :features,
    :source_modes,
    :warnings,
    :unsupported_features,
    :source_state_token
  ]
  defstruct [
    :root,
    :git_version,
    :common_dir,
    :local_identity,
    :logical_identity,
    :object_format,
    :head,
    :base_commit,
    :branch,
    :dirtiness,
    :features,
    :source_modes,
    :warnings,
    :unsupported_features,
    :source_state_token,
    schema_version: @schema_version,
    encoding_version: @encoding_version
  ]

  @type t :: %__MODULE__{}

  @spec inspect(Path.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def inspect(repository, opts \\ []) do
    requested = Path.expand(repository)

    with {:ok, git_version} <- Git.version(opts),
         :ok <- supported_git_version(git_version),
         {:ok, root, bare?} <- repository_root(requested, opts),
         {:ok, common_dir} <- Git.common_dir(root, opts),
         {:ok, head} <- Git.resolve_commit(root, "HEAD", opts),
         {:ok, base_commit} <-
           Git.resolve_commit(root, Keyword.get(opts, :base_ref, "HEAD"), opts),
         {:ok, object_format_output} <-
           Git.read(root, ["rev-parse", "--show-object-format"], opts),
         object_format <- trim_line(object_format_output),
         {:ok, status} <- repository_status(root, bare?, opts),
         {:ok, tracked} <- tracked_entries(root, bare?, opts),
         {:ok, worktrees} <-
           Git.read(root, ["worktree", "list", "--porcelain", "-z"], opts),
         {:ok, identities} <- identities(root, common_dir, object_format, base_commit),
         {:ok, nested} <- nested_repositories(root, bare?),
         attrs <- attribute_features(root, tracked),
         features <-
           features(root, object_format, tracked, worktrees, nested, attrs, opts),
         dirtiness <- parse_status(status),
         unsupported <- unsupported_features(features),
         warnings <- warnings(dirtiness, features, unsupported),
         {:ok, source_state_token} <-
           source_state_token(root, head, base_commit, status, features, opts) do
      {:ok,
       %__MODULE__{
         root: root,
         git_version: format_git_version(git_version),
         common_dir: common_dir,
         local_identity: identities.local,
         logical_identity: identities.logical,
         object_format: object_format,
         head: head,
         base_commit: base_commit,
         branch: branch(root, opts),
         dirtiness: dirtiness,
         features: features,
         source_modes: source_modes(unsupported, features, dirtiness),
         warnings: warnings,
         unsupported_features: unsupported,
         source_state_token: source_state_token
       }}
    end
  end

  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = inspection), do: Map.from_struct(inspection)

  defp identities(root, common_dir, object_format, base_commit) do
    with {:ok, root_stat} <- File.stat(root),
         {:ok, common_stat} <- File.stat(common_dir) do
      {:ok,
       %{
         local: %{
           root: root,
           common_dir: common_dir,
           root_device: root_stat.major_device,
           root_inode: root_stat.inode,
           common_device: common_stat.major_device,
           common_inode: common_stat.inode
         },
         logical: %{
           object_format: object_format,
           base_commit: base_commit
         }
       }}
    end
  end

  defp branch(root, opts) do
    case Git.read(root, ["symbolic-ref", "--quiet", "--short", "HEAD"], opts) do
      {:ok, output} -> trim_line(output)
      {:error, _reason} -> nil
    end
  end

  defp supported_git_version(version) do
    if version_compare(version, @minimum_git_version) in [:eq, :gt],
      do: :ok,
      else: {:error, {:git_version_unsupported, version, @minimum_git_version}}
  end

  defp version_compare(left, right) do
    cond do
      left == right -> :eq
      left > right -> :gt
      true -> :lt
    end
  end

  defp format_git_version({major, minor, patch}), do: "#{major}.#{minor}.#{patch}"

  defp repository_root(requested, opts) do
    case Git.read(requested, ["rev-parse", "--show-toplevel"], opts) do
      {:ok, output} ->
        {:ok, trim_line(output), false}

      {:error, worktree_reason} ->
        case Git.read(requested, ["rev-parse", "--is-bare-repository"], opts) do
          {:ok, output} when output in ["true\n", "true\r\n", "true"] ->
            {:ok, requested, true}

          _not_bare ->
            {:error, {:repository_root_unresolved, worktree_reason}}
        end
    end
  end

  defp repository_status(_root, true, _opts), do: {:ok, ""}

  defp repository_status(root, false, opts) do
    Git.read(
      root,
      [
        "status",
        "--porcelain=v2",
        "-z",
        "--untracked-files=all",
        "--ignored=matching"
      ],
      opts
    )
  end

  defp tracked_entries(root, false, opts),
    do: Git.read(root, ["ls-files", "--stage", "-z"], opts)

  defp tracked_entries(root, true, opts) do
    Git.read(
      root,
      ["ls-tree", "-r", "-z", "--format=%(objectmode) %(objectname) 0%x09%(path)", "HEAD"],
      opts
    )
  end

  defp features(root, object_format, tracked, worktrees, nested, attrs, opts) do
    modes = tracked_modes(tracked)

    %{
      bare: git_boolean(root, ["rev-parse", "--is-bare-repository"], opts),
      shallow: git_boolean(root, ["rev-parse", "--is-shallow-repository"], opts),
      sparse_checkout: git_config_boolean(root, "core.sparseCheckout", opts),
      partial_clone: partial_clone?(root, opts),
      submodules: Enum.any?(modes, fn {mode, _path} -> mode == "160000" end),
      symlinks: Enum.any?(modes, fn {mode, _path} -> mode == "120000" end),
      case_collisions: case_collisions(modes),
      nested_repositories: nested,
      linked_worktrees: count_worktrees(worktrees),
      git_lfs: attrs.git_lfs,
      custom_filters: attrs.custom_filters,
      custom_diff_or_merge: attrs.custom_diff_or_merge,
      object_format: object_format
    }
  end

  defp parse_status(status) do
    status
    |> split_nul()
    |> parse_status_tokens(%{staged: 0, unstaged: 0, untracked: 0, ignored: 0, unmerged: 0})
    |> then(fn counts ->
      clean? = Enum.all?([:staged, :unstaged, :untracked, :unmerged], &(counts[&1] == 0))
      Map.put(counts, :clean, clean?)
    end)
  end

  defp parse_status_tokens([], counts), do: counts
  defp parse_status_tokens(["" | rest], counts), do: parse_status_tokens(rest, counts)

  defp parse_status_tokens([<<?1, ?\s, x, y, _rest::binary>> | rest], counts),
    do: parse_status_tokens(rest, count_xy(counts, x, y))

  defp parse_status_tokens([<<?2, ?\s, x, y, _rest::binary>>, _original | rest], counts),
    do: parse_status_tokens(rest, count_xy(counts, x, y))

  defp parse_status_tokens([<<?u, ?\s, _rest::binary>> | rest], counts),
    do: parse_status_tokens(rest, Map.update!(counts, :unmerged, &(&1 + 1)))

  defp parse_status_tokens([<<??, ?\s, _path::binary>> | rest], counts),
    do: parse_status_tokens(rest, Map.update!(counts, :untracked, &(&1 + 1)))

  defp parse_status_tokens([<<?!, ?\s, _path::binary>> | rest], counts),
    do: parse_status_tokens(rest, Map.update!(counts, :ignored, &(&1 + 1)))

  defp parse_status_tokens([_unknown | rest], counts), do: parse_status_tokens(rest, counts)

  defp count_xy(counts, x, y) do
    counts
    |> maybe_count(:staged, x != ?.)
    |> maybe_count(:unstaged, y != ?.)
  end

  defp maybe_count(counts, _key, false), do: counts
  defp maybe_count(counts, key, true), do: Map.update!(counts, key, &(&1 + 1))

  defp tracked_modes(output) do
    output
    |> split_nul()
    |> Enum.flat_map(fn entry ->
      case :binary.split(entry, <<"\t">>) do
        [metadata, path] ->
          case :binary.split(metadata, <<" ">>, [:global]) do
            [mode, _oid, "0"] -> [{mode, path}]
            _other -> []
          end

        _other ->
          []
      end
    end)
  end

  defp count_worktrees(output) do
    output
    |> split_nul()
    |> Enum.count(&match?(<<"worktree ", _path::binary>>, &1))
  end

  defp case_collisions(modes) do
    modes
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&String.valid?/1)
    |> Enum.group_by(&String.downcase/1)
    |> Enum.any?(fn {_folded, paths} -> length(Enum.uniq(paths)) > 1 end)
  end

  defp attribute_features(root, tracked) do
    tracked
    |> tracked_modes()
    |> Enum.map(&elem(&1, 1))
    |> Enum.filter(&(Path.basename(&1) == ".gitattributes"))
    |> Enum.reduce(%{git_lfs: false, custom_filters: false, custom_diff_or_merge: false}, fn path,
                                                                                             acc ->
      case safe_read(root, path) do
        {:ok, contents} ->
          %{
            git_lfs: acc.git_lfs or Regex.match?(~r/filter\s*=\s*lfs/, contents),
            custom_filters:
              acc.custom_filters or
                Regex.match?(~r/(?:^|\s)(?:filter|working-tree-encoding)=/, contents),
            custom_diff_or_merge:
              acc.custom_diff_or_merge or Regex.match?(~r/(?:^|\s)(?:diff|merge)=/, contents)
          }

        {:error, _reason} ->
          acc
      end
    end)
  end

  defp safe_read(root, relative) do
    path = Path.expand(relative, root)

    if within_root?(path, root) and File.regular?(path),
      do: File.read(path),
      else: {:error, :repository_attribute_path_invalid}
  end

  defp git_boolean(root, args, opts) do
    case Git.read(root, args, opts) do
      {:ok, output} -> trim_line(output) == "true"
      {:error, _reason} -> false
    end
  end

  defp git_config_boolean(root, key, opts),
    do: git_boolean(root, ["config", "--bool", "--get", key], opts)

  defp partial_clone?(root, opts) do
    case Git.read(
           root,
           [
             "config",
             "--local",
             "--get-regexp",
             "^(extensions\\.partialClone|remote\\..*\\.promisor)$"
           ],
           opts
         ) do
      {:ok, output} -> trim_line(output) != ""
      {:error, _reason} -> false
    end
  end

  defp nested_repositories(_root, true), do: {:ok, false}

  defp nested_repositories(root, false) do
    case scan_nested_repositories(root, root, 0) do
      {:ok, found, _seen} -> {:ok, found}
      {:error, _reason} = error -> error
    end
  end

  defp scan_nested_repositories(_root, _directory, count)
       when count > @max_nested_scan_entries,
       do: {:error, :repository_nested_scan_limit_exceeded}

  defp scan_nested_repositories(root, directory, count) do
    with {:ok, names} <- File.ls(directory) do
      Enum.reduce_while(names, {:ok, false, count}, fn name, {:ok, found, seen} ->
        path = Path.join(directory, name)

        cond do
          directory == root and name == ".git" ->
            {:cont, {:ok, found, seen + 1}}

          name == ".git" ->
            {:halt, {:ok, true, seen + 1}}

          true ->
            case File.lstat(path) do
              {:ok, %{type: :directory}} ->
                case scan_nested_repositories(root, path, seen + 1) do
                  {:ok, true, next_seen} -> {:halt, {:ok, true, next_seen}}
                  {:ok, false, next_seen} -> {:cont, {:ok, found, next_seen}}
                  {:error, reason} -> {:halt, {:error, reason}}
                end

              {:ok, _stat} ->
                {:cont, {:ok, found, seen + 1}}

              {:error, reason} ->
                {:halt, {:error, {:repository_scan_failed, path, reason}}}
            end
        end
      end)
    end
  end

  defp unsupported_features(features) do
    [
      {:bare, features.bare},
      {:shallow, features.shallow},
      {:sparse_checkout, features.sparse_checkout},
      {:partial_clone, features.partial_clone},
      {:submodules, features.submodules},
      {:git_lfs, features.git_lfs},
      {:custom_filters, features.custom_filters},
      {:custom_diff_or_merge, features.custom_diff_or_merge},
      {:case_collisions, features.case_collisions},
      {:nested_repositories, features.nested_repositories},
      {:sha256_object_format, features.object_format != "sha1"}
    ]
    |> Enum.filter(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp warnings(dirtiness, features, unsupported) do
    []
    |> maybe_warning(not dirtiness.clean, :repository_dirty)
    |> maybe_warning(dirtiness.ignored > 0, :repository_has_ignored_files)
    |> maybe_warning(features.linked_worktrees > 1, :repository_has_linked_worktrees)
    |> then(&(&1 ++ Enum.map(unsupported, fn feature -> {:unsupported_feature, feature} end)))
  end

  defp maybe_warning(warnings, true, warning), do: warnings ++ [warning]
  defp maybe_warning(warnings, false, _warning), do: warnings

  defp source_modes([], %{bare: false}, %{unmerged: count}) when count > 0, do: []

  defp source_modes([], %{bare: false}, %{clean: true}),
    do: [:committed, :staged, :working_tree]

  defp source_modes([], %{bare: false}, _dirtiness), do: [:staged, :working_tree]
  defp source_modes(_unsupported, _features, _dirtiness), do: []

  defp source_state_token(root, head, base_commit, status, features, opts) do
    with {:ok, index_digest} <- index_digest(root, opts),
         {:ok, worktree_digest} <- changed_content_digest(root, status) do
      Canonical.digest("source-state", 1, %{
        "head" => head,
        "base_commit" => base_commit,
        "index_digest" => index_digest,
        "status" => Base.url_encode64(status, padding: false),
        "worktree_digest" => worktree_digest,
        "features" => features
      })
    end
  end

  defp index_digest(root, opts) do
    with {:ok, output} <- Git.read(root, ["rev-parse", "--git-path", "index"], opts),
         path <- output |> trim_line() |> Path.expand(root) do
      case File.read(path) do
        {:ok, bytes} -> Canonical.digest_bytes("git-index", 1, bytes)
        {:error, :enoent} -> Canonical.digest_bytes("git-index", 1, "")
        {:error, reason} -> {:error, {:repository_index_read_failed, reason}}
      end
    end
  end

  defp changed_content_digest(root, status) do
    entries =
      status
      |> status_paths()
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(fn relative ->
        path = Path.expand(relative, root)

        cond do
          not within_root?(path, root) ->
            %{"path" => Canonical.path(relative), "state" => "invalid"}

          true ->
            case File.lstat(path) do
              {:ok, %{type: :regular, mode: mode}} ->
                {:ok, bytes} = File.read(path)
                {:ok, digest} = Canonical.digest_bytes("source-file", 1, bytes)

                %{
                  "path" => Canonical.path(relative),
                  "state" => "regular",
                  "mode" => mode &&& 0o777,
                  "digest" => digest
                }

              {:ok, %{type: :symlink}} ->
                {:ok, target} = File.read_link(path)
                {:ok, digest} = Canonical.digest_bytes("source-symlink", 1, target)
                %{"path" => Canonical.path(relative), "state" => "symlink", "digest" => digest}

              {:ok, %{type: type}} ->
                %{"path" => Canonical.path(relative), "state" => to_string(type)}

              {:error, :enoent} ->
                %{"path" => Canonical.path(relative), "state" => "deleted"}

              {:error, reason} ->
                %{"path" => Canonical.path(relative), "state" => Kernel.inspect(reason)}
            end
        end
      end)

    Canonical.digest("working-tree-overlay", 1, entries)
  end

  defp status_paths(status), do: status |> split_nul() |> status_paths([])
  defp status_paths([], acc), do: Enum.reverse(acc)
  defp status_paths(["" | rest], acc), do: status_paths(rest, acc)

  defp status_paths([<<?1, ?\s, _rest::binary>> = entry | rest], acc),
    do: status_paths(rest, [field_after_spaces(entry, 8) | acc])

  defp status_paths([<<?2, ?\s, _rest::binary>> = entry, original | rest], acc),
    do: status_paths(rest, [original, field_after_spaces(entry, 9) | acc])

  defp status_paths([<<??, ?\s, path::binary>> | rest], acc),
    do: status_paths(rest, [path | acc])

  defp status_paths([<<?!, ?\s, path::binary>> | rest], acc),
    do: status_paths(rest, [path | acc])

  defp status_paths([_entry | rest], acc), do: status_paths(rest, acc)

  defp field_after_spaces(binary, count), do: field_after_spaces(binary, count, 0)
  defp field_after_spaces(rest, count, count), do: rest

  defp field_after_spaces(<<?\s, rest::binary>>, count, seen),
    do: field_after_spaces(rest, count, seen + 1)

  defp field_after_spaces(<<_byte, rest::binary>>, count, seen),
    do: field_after_spaces(rest, count, seen)

  defp field_after_spaces(<<>>, _count, _seen), do: ""

  defp within_root?(path, root) do
    relative = Path.relative_to(path, root)

    relative != ".." and not String.starts_with?(relative, "../") and
      Path.type(relative) != :absolute
  end

  defp split_nul(binary), do: :binary.split(binary, <<0>>, [:global])

  defp trim_line(binary) do
    binary
    |> String.trim_trailing("\n")
    |> String.trim_trailing("\r")
  end
end
