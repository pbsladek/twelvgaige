defmodule Twelvgaige.Authoring.Patch do
  @moduledoc """
  Patch artifact inspection, verification, and guarded application.

  Patch writes are intentionally narrow: only replace operations that pass the
  verifier can be written, and write mode requires a matching human approval
  artifact.
  """

  alias Twelvgaige.Authoring.AtomicFile
  alias Twelvgaige.Audit.Checkpoint
  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Agent
  alias Twelvgaige.Shell.Format.JSON, as: JSONFormat
  alias Twelvgaige.Shell.Format.TOML, as: TOMLFormat
  alias Twelvgaige.Shell.Format.YAML, as: YAMLFormat
  alias Twelvgaige.Shell.Lint
  alias Twelvgaige.Shell.Workflow

  @digest_regex ~r/^sha256:[0-9a-f]{64}$/
  @max_content_bytes 512 * 1024
  @allowed_validation_commands MapSet.new(["shell validate", "shell lint"])

  @type report :: map()

  @spec inspect_file(Path.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def inspect_file(path, opts \\ []) do
    with {:ok, patch} <- load_patch(path) do
      {:ok, inspect_patch(patch, opts)}
    end
  end

  @spec verify_file(Path.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def verify_file(path, opts \\ []) do
    with {:ok, patch} <- load_patch(path),
         {:ok, approval} <- maybe_load_approval(Keyword.get(opts, :approval)) do
      {:ok, verify_patch(patch, approval, opts)}
    end
  end

  @spec apply_file(Path.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def apply_file(path, opts \\ []) do
    if Keyword.get(opts, :write?, false) do
      with {:ok, patch} <- load_patch(path),
           {:ok, approval} <- maybe_load_approval(Keyword.get(opts, :approval)) do
        verify_report = verify_patch(patch, approval, opts)
        apply_verified_patch(patch, approval, verify_report, opts)
      end
    else
      with {:ok, report} <- verify_file(path, opts) do
        {:ok,
         apply_report(report,
           mode: "dry_run",
           write_requested: false,
           changed: false
         )}
      end
    end
  end

  @spec canonical_digest(map()) :: String.t()
  def canonical_digest(patch) when is_map(patch) do
    patch
    |> Map.delete("patch_digest")
    |> canonical_json()
    |> sha256()
  end

  @spec approval_digest(map()) :: String.t()
  def approval_digest(approval) when is_map(approval), do: canonical_digest(approval)

  defp load_patch(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, patch} <- Jason.decode(contents),
         :ok <- validate_patch_shape(patch) do
      {:ok, patch}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "patch artifact must be JSON",
           details: %{path: path, reason: Exception.message(error)}
         )}

      {:error, reason} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "unable to read patch artifact",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp maybe_load_approval(nil), do: {:ok, nil}

  defp maybe_load_approval(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, approval} <- Jason.decode(contents),
         :ok <- validate_approval_shape(approval) do
      {:ok, approval}
    else
      {:error, %Error{} = error} ->
        {:error, error}

      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "patch approval must be JSON",
           details: %{path: path, reason: Exception.message(error)}
         )}

      {:error, reason} ->
        {:error,
         Error.new(:input_error, :invalid_shell, "unable to read patch approval",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp inspect_patch(patch, opts) do
    computed_digest = canonical_digest(patch)
    stored_digest = Map.get(patch, "patch_digest")
    digest_findings = digest_findings(stored_digest, computed_digest)
    root = Keyword.get(opts, :root)

    files =
      patch
      |> Map.get("files", [])
      |> Enum.map(&inspect_file_entry(&1, root))

    findings = digest_findings ++ Enum.flat_map(files, &Map.get(&1, "findings", []))
    status = if error_findings?(findings), do: "failed", else: "ok"

    %{
      "kind" => "twelvgaige.patch.inspect",
      "status" => status,
      "patch_id" => Map.get(patch, "id"),
      "patch_digest" => computed_digest,
      "declared_patch_digest" => stored_digest,
      "files" => files,
      "validations" => Map.get(patch, "validations", []),
      "summary" => Map.get(patch, "summary", %{}),
      "findings" => findings,
      "changed" => false,
      "exit_code" => if(status == "ok", do: 0, else: 4)
    }
  end

  defp verify_patch(patch, approval, opts) do
    root = Keyword.get(opts, :root)
    computed_digest = canonical_digest(patch)
    stored_digest = Map.get(patch, "patch_digest")
    patch_files = Map.get(patch, "files", [])

    findings =
      []
      |> Kernel.++(root_required_findings(root))
      |> Kernel.++(digest_findings(stored_digest, computed_digest))
      |> Kernel.++(approval_findings(approval, computed_digest))
      |> Kernel.++(validation_command_findings(Map.get(patch, "validations", []), root))
      |> Kernel.++(duplicate_path_findings(patch_files))

    files =
      patch_files
      |> Enum.map(&verify_file_entry(&1, root))

    findings = findings ++ Enum.flat_map(files, &Map.get(&1, "findings", []))
    status = if error_findings?(findings), do: "failed", else: "ok"

    %{
      "kind" => "twelvgaige.patch.verify",
      "status" => status,
      "patch_id" => Map.get(patch, "id"),
      "patch_digest" => computed_digest,
      "declared_patch_digest" => stored_digest,
      "approval" => approval_report(approval, computed_digest),
      "files" => files,
      "validations" => Map.get(patch, "validations", []),
      "summary" => Map.get(patch, "summary", %{}),
      "findings" => findings,
      "changed" => false,
      "exit_code" => if(status == "ok", do: 0, else: 4)
    }
  end

  defp apply_verified_patch(_patch, nil, verify_report, opts) do
    findings = [
      finding(
        "approval_required",
        "shell patch apply --write requires --approval with a matching human approval"
      )
    ]

    {:ok,
     apply_report(verify_report,
       mode: "write",
       write_requested: true,
       changed: false,
       findings: findings,
       audit: patch_apply_audit(verify_report, nil, Keyword.get(opts, :root), [], [], findings)
     )}
  end

  defp apply_verified_patch(patch, approval, %{"status" => "ok"} = verify_report, opts) do
    root = Keyword.fetch!(opts, :root)

    case write_patch_files(patch, root) do
      {:ok, write_results} ->
        validations = run_post_write_validations(patch, root)
        validation_findings = validation_findings(validations)
        exit_code = if validation_findings == [], do: 0, else: 1

        {:ok,
         apply_report(verify_report,
           mode: "write",
           write_requested: true,
           changed: true,
           files: merge_write_results(verify_report["files"], write_results),
           post_write_validations: validations,
           findings: validation_findings,
           exit_code: exit_code,
           audit:
             patch_apply_audit(
               verify_report,
               approval,
               root,
               write_results,
               validations,
               validation_findings
             )
         )}

      {:error, write_results, finding} ->
        {:ok,
         apply_report(verify_report,
           mode: "write",
           write_requested: true,
           changed: write_results != [],
           files: merge_write_results(verify_report["files"], write_results),
           findings: [finding],
           exit_code: 7,
           audit: patch_apply_audit(verify_report, approval, root, write_results, [], [finding])
         )}
    end
  end

  defp apply_verified_patch(_patch, _approval, verify_report, _opts) do
    {:ok,
     apply_report(verify_report,
       mode: "write",
       write_requested: true,
       changed: false
     )}
  end

  defp apply_report(report, opts) do
    findings = Map.get(report, "findings", []) ++ Keyword.get(opts, :findings, [])
    status = if error_findings?(findings), do: "failed", else: Map.get(report, "status", "failed")

    exit_code =
      Keyword.get_lazy(opts, :exit_code, fn ->
        cond do
          status == "ok" -> 0
          error_findings?(findings) -> 4
          true -> Map.get(report, "exit_code", 4)
        end
      end)

    report
    |> Map.put("kind", "twelvgaige.patch.apply")
    |> Map.put("mode", Keyword.fetch!(opts, :mode))
    |> Map.put("write_requested", Keyword.fetch!(opts, :write_requested))
    |> Map.put("changed", Keyword.fetch!(opts, :changed))
    |> Map.put("status", status)
    |> Map.put("exit_code", exit_code)
    |> Map.put("findings", findings)
    |> maybe_put("files", Keyword.get(opts, :files))
    |> maybe_put("post_write_validations", Keyword.get(opts, :post_write_validations))
    |> maybe_put("audit", Keyword.get(opts, :audit))
  end

  defp write_patch_files(patch, root) do
    patch
    |> Map.get("files", [])
    |> Enum.sort_by(&Map.get(&1, "path", ""))
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, results} ->
      case write_patch_file(file, root) do
        {:ok, result} ->
          {:cont, {:ok, [result | results]}}

        {:error, result, finding} ->
          {:halt, {:error, Enum.reverse([result | results]), finding}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _results, _finding} = error -> error
    end
  end

  defp write_patch_file(
         %{"path" => path, "content" => content, "after_digest" => after_digest},
         root
       ) do
    target = Path.expand(path, root)

    case AtomicFile.write(target, content) do
      :ok ->
        verify_written_file(path, target, after_digest)

      {:error, %Error{} = error} ->
        {:error, %{"path" => path, "write_status" => "failed"},
         finding("apply_write_failed", "unable to write patch target",
           path: path,
           error: Error.to_map(error)
         )}
    end
  end

  defp verify_written_file(path, target, after_digest) do
    case File.read(target) do
      {:ok, contents} ->
        final_digest = sha256(contents)
        result = %{"path" => path, "write_status" => "written", "final_digest" => final_digest}

        if final_digest == after_digest do
          {:ok, result}
        else
          {:error, result,
           finding("final_digest_mismatch", "written file digest does not match patch artifact",
             path: path,
             expected: after_digest,
             actual: final_digest
           )}
        end

      {:error, reason} ->
        {:error, %{"path" => path, "write_status" => "failed"},
         finding("apply_readback_failed", "unable to read patch target after write",
           path: path,
           reason: inspect(reason)
         )}
    end
  end

  defp merge_write_results(files, write_results) do
    results_by_path = Map.new(write_results, &{&1["path"], &1})

    Enum.map(files, fn file ->
      Map.merge(file, Map.get(results_by_path, file["path"], %{}))
    end)
  end

  defp run_post_write_validations(patch, root) do
    files_by_path = Map.new(Map.get(patch, "files", []), &{Map.get(&1, "path"), &1})

    patch
    |> Map.get("validations", [])
    |> Enum.map(&run_post_write_validation(&1, files_by_path, root))
  end

  defp run_post_write_validation(
         %{"command" => command, "path" => path} = validation,
         files,
         root
       ) do
    target = if is_binary(path), do: Path.expand(path, root), else: nil
    file = Map.get(files, path)

    findings =
      []
      |> Kernel.++(path_findings(path, root))
      |> Kernel.++(post_write_command_findings(command))
      |> Kernel.++(post_write_target_findings(command, file, path, target, validation))

    %{
      "command" => command,
      "path" => path,
      "absolute_path" => target,
      "status" => if(error_findings?(findings), do: "failed", else: "ok"),
      "findings" => findings
    }
    |> compact()
  end

  defp run_post_write_validation(validation, _files, _root) do
    %{
      "status" => "failed",
      "validation" => validation,
      "findings" => [finding("validation_invalid", "patch validation entry is invalid")]
    }
  end

  defp post_write_command_findings(command) do
    if MapSet.member?(@allowed_validation_commands, command) do
      []
    else
      [finding("validation_command_denied", "patch validation command is not allowed")]
    end
  end

  defp post_write_target_findings(command, file, path, target, validation)
       when command in ["shell validate", "shell lint"] and is_map(file) and is_binary(target) do
    case File.read(target) do
      {:ok, contents} ->
        run_post_write_command(command, file, path, target, contents, validation)

      {:error, reason} ->
        [
          finding("post_write_validation_read_failed", "unable to read validation target",
            path: path,
            reason: inspect(reason)
          )
        ]
    end
  end

  defp post_write_target_findings(command, _file, _path, _target, _validation)
       when command in ["shell validate", "shell lint"] do
    [finding("post_write_validation_target_unknown", "validation path is not part of the patch")]
  end

  defp post_write_target_findings(_command, _file, _path, _target, _validation), do: []

  defp run_post_write_command("shell validate", file, path, _target, contents, _validation) do
    case validate_shell_candidate(Map.get(file, "kind"), path, contents) do
      :ok -> []
      {:error, %Error{} = error} -> [post_write_validation_error(error)]
    end
  end

  defp run_post_write_command(
         "shell lint",
         %{"kind" => "workflow"},
         path,
         target,
         _contents,
         validation
       ) do
    strict? = Map.get(validation, "strict", true)

    case Lint.run_path(target, strict?: strict?) do
      {:ok, %{status: :ok}} ->
        []

      {:ok, report} ->
        [
          finding("post_write_lint_failed", "post-write shell lint failed",
            path: path,
            lint: Lint.to_map(report)
          )
        ]

      {:error, %Error{} = error} ->
        [post_write_validation_error(error)]
    end
  end

  defp run_post_write_command("shell lint", _file, path, _target, _contents, _validation) do
    [
      finding("post_write_lint_unsupported", "shell lint validation requires a workflow shell",
        path: path
      )
    ]
  end

  defp validate_shell_candidate("workflow", path, contents) do
    with {:ok, map} <- parse_shell_content(path, contents),
         {:ok, %Workflow{}} <- Workflow.from_map(map) do
      :ok
    end
  end

  defp validate_shell_candidate("agent", path, contents) do
    with {:ok, map} <- parse_shell_content(path, contents),
         {:ok, %Agent{}} <- Agent.from_map(map) do
      :ok
    end
  end

  defp validate_shell_candidate(kind, path, contents),
    do: validate_candidate(kind, path, contents)

  defp post_write_validation_error(%Error{} = error) do
    finding("post_write_validation_failed", error.message, error: Error.to_map(error))
  end

  defp validation_findings(validations) do
    Enum.flat_map(validations, &Map.get(&1, "findings", []))
  end

  defp patch_apply_audit(verify_report, approval, root, write_results, validations, findings) do
    events =
      verify_report
      |> patch_apply_events(approval, root, write_results, validations, findings)
      |> Enum.with_index(1)
      |> Enum.map(fn {event, seq} -> Map.put(event, :seq, seq) end)

    %{
      "events" => Enum.map(events, &Twelvgaige.Audit.Event.to_map/1),
      "checkpoint" => Checkpoint.export(events, scope: :authoring_patch)
    }
  end

  defp patch_apply_events(verify_report, approval, root, write_results, validations, findings) do
    status = if error_findings?(findings), do: :failed, else: :complete
    now = Twelvgaige.Clock.utc_now()

    start_event = %{
      event_type: :authoring_patch_apply_start,
      occurred_at: now,
      actor: :local_cli,
      patch_id: verify_report["patch_id"],
      patch_digest: verify_report["patch_digest"],
      approval: audit_approval(approval),
      root: root,
      files: audit_files(verify_report["files"])
    }

    file_events =
      Enum.map(write_results, fn result ->
        %{
          event_type: :authoring_patch_apply_file_written,
          occurred_at: now,
          actor: :local_cli,
          patch_id: verify_report["patch_id"],
          patch_digest: verify_report["patch_digest"],
          path: result["path"],
          write_status: result["write_status"],
          final_digest: result["final_digest"]
        }
      end)

    terminal_event = %{
      event_type:
        if(status == :complete,
          do: :authoring_patch_apply_complete,
          else: :authoring_patch_apply_failed
        ),
      occurred_at: now,
      actor: :local_cli,
      patch_id: verify_report["patch_id"],
      patch_digest: verify_report["patch_digest"],
      status: status,
      validation_status: validation_status(validations),
      findings: findings
    }

    [start_event | file_events] ++ [terminal_event]
  end

  defp audit_approval(nil), do: nil

  defp audit_approval(approval) do
    %{
      id: Map.get(approval, "id"),
      approved_by: Map.get(approval, "approved_by"),
      scope: Map.get(approval, "scope"),
      patch_digest: Map.get(approval, "patch_digest")
    }
  end

  defp audit_files(files) do
    Enum.map(files || [], fn file ->
      Map.take(file, ["path", "kind", "operation", "before_digest", "after_digest"])
    end)
  end

  defp validation_status([]), do: :not_run

  defp validation_status(validations) do
    if Enum.any?(validations, &(&1["status"] == "failed")), do: :failed, else: :ok
  end

  defp validate_patch_shape(%{"kind" => "twelvgaige.patch.v1", "files" => files})
       when is_list(files) and files != [],
       do: :ok

  defp validate_patch_shape(_patch) do
    {:error,
     Error.new(:input_error, :invalid_shell, "patch artifact must be kind twelvgaige.patch.v1")}
  end

  defp validate_approval_shape(%{"kind" => "twelvgaige.patch_approval.v1"}), do: :ok

  defp validate_approval_shape(_approval) do
    {:error,
     Error.new(
       :input_error,
       :invalid_shell,
       "patch approval must be kind twelvgaige.patch_approval.v1"
     )}
  end

  defp inspect_file_entry(file, root) do
    path = Map.get(file, "path")
    kind = Map.get(file, "kind")

    findings =
      file
      |> base_file_findings()
      |> Kernel.++(path_findings(path, root))
      |> Kernel.++(kind_path_findings(kind, path))
      |> Kernel.++(content_findings(file))

    file_report(file, root, findings)
  end

  defp verify_file_entry(file, root) do
    path = Map.get(file, "path")
    kind = Map.get(file, "kind")

    findings =
      file
      |> base_file_findings()
      |> Kernel.++(path_findings(path, root))
      |> Kernel.++(kind_path_findings(kind, path))
      |> Kernel.++(content_findings(file))
      |> Kernel.++(target_file_findings(file, root))
      |> Kernel.++(candidate_validation_findings(file))

    file_report(file, root, findings)
  end

  defp file_report(file, root, findings) do
    path = Map.get(file, "path")

    %{
      "path" => path,
      "absolute_path" => absolute_path(path, root),
      "kind" => Map.get(file, "kind"),
      "operation" => Map.get(file, "operation"),
      "before_digest" => Map.get(file, "before_digest"),
      "after_digest" => Map.get(file, "after_digest"),
      "before_size_bytes" => Map.get(file, "before_size_bytes"),
      "after_size_bytes" => Map.get(file, "after_size_bytes"),
      "findings" => findings
    }
    |> compact()
  end

  defp base_file_findings(file) do
    []
    |> require_field(file, "path", &non_empty_string?/1)
    |> require_field(file, "kind", &non_empty_string?/1)
    |> require_field(file, "operation", &(&1 == "replace"))
    |> require_field(file, "before_digest", &digest?/1)
    |> require_field(file, "after_digest", &digest?/1)
    |> require_field(file, "before_size_bytes", &non_negative_integer?/1)
    |> require_field(file, "after_size_bytes", &non_negative_integer?/1)
    |> require_field(file, "content", &is_binary/1)
  end

  defp require_field(findings, file, field, predicate) do
    value = Map.get(file, field)

    if predicate.(value) do
      findings
    else
      [
        finding("invalid_field", "patch file field #{field} is invalid",
          field: field,
          value: value
        )
        | findings
      ]
    end
  end

  defp path_findings(path, root) do
    cond do
      not is_binary(path) or path == "" ->
        [finding("path_invalid", "patch path must be a non-empty relative path")]

      Path.type(path) == :absolute ->
        [
          finding("path_absolute", "patch path must be relative to the traphouse root",
            path: path
          )
        ]

      path_has_parent_segment?(path) ->
        [finding("path_traversal", "patch path must not contain parent traversal", path: path)]

      is_binary(root) and outside_root?(path, root) ->
        [
          finding("path_outside_root", "patch path resolves outside the traphouse root",
            path: path
          )
        ]

      true ->
        []
    end
  end

  defp kind_path_findings(kind, path) when is_binary(kind) and is_binary(path) do
    if allowed_kind_path?(kind, path) do
      []
    else
      [
        finding("kind_path_denied", "patch file kind is not allowed for this path",
          kind: kind,
          path: path
        )
      ]
    end
  end

  defp kind_path_findings(kind, path) do
    [
      finding("kind_path_denied", "patch file kind is not allowed for this path",
        kind: kind,
        path: path
      )
    ]
  end

  defp content_findings(%{"content" => content} = file) when is_binary(content) do
    []
    |> maybe_add(byte_size(content) != Map.get(file, "after_size_bytes"), fn ->
      finding("after_size_mismatch", "candidate content size does not match after_size_bytes",
        expected: Map.get(file, "after_size_bytes"),
        actual: byte_size(content)
      )
    end)
    |> maybe_add(sha256(content) != Map.get(file, "after_digest"), fn ->
      finding("after_digest_mismatch", "candidate content digest does not match after_digest",
        expected: Map.get(file, "after_digest"),
        actual: sha256(content)
      )
    end)
    |> maybe_add(byte_size(content) > @max_content_bytes, fn ->
      finding("content_too_large", "candidate content exceeds maximum patch size",
        max_bytes: @max_content_bytes,
        actual_bytes: byte_size(content)
      )
    end)
    |> maybe_add(String.contains?(content, <<0>>), fn ->
      finding("binary_content", "candidate content appears to be binary")
    end)
  end

  defp content_findings(_file), do: []

  defp target_file_findings(_file, nil), do: []

  defp target_file_findings(file, root) do
    path = Map.get(file, "path")

    cond do
      not is_binary(path) or path == "" or Path.type(path) == :absolute or
          path_has_parent_segment?(path) ->
        []

      true ->
        target_file_findings_for_path(file, root, path)
    end
  end

  defp target_file_findings_for_path(file, root, path) do
    target = Path.expand(path, root)

    with [] <- symlink_findings(target, root),
         {:ok, stat} <- File.stat(target),
         true <- stat.type == :regular,
         {:ok, contents} <- File.read(target) do
      []
      |> maybe_add(stat.size != Map.get(file, "before_size_bytes"), fn ->
        finding("before_size_mismatch", "current file size does not match before_size_bytes",
          expected: Map.get(file, "before_size_bytes"),
          actual: stat.size
        )
      end)
      |> maybe_add(sha256(contents) != Map.get(file, "before_digest"), fn ->
        finding("before_digest_mismatch", "current file digest does not match before_digest",
          expected: Map.get(file, "before_digest"),
          actual: sha256(contents)
        )
      end)
      |> maybe_add(Map.get(stat, :links, 1) > 1, fn ->
        finding("hard_link_target", "patch target has multiple hard links")
      end)
    else
      findings when is_list(findings) ->
        findings

      {:error, :enoent} ->
        [finding("target_missing", "patch target file does not exist", path: path)]

      {:error, reason} ->
        [
          finding("target_unreadable", "patch target file cannot be read",
            path: path,
            reason: inspect(reason)
          )
        ]

      false ->
        [finding("target_not_regular", "patch target must be a regular file", path: path)]
    end
  end

  defp candidate_validation_findings(%{"kind" => kind, "path" => path, "content" => content})
       when is_binary(kind) and is_binary(path) and is_binary(content) do
    case validate_candidate(kind, path, content) do
      :ok ->
        []

      {:error, %Error{} = error} ->
        [finding("candidate_invalid", error.message, error: Error.to_map(error))]
    end
  end

  defp candidate_validation_findings(_file), do: []

  defp validate_candidate(kind, path, content) when kind in ["workflow", "agent"] do
    with {:ok, map} <- parse_shell_content(path, content) do
      case kind do
        "workflow" ->
          with {:ok, workflow} <- Workflow.from_map(map),
               lint <- Lint.run(workflow, strict?: true, path: path),
               :ok <- require_lint_success(lint) do
            :ok
          end

        "agent" ->
          with {:ok, %Agent{}} <- Agent.from_map(map) do
            :ok
          end
      end
    end
  end

  defp validate_candidate("shot_template", path, content) do
    with {:ok, %{"kind" => "shot_template", "shot" => shot}} when is_map(shot) <-
           parse_shell_content(path, content) do
      :ok
    else
      {:ok, _map} ->
        {:error, Error.new(:input_error, :invalid_shell, "shot template candidate is invalid")}

      {:error, _error} = error ->
        error
    end
  end

  defp validate_candidate("scaffold", path, content) do
    with {:ok, %{"kind" => "scaffold", "workflow" => workflow}} when is_map(workflow) <-
           parse_shell_content(path, content) do
      :ok
    else
      {:ok, _map} ->
        {:error, Error.new(:input_error, :invalid_shell, "scaffold candidate is invalid")}

      {:error, _error} = error ->
        error
    end
  end

  defp validate_candidate("library_lock", path, content) do
    with {:ok, %{"kind" => "library_lock", "entries" => entries}} when is_list(entries) <-
           parse_shell_content(path, content) do
      :ok
    else
      {:ok, _map} ->
        {:error, Error.new(:input_error, :invalid_shell, "library lock candidate is invalid")}

      {:error, _error} = error ->
        error
    end
  end

  defp validate_candidate("doc", _path, _content), do: :ok
  defp validate_candidate(_kind, _path, _content), do: :ok

  defp parse_shell_content(path, content) do
    case path |> Path.extname() |> String.downcase() do
      ".json" ->
        JSONFormat.parse(content, path)

      ".toml" ->
        TOMLFormat.parse(content, path)

      ".yaml" ->
        YAMLFormat.parse(content, path)

      ".yml" ->
        YAMLFormat.parse(content, path)

      ".lock" ->
        YAMLFormat.parse(content, path)

      _extension ->
        {:error, Error.new(:input_error, :invalid_shell, "unsupported patch candidate extension")}
    end
  end

  defp require_lint_success(%{status: :ok}), do: :ok

  defp require_lint_success(report) do
    {:error,
     Error.new(:compile_error, :invalid_shell, "patch candidate failed strict lint",
       details: %{lint: Lint.to_map(report)}
     )}
  end

  defp symlink_findings(target, root) do
    root = Path.expand(root)

    target
    |> path_chain(root)
    |> Enum.find(&symlink?/1)
    |> case do
      nil -> []
      path -> [finding("symlink_path", "patch path must not traverse symlinks", path: path)]
    end
  end

  defp path_chain(target, root) do
    relative = Path.relative_to(target, root)

    relative
    |> Path.split()
    |> Enum.scan(root, &Path.join(&2, &1))
  end

  defp symlink?(path) do
    case File.lstat(path) do
      {:ok, %{type: :symlink}} -> true
      {:ok, _stat} -> false
      {:error, :enoent} -> false
      {:error, _reason} -> false
    end
  end

  defp validation_command_findings(validations, root) when is_list(validations) do
    Enum.flat_map(validations, fn
      %{"command" => command, "path" => path} when is_binary(command) ->
        []
        |> Kernel.++(path_findings(path, root))
        |> Kernel.++(
          if MapSet.member?(@allowed_validation_commands, command) do
            []
          else
            [
              finding("validation_command_denied", "patch validation command is not allowed",
                command: command
              )
            ]
          end
        )

      _validation ->
        [finding("validation_invalid", "patch validation entry is invalid")]
    end)
  end

  defp validation_command_findings(_validations, _root),
    do: [finding("validation_invalid", "patch validations must be a list")]

  defp duplicate_path_findings(files) when is_list(files) do
    files
    |> Enum.map(&Map.get(&1, "path"))
    |> Enum.filter(&is_binary/1)
    |> Enum.frequencies()
    |> Enum.flat_map(fn
      {path, count} when count > 1 ->
        [
          finding("duplicate_patch_path", "patch artifact contains duplicate file paths",
            path: path
          )
        ]

      {_path, _count} ->
        []
    end)
  end

  defp duplicate_path_findings(_files), do: []

  defp approval_findings(nil, _patch_digest), do: []

  defp approval_findings(approval, patch_digest) do
    []
    |> maybe_add(Map.get(approval, "patch_digest") != patch_digest, fn ->
      finding("approval_digest_mismatch", "approval patch digest does not match artifact",
        expected: patch_digest,
        actual: Map.get(approval, "patch_digest")
      )
    end)
    |> maybe_add(not human_actor?(Map.get(approval, "approved_by")), fn ->
      finding("approval_actor_invalid", "approval must be from a human actor")
    end)
    |> maybe_add(Map.get(approval, "scope") not in ["file", "repo", "ci"], fn ->
      finding("approval_scope_invalid", "approval scope must be file, repo, or ci")
    end)
    |> Kernel.++(approval_expiry_findings(Map.get(approval, "expires_at")))
  end

  defp approval_report(nil, _patch_digest), do: %{"status" => "not_provided"}

  defp approval_report(approval, patch_digest) do
    findings = approval_findings(approval, patch_digest)
    status = if error_findings?(findings), do: "invalid", else: "valid"

    %{
      "status" => status,
      "id" => Map.get(approval, "id"),
      "approved_by" => Map.get(approval, "approved_by"),
      "scope" => Map.get(approval, "scope"),
      "patch_digest" => Map.get(approval, "patch_digest"),
      "findings" => findings
    }
    |> compact()
  end

  defp approval_expiry_findings(nil), do: []

  defp approval_expiry_findings(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, expires_at, _offset} ->
        if DateTime.compare(expires_at, Twelvgaige.Clock.utc_now()) == :gt do
          []
        else
          [finding("approval_expired", "patch approval is expired", expires_at: value)]
        end

      {:error, reason} ->
        [
          finding("approval_expires_invalid", "patch approval expiry is invalid",
            reason: inspect(reason)
          )
        ]
    end
  end

  defp approval_expiry_findings(_value),
    do: [finding("approval_expires_invalid", "patch approval expiry is invalid")]

  defp digest_findings(stored_digest, computed_digest) do
    cond do
      is_nil(stored_digest) ->
        [
          finding("patch_digest_missing", "patch artifact is missing patch_digest",
            actual: computed_digest
          )
        ]

      stored_digest != computed_digest ->
        [
          finding(
            "patch_digest_mismatch",
            "patch artifact digest does not match canonical digest",
            expected: stored_digest,
            actual: computed_digest
          )
        ]

      true ->
        []
    end
  end

  defp root_required_findings(nil),
    do: [finding("root_required", "patch verification requires --root")]

  defp root_required_findings(_root), do: []

  defp allowed_kind_path?("workflow", path), do: shell_path_under?(path, "workflows")
  defp allowed_kind_path?("agent", path), do: shell_path_under?(path, "workflows/agents")
  defp allowed_kind_path?("shot_template", path), do: shell_path_under?(path, "shots")
  defp allowed_kind_path?("scaffold", path), do: shell_path_under?(path, "scaffolds")
  defp allowed_kind_path?("library_lock", "twelvgaige-library.lock"), do: true
  defp allowed_kind_path?("library_lock", "twelvgaige-scaffold-library.lock"), do: true
  defp allowed_kind_path?("doc", "README.md"), do: true
  defp allowed_kind_path?("doc", "usage.md"), do: true
  defp allowed_kind_path?("doc", "USAGE.md"), do: true

  defp allowed_kind_path?("doc", path),
    do: String.starts_with?(path, "docs/") and Path.extname(path) == ".md"

  defp allowed_kind_path?(_kind, _path), do: false

  defp shell_path_under?(path, prefix) do
    String.starts_with?(path, prefix <> "/") and
      String.downcase(Path.extname(path)) in [".yaml", ".yml", ".json", ".toml"]
  end

  defp absolute_path(path, root) when is_binary(path) and is_binary(root),
    do: Path.expand(path, root)

  defp absolute_path(_path, _root), do: nil

  defp outside_root?(path, root) do
    expanded = Path.expand(path, root)
    root = Path.expand(root)
    relative = Path.relative_to(expanded, root)

    expanded != root and
      (relative == ".." or String.starts_with?(relative, "../") or
         Path.type(relative) != :relative)
  end

  defp path_has_parent_segment?(path) do
    path |> Path.split() |> Enum.any?(&(&1 == ".."))
  end

  defp human_actor?(actor) when is_binary(actor) and actor != "",
    do: not String.starts_with?(actor, "agent:")

  defp human_actor?(_actor), do: false

  defp maybe_add(findings, true, fun), do: [fun.() | findings]
  defp maybe_add(findings, false, _fun), do: findings

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp finding(status, message, extra \\ []) do
    %{
      "severity" => "error",
      "status" => status,
      "message" => message
    }
    |> Map.merge(Map.new(extra, fn {key, value} -> {Atom.to_string(key), value} end))
    |> compact()
  end

  defp error_findings?(findings), do: Enum.any?(findings, &(Map.get(&1, "severity") == "error"))
  defp non_empty_string?(value), do: is_binary(value) and value != ""
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp digest?(value), do: is_binary(value) and Regex.match?(@digest_regex, value)

  defp sha256(contents),
    do: "sha256:" <> (:crypto.hash(:sha256, contents) |> Base.encode16(case: :lower))

  defp canonical_json(value) when is_map(value) do
    entries =
      value
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} ->
        Jason.encode!(to_string(key)) <> ":" <> canonical_json(value)
      end)

    "{" <> Enum.join(entries, ",") <> "}"
  end

  defp canonical_json(value) when is_list(value),
    do: "[" <> (value |> Enum.map(&canonical_json/1) |> Enum.join(",")) <> "]"

  defp canonical_json(value) when is_binary(value), do: Jason.encode!(value)
  defp canonical_json(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_json(value) when is_float(value), do: Jason.encode!(value)
  defp canonical_json(true), do: "true"
  defp canonical_json(false), do: "false"
  defp canonical_json(nil), do: "null"

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] or value == %{} end)
    |> Map.new()
  end
end
