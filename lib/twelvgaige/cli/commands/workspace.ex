defmodule Twelvgaige.CLI.Commands.Workspace do
  @moduledoc false

  alias Twelvgaige.Breech.IPC.{Client, Endpoint}
  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}

  def list(args, deps \\ []) do
    with {:ok, opts} <- parse(args, defaults()),
         {:ok, endpoint} <- discover(opts),
         {:ok, workspaces} <- list_fun(deps).(endpoint.address, client_opts(endpoint, opts)),
         workspaces <- repository_filter(workspaces, opts[:repository]) do
      {:ok, format_list(workspaces, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, args)
      {:error, reason} -> error(reason, args)
    end
  end

  def show(action, requested_id, args, deps \\ [])
      when action in [
             :show,
             :path,
             :status,
             :diff,
             :cleanup,
             :export,
             :apply,
             :reconcile,
             :review_cleanup
           ] do
    with {:ok, opts} <- parse(args, defaults()),
         {:ok, endpoint} <- discover(opts),
         {:ok, workspace_id} <- resolve_id(requested_id, endpoint, opts, deps),
         {:ok, result} <- execute(action, workspace_id, endpoint, opts, deps) do
      {:ok, format(action, result, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, args)
      {:error, reason} -> error(reason, args)
    end
  end

  def retention(action, args, deps \\ []) when action in [:status, :run] do
    with {:ok, opts} <- parse(args, defaults()),
         {:ok, endpoint} <- discover(opts),
         {:ok, report} <-
           retention_fun(action, deps).(endpoint.address, client_opts(endpoint, opts)) do
      {:ok, format_retention(action, report, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, args)
      {:error, reason} -> error(reason, args)
    end
  end

  def set(:list, args, deps) do
    with {:ok, opts} <- parse(args, defaults()),
         {:ok, endpoint} <- discover(opts),
         {:ok, sets} <- set_list_fun(deps).(endpoint.address, client_opts(endpoint, opts)) do
      {:ok, format_set_list(sets, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, args)
      {:error, reason} -> error(reason, args)
    end
  end

  def set(:show, [requested_id | args], deps) do
    with {:ok, opts} <- parse(args, defaults()),
         {:ok, endpoint} <- discover(opts),
         {:ok, sets} <- set_list_fun(deps).(endpoint.address, client_opts(endpoint, opts)),
         {:ok, set_id} <- resolve_set_id(requested_id, sets),
         {:ok, set} <-
           set_get_fun(deps).(endpoint.address, set_id, client_opts(endpoint, opts)) do
      {:ok, format_set_show(set, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, args)
      {:error, reason} -> error(reason, args)
    end
  end

  def set(:show, [], _deps), do: error(:workspace_set_id_required, [])

  defp defaults do
    [
      format: :human,
      repository: nil,
      write?: false,
      yes?: false,
      expected_epoch: nil,
      request_id: Twelvgaige.ID.new(:event),
      output: nil,
      target: "review-worktree",
      action: "quarantine",
      ipc_timeout_ms: 30_000
    ]
  end

  defp parse([], opts), do: {:ok, opts}

  defp parse(["--format", value | rest], opts) when value in ["human", "json"],
    do: parse(rest, Keyword.put(opts, :format, String.to_existing_atom(value)))

  defp parse(["--repo", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :repository, Path.expand(value)))

  defp parse(["--runtime-dir", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :runtime_dir, value))

  defp parse(["--endpoint", value | rest], opts),
    do: parse(rest, Keyword.put(opts, :endpoint_path, value))

  defp parse(["--write" | rest], opts), do: parse(rest, Keyword.put(opts, :write?, true))
  defp parse(["--yes" | rest], opts), do: parse(rest, Keyword.put(opts, :yes?, true))

  defp parse(["--expected-epoch", value | rest], opts) do
    case Integer.parse(value) do
      {epoch, ""} when epoch >= 0 -> parse(rest, Keyword.put(opts, :expected_epoch, epoch))
      _invalid -> {:error, :workspace_expected_epoch_invalid}
    end
  end

  defp parse(["--request-id", value | rest], opts) when value != "",
    do: parse(rest, Keyword.put(opts, :request_id, value))

  defp parse(["--output", value | rest], opts) when value != "",
    do: parse(rest, Keyword.put(opts, :output, value))

  defp parse(["--check" | rest], opts), do: parse(rest, Keyword.put(opts, :write?, false))

  defp parse(["--target", value | rest], opts)
       when value in ["review-worktree", "current-worktree"],
       do: parse(rest, Keyword.put(opts, :target, value))

  defp parse(["--action", value | rest], opts)
       when value in [
              "quarantine",
              "restore-backup",
              "resume-export",
              "resume-cleanup",
              "discard-review"
            ],
       do: parse(rest, Keyword.put(opts, :action, value))

  defp parse([unknown | _rest], _opts), do: {:error, {:unknown_option, unknown}}

  defp discover(opts) do
    path = opts[:endpoint_path] || Endpoint.default_path(runtime_dir: opts[:runtime_dir])
    Endpoint.discover(path: path)
  end

  defp resolve_id(requested, endpoint, opts, deps) do
    with {:ok, workspaces} <- list_fun(deps).(endpoint.address, client_opts(endpoint, opts)) do
      candidates = repository_filter(workspaces, opts[:repository])

      cond do
        requested == "--last" and candidates == [] ->
          {:error, :workspace_not_found}

        requested == "--last" ->
          {:ok, candidates |> List.last() |> value("id")}

        exact = Enum.find(candidates, &(value(&1, "id") == requested)) ->
          {:ok, value(exact, "id")}

        true ->
          case Enum.filter(candidates, &String.starts_with?(value(&1, "id", ""), requested)) do
            [workspace] -> {:ok, value(workspace, "id")}
            [] -> {:error, :workspace_not_found}
            matches -> {:error, {:workspace_id_ambiguous, Enum.map(matches, &value(&1, "id"))}}
          end
      end
    end
  end

  defp execute(:diff, id, endpoint, opts, deps),
    do: diff_fun(deps).(endpoint.address, id, client_opts(endpoint, opts))

  defp execute(:cleanup, id, endpoint, opts, deps) do
    cond do
      opts[:write?] and not opts[:yes?] ->
        {:error, :workspace_cleanup_confirmation_required}

      opts[:write?] and is_nil(opts[:expected_epoch]) ->
        {:error, :workspace_expected_epoch_required}

      true ->
        cleanup_fun(deps).(
          endpoint.address,
          id,
          client_opts(endpoint, opts) ++
            [
              write?: opts[:write?],
              yes?: opts[:yes?],
              expected_epoch: opts[:expected_epoch],
              request_id: opts[:request_id]
            ]
        )
    end
  end

  defp execute(:export, id, endpoint, opts, deps) do
    case opts[:output] do
      nil ->
        {:error, :workspace_export_output_required}

      output ->
        export_fun(deps).(
          endpoint.address,
          id,
          Path.expand(output),
          client_opts(endpoint, opts)
        )
    end
  end

  defp execute(:apply, id, endpoint, opts, deps) do
    cond do
      opts[:write?] and not opts[:yes?] ->
        {:error, :workspace_apply_confirmation_required}

      opts[:write?] and is_nil(opts[:expected_epoch]) ->
        {:error, :workspace_expected_epoch_required}

      true ->
        apply_fun(deps).(
          endpoint.address,
          id,
          client_opts(endpoint, opts) ++
            [
              write?: opts[:write?],
              yes?: opts[:yes?],
              expected_epoch: opts[:expected_epoch],
              target: opts[:target]
            ]
        )
    end
  end

  defp execute(:reconcile, id, endpoint, opts, deps) do
    cond do
      opts[:write?] and not opts[:yes?] ->
        {:error, :workspace_reconcile_confirmation_required}

      opts[:write?] and is_nil(opts[:expected_epoch]) ->
        {:error, :workspace_expected_epoch_required}

      true ->
        reconcile_fun(deps).(
          endpoint.address,
          id,
          client_opts(endpoint, opts) ++
            [
              write?: opts[:write?],
              yes?: opts[:yes?],
              expected_epoch: opts[:expected_epoch],
              action: reconciliation_action(opts[:action])
            ]
        )
    end
  end

  defp execute(:review_cleanup, id, endpoint, opts, deps) do
    cond do
      opts[:write?] and not opts[:yes?] ->
        {:error, :review_worktree_cleanup_confirmation_required}

      opts[:write?] and is_nil(opts[:expected_epoch]) ->
        {:error, :workspace_expected_epoch_required}

      true ->
        review_cleanup_fun(deps).(
          endpoint.address,
          id,
          client_opts(endpoint, opts) ++
            [
              write?: opts[:write?],
              yes?: opts[:yes?],
              expected_epoch: opts[:expected_epoch]
            ]
        )
    end
  end

  defp execute(_action, id, endpoint, opts, deps),
    do: get_fun(deps).(endpoint.address, id, client_opts(endpoint, opts))

  defp reconciliation_action("restore-backup"), do: :restore_backup
  defp reconciliation_action("resume-export"), do: :resume_export
  defp reconciliation_action("resume-cleanup"), do: :resume_cleanup
  defp reconciliation_action("discard-review"), do: :discard_review
  defp reconciliation_action(_action), do: :quarantine

  defp client_opts(endpoint, opts) do
    [token: endpoint.token, timeout_ms: opts[:ipc_timeout_ms]]
    |> maybe_put(:request_id, opts[:request_id])
  end

  defp list_fun(deps), do: Keyword.get(deps, :list_fun, &Client.list_workspaces/2)
  defp get_fun(deps), do: Keyword.get(deps, :get_fun, &Client.get_workspace/3)
  defp diff_fun(deps), do: Keyword.get(deps, :diff_fun, &Client.workspace_diff/3)
  defp cleanup_fun(deps), do: Keyword.get(deps, :cleanup_fun, &Client.cleanup_workspace/3)
  defp export_fun(deps), do: Keyword.get(deps, :export_fun, &Client.export_workspace/4)
  defp apply_fun(deps), do: Keyword.get(deps, :apply_fun, &Client.apply_workspace/3)

  defp reconcile_fun(deps),
    do: Keyword.get(deps, :reconcile_fun, &Client.reconcile_workspace/3)

  defp review_cleanup_fun(deps),
    do: Keyword.get(deps, :review_cleanup_fun, &Client.cleanup_review_worktree/3)

  defp retention_fun(:status, deps),
    do: Keyword.get(deps, :retention_status_fun, &Client.workspace_retention_status/2)

  defp retention_fun(:run, deps),
    do: Keyword.get(deps, :retention_run_fun, &Client.run_workspace_retention/2)

  defp set_list_fun(deps),
    do: Keyword.get(deps, :set_list_fun, &Client.list_workspace_sets/2)

  defp set_get_fun(deps),
    do: Keyword.get(deps, :set_get_fun, &Client.get_workspace_set/3)

  defp repository_filter(workspaces, nil), do: workspaces

  defp repository_filter(workspaces, repository),
    do: Enum.filter(workspaces, &(Path.expand(value(&1, "repository", "")) == repository))

  defp resolve_set_id("--last", []), do: {:error, :workspace_set_not_found}

  defp resolve_set_id("--last", sets),
    do: {:ok, sets |> List.last() |> value("id")}

  defp resolve_set_id(requested, sets) do
    case Enum.filter(sets, &String.starts_with?(value(&1, "id", ""), requested)) do
      [set] -> {:ok, value(set, "id")}
      [] -> {:error, :workspace_set_not_found}
      matches -> {:error, {:workspace_set_id_ambiguous, Enum.map(matches, &value(&1, "id"))}}
    end
  end

  defp format_list(workspaces, :json), do: CommandHelpers.encode_line(workspaces)
  defp format_list([], :human), do: "No workspaces.\n"

  defp format_list(workspaces, :human) do
    header = "ID\tSTATE\tSOURCE\tREPOSITORY\n"

    rows =
      Enum.map_join(workspaces, "", fn workspace ->
        "#{value(workspace, "id")}\t#{value(workspace, "state")}\t#{value(workspace, "source_mode")}\t#{value(workspace, "repository")}\n"
      end)

    header <> rows
  end

  defp format_set_list(sets, :json), do: CommandHelpers.encode_line(sets)
  defp format_set_list([], :human), do: "No workspace sets.\n"

  defp format_set_list(sets, :human) do
    header = "ID\tSTATE\tREPOSITORIES\n"

    rows =
      Enum.map_join(sets, "", fn set ->
        state = if value(set, "finalized_at"), do: "finalized", else: "active"
        repositories = set |> value("repositories", %{}) |> map_size()
        "#{value(set, "id")}\t#{state}\t#{repositories}\n"
      end)

    header <> rows
  end

  defp format_set_show(set, :json), do: CommandHelpers.encode_line(set)

  defp format_set_show(set, :human) do
    state = if value(set, "finalized_at"), do: "finalized", else: "active"

    repositories =
      set
      |> value("repositories", %{})
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("", fn {name, workspace} ->
        output = value(workspace, "head_commit", "pending") || "pending"

        "  #{name}: #{value(workspace, "base_commit")} -> #{output} (#{value(workspace, "id")})\n"
      end)

    "Workspace set: #{value(set, "id")}\nState: #{state}\nOwner: #{value(set, "owner_session_id")}\nRepositories:\n#{repositories}"
  end

  defp format(_action, result, :json), do: CommandHelpers.encode_line(result)
  defp format(:path, result, :human), do: value(result, "path", "") <> "\n"

  defp format(:status, result, :human) do
    outcomes = value(value(result, "result_manifest", %{}), "outcomes", %{})

    """
    Workspace: #{value(result, "id")}
    State: #{value(result, "state")}
    Epoch: #{value(result, "control_epoch")}
    Source: #{value(result, "source_mode")}@#{value(result, "base_commit")}
    Agent: #{value(outcomes, "agent_execution", "not_run")}
    Capture: #{value(outcomes, "result_capture", "not_run")}
    Integrity: #{value(outcomes, "artifact_integrity", "not_run")}
    Tests: #{value(outcomes, "test_verification", "not_run")}
    Policy: #{value(outcomes, "policy_compliance", "not_run")}
    """
  end

  defp format(:diff, result, :human) do
    patch = value(result, "patch", %{})

    case value(patch, "encoding") do
      "utf-8" -> value(patch, "data", "")
      "base64" -> "Binary patch (base64):\n" <> value(patch, "data", "") <> "\n"
      _other -> ""
    end
  end

  defp format(:cleanup, result, :human) do
    if value(result, "dry_run", true) do
      "Cleanup plan for #{value(result, "workspace_id")}: #{value(result, "entries")} entries, #{value(result, "bytes")} bytes. Re-run with --write --yes --expected-epoch #{value(result, "expected_epoch")}.\n"
    else
      "Workspace #{value(result, "workspace_id")} removed. Artifacts retained.\n"
    end
  end

  defp format(:export, result, :human) do
    "Exported #{value(result, "workspace_id")} to #{value(result, "destination")} (#{value(result, "patch_bytes")} patch bytes).\n"
  end

  defp format(:apply, result, :human) do
    if value(result, "dry_run", true) do
      target_flag =
        if value(result, "target") == "current-worktree",
          do: " --target current-worktree",
          else: ""

      "Apply check passed for #{value(result, "workspace_id")} (#{value(result, "target")}). Result tree: #{value(result, "result_tree")}. Re-run with --write --yes --expected-epoch #{value(result, "expected_epoch")}#{target_flag}.\n"
    else
      if value(result, "target") == "current-worktree" do
        "Applied verified result to current worktree: #{value(result, "path")}\nResult tree: #{value(result, "verified_result_tree")}\nRecovery backup: #{value(result, "backup_path")} (retained until #{value(result, "backup_expires_at")})\n"
      else
        "Verified review worktree: #{value(result, "path")}\nResult tree: #{value(result, "verified_result_tree")}\nSource worktree unchanged; Git common metadata is shared.\n"
      end
    end
  end

  defp format(:reconcile, result, :human) do
    if value(result, "dry_run", true) do
      commands = value(result, "recovery_commands", []) |> Enum.join("\n  ")
      restoration = value(result, "restoration", %{})
      export_resume = value(result, "export_resume", %{})
      cleanup_resume = value(result, "cleanup_resume", %{})
      review_discard = value(result, "review_discard", %{})

      restore =
        if value(restoration, "available", false),
          do: "\nValidated backup restore: #{value(restoration, "command")}",
          else: ""

      resume =
        if value(export_resume, "available", false),
          do: "\nVerified export resume: #{value(export_resume, "command")}",
          else: ""

      cleanup =
        if value(cleanup_resume, "available", false),
          do: "\nVerified cleanup resume: #{value(cleanup_resume, "command")}",
          else: ""

      discard =
        if value(review_discard, "available", false),
          do: "\nVerified review discard: #{value(review_discard, "command")}",
          else: ""

      "Reconciliation required for #{value(result, "workspace_id")} after #{value(result, "interrupted_kind")} (#{value(result, "interrupted_request_id")}).\nEvidence-preserving commands:\n  #{commands}#{restore}#{resume}#{cleanup}#{discard}\nTo record quarantine: twelvgaige workspace reconcile #{value(result, "workspace_id")} --write --yes --expected-epoch #{value(result, "expected_epoch")} --action quarantine\n"
    else
      case value(result, "action") do
        action when action in ["restore_backup", :restore_backup] ->
          "Workspace #{value(result, "workspace_id")} restored from its validated backup and returned to reviewable state.\n"

        action when action in ["resume_export", :resume_export] ->
          "Workspace #{value(result, "workspace_id")} resumed and verified its interrupted export.\n"

        action when action in ["resume_cleanup", :resume_cleanup] ->
          "Workspace #{value(result, "workspace_id")} resumed its interrupted cleanup and is durably deleted.\n"

        action when action in ["discard_review", :discard_review] ->
          "Workspace #{value(result, "workspace_id")} discarded the unchanged interrupted review worktree and returned to reviewable state.\n"

        _action ->
          "Workspace #{value(result, "workspace_id")} reconciled as quarantined. Evidence and external changes were preserved.\n"
      end
    end
  end

  defp format(:review_cleanup, result, :human) do
    if value(result, "dry_run", true) do
      "Review cleanup check passed for #{value(result, "workspace_id")}: #{value(result, "review_path")}. Re-run with --write --yes --expected-epoch #{value(result, "expected_epoch")}.\n"
    else
      "Removed verified review worktree #{value(result, "review_path")}. The result artifact remains retained.\n"
    end
  end

  defp format(:show, result, :human) do
    """
    Workspace: #{value(result, "id")}
    State: #{value(result, "state")}
    Repository: #{value(result, "repository")}
    Path: #{value(result, "path")}
    Base: #{value(result, "base_commit")}
    Result: #{value(result, "head_commit", "not finalized")}
    Epoch: #{value(result, "control_epoch")}
    """
  end

  defp format_retention(_action, result, :json), do: CommandHelpers.encode_line(result)

  defp format_retention(:status, result, :human) do
    expired = length(value(result, "expired_workspaces", []))
    suggestion = if expired > 0, do: "\nNext: twelvgaige workspace retention run", else: ""

    "Workspace retention: #{value(result, "workspace_retention_days")} days; expired now: #{expired}; last run: #{value(result, "last_run", "never")}#{suggestion}\n"
  end

  defp format_retention(:run, result, :human) do
    "Workspace retention sweep complete: #{length(value(result, "removed", []))} removed, #{length(value(result, "failures", []))} retained for review.\n"
  end

  defp error(reason, args) do
    format = if("json" in args, do: :json, else: :human)
    {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end
end
