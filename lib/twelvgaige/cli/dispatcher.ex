defmodule Twelvgaige.CLI.Dispatcher do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.Audit, as: AuditCommand
  alias Twelvgaige.CLI.Commands.Crypto, as: CryptoCommand
  alias Twelvgaige.CLI.Commands.Completion, as: CompletionCommand
  alias Twelvgaige.CLI.Commands.Daemon, as: DaemonCommand
  alias Twelvgaige.CLI.Commands.Developer, as: DeveloperCommand
  alias Twelvgaige.CLI.Commands.Operations, as: OperationsCommand
  alias Twelvgaige.CLI.Commands.Repository, as: RepositoryCommand
  alias Twelvgaige.CLI.Commands.Round, as: RoundCommand
  alias Twelvgaige.CLI.Commands.RoundControl, as: RoundControlCommand
  alias Twelvgaige.CLI.Commands.SandboxSetup, as: SandboxSetupCommand
  alias Twelvgaige.CLI.Commands.ScaffoldLibrary, as: ScaffoldLibraryCommand
  alias Twelvgaige.CLI.Commands.SessionStart, as: SessionStartCommand
  alias Twelvgaige.CLI.Commands.SessionPlan, as: SessionPlanCommand
  alias Twelvgaige.CLI.Commands.SessionFollow, as: SessionFollowCommand
  alias Twelvgaige.CLI.Commands.SessionReview, as: SessionReviewCommand
  alias Twelvgaige.CLI.Commands.SessionRetry, as: SessionRetryCommand
  alias Twelvgaige.CLI.Commands.SessionResult, as: SessionResultCommand
  alias Twelvgaige.CLI.Commands.ShellAuthor, as: ShellAuthorCommand
  alias Twelvgaige.CLI.Commands.ShellBulk, as: ShellBulkCommand
  alias Twelvgaige.CLI.Commands.ShellCache, as: ShellCacheCommand
  alias Twelvgaige.CLI.Commands.ShellCreate, as: ShellCreateCommand
  alias Twelvgaige.CLI.Commands.ShellLifecycle, as: ShellLifecycleCommand
  alias Twelvgaige.CLI.Commands.ShellOps, as: ShellOpsCommand
  alias Twelvgaige.CLI.Commands.ShellPatch, as: ShellPatchCommand
  alias Twelvgaige.CLI.Commands.ShellReports, as: ShellReportsCommand
  alias Twelvgaige.CLI.Commands.ShotLibrary, as: ShotLibraryCommand
  alias Twelvgaige.CLI.Commands.ShotRefactor, as: ShotRefactorCommand
  alias Twelvgaige.CLI.Commands.Status, as: StatusCommand
  alias Twelvgaige.CLI.Commands.Support, as: SupportCommand
  alias Twelvgaige.CLI.Commands.Store, as: StoreCommand
  alias Twelvgaige.CLI.Commands.TaskValidate, as: TaskValidateCommand
  alias Twelvgaige.CLI.Commands.Workspace, as: WorkspaceCommand
  alias Twelvgaige.CLI.CommandSpec
  alias Twelvgaige.CLI.CommandHelpers
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.CLI.ResultEnvelope
  alias Twelvgaige.CLI.Usage
  alias Twelvgaige.Error

  def dispatch(args) do
    started_at = System.monotonic_time(:millisecond)

    case parse_global(args) do
      {:ok, command_args, global} ->
        put_global(global)
        verbose_start(command_args, global)
        emit_deprecation_warnings(command_args)

        try do
          result = validated_dispatch(command_args, global)
          verbose_finish(result, started_at, global)
          result
        after
          clear_global()
        end

      {:error, reason} ->
        reason |> global_error() |> ResultEnvelope.wrap(args) |> emit(args)
    end
  end

  @spec run([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def run(args) do
    case parse_global(args) do
      {:ok, command_args, global} ->
        put_global(global)

        try do
          command_args
          |> validated_route()
          |> apply_global_output(command_args, global)
        after
          clear_global()
        end

      {:error, reason} ->
        reason |> global_error() |> ResultEnvelope.wrap(args)
    end
  end

  defp route(["--help"]), do: {:ok, Usage.text(), 0}
  defp route(["-h"]), do: {:ok, Usage.text(), 0}
  defp route(["version"]), do: {:ok, Twelvgaige.version() <> "\n", 0}
  defp route(["completion" | args]), do: CompletionCommand.run(args)
  defp route(["init" | args]), do: DeveloperCommand.init(args)
  defp route(["doctor" | args]), do: DeveloperCommand.doctor(args)
  defp route(["support", "bundle" | args]), do: SupportCommand.bundle(args)
  defp route(["status"]), do: StatusCommand.run(format: :human)
  defp route(["status", "--format", format]), do: StatusCommand.run(format: parse_format(format))
  defp route(["crypto", "status"]), do: CryptoCommand.status(format: :human)

  defp route(["crypto", "status", "--format", format]),
    do: CryptoCommand.status(format: parse_format(format))

  defp route(["crypto", "sqlcipher-spike" | args]), do: CryptoCommand.sqlcipher_spike(args)

  defp route(["store", "backup", destination | args]), do: StoreCommand.backup(destination, args)

  defp route(["store", "restore", source, destination | args]),
    do: StoreCommand.restore(source, destination, args)

  defp route(["store", "migrate-sqlcipher" | args]), do: StoreCommand.migrate_sqlcipher(args)

  defp route(["store", "rewrap-envelope", path | args]),
    do: StoreCommand.rewrap_envelope(path, args)

  defp route(["audit", "verify", path | args]), do: AuditCommand.verify_checkpoint(path, args)
  defp route(["daemon", "paths" | args]), do: DaemonCommand.paths(args)
  defp route(["daemon", "stop" | args]), do: DaemonCommand.stop(args)
  defp route(["daemon", "token", "rotate" | args]), do: OperationsCommand.rotate_token(args)
  defp route(["repo", "inspect" | args]), do: RepositoryCommand.inspect(args)
  defp route(["workspace", "list" | args]), do: WorkspaceCommand.list(args)

  defp route(["workspace", "set", "list" | args]),
    do: WorkspaceCommand.set(:list, args, [])

  defp route(["workspace", "set", "show" | args]),
    do: WorkspaceCommand.set(:show, args, [])

  defp route(["workspace", "review", "cleanup", workspace_id | args]),
    do: WorkspaceCommand.show(:review_cleanup, workspace_id, args)

  defp route(["workspace", "retention", "status" | args]),
    do: WorkspaceCommand.retention(:status, args)

  defp route(["workspace", "retention", "run" | args]),
    do: WorkspaceCommand.retention(:run, args)

  defp route(["workspace", action, workspace_id | args])
       when action in [
              "show",
              "path",
              "status",
              "diff",
              "cleanup",
              "export",
              "apply",
              "reconcile"
            ] do
    WorkspaceCommand.show(String.to_existing_atom(action), workspace_id, args)
  end

  defp route(["session", "start" | args]), do: SessionStartCommand.run(args)
  defp route(["session", "plan" | args]), do: SessionPlanCommand.run(args)

  defp route(["session", "watch", session_id | args]),
    do: SessionFollowCommand.run(session_id, args)

  defp route(["session", "review", session_id | args]),
    do: SessionReviewCommand.run(session_id, args)

  defp route(["session", "retry", session_id | args]),
    do: SessionRetryCommand.run(session_id, args)

  defp route(["session", "export", session_id | args]),
    do: SessionResultCommand.export(session_id, args)

  defp route(["session", "apply", session_id | args]),
    do: SessionResultCommand.apply(session_id, args)

  defp route(["task", "validate", path | args]), do: TaskValidateCommand.run(path, args)
  defp route(["session", "list" | args]), do: OperationsCommand.session_list(args)

  defp route(["session", "show", session_id | args]),
    do: OperationsCommand.session_show(session_id, args)

  defp route(["session", "attach", session_id | args]),
    do: OperationsCommand.session_attach(session_id, args)

  defp route(["session", "takeover", session_id | args]),
    do: OperationsCommand.session_takeover(session_id, args)

  defp route(["session", "revoke", session_id | args]),
    do: OperationsCommand.session_revoke(session_id, args)

  defp route(["session", "cancel", session_id | args]),
    do: OperationsCommand.session_cancel(session_id, args)

  defp route(["sandbox", "health" | args]), do: OperationsCommand.sandbox_health(args)
  defp route(["sandbox", "setup" | args]), do: SandboxSetupCommand.run(args)
  defp route(["sandbox", "reconcile" | args]), do: OperationsCommand.sandbox_reconcile(args)

  defp route(["operation", "show", request_id | args]),
    do: OperationsCommand.operation_show(request_id, args)

  defp route(["operations", "dashboard" | args]), do: OperationsCommand.dashboard(args)

  defp route(["operations", "audit", "status" | args]),
    do: OperationsCommand.audit_status(args)

  defp route(["operations", "audit", "checkpoint" | args]),
    do: OperationsCommand.audit_checkpoint(args)

  defp route(["operations", "audit", "export", destination | args]),
    do: OperationsCommand.audit_export(destination, args)

  defp route(["operations", "store", "stats" | args]), do: OperationsCommand.store_stats(args)

  defp route(["operations", "store", "backup", destination | args]),
    do: OperationsCommand.store_backup(destination, args)

  defp route(["operations", "store", "restore", source, destination | args]),
    do: OperationsCommand.store_restore(source, destination, args)

  defp route(["operations", "retention", "status" | args]),
    do: OperationsCommand.retention_status(args)

  defp route(["operations", "retention", "run" | args]),
    do: OperationsCommand.retention_run(args)

  defp route(["operations", "artifact", "inventory" | args]),
    do: OperationsCommand.artifact_inventory(args)

  defp route(["operations", "artifact", "rotate" | args]),
    do: OperationsCommand.artifact_rotate(args)

  defp route(["operations", "release", "check" | args]),
    do: OperationsCommand.release_check(args)

  defp route(["shell", "validate", path]), do: ShellCacheCommand.validate(path, format: :human)

  defp route(["shell", "validate", path, "--format", format]),
    do: ShellCacheCommand.validate(path, format: parse_format(format))

  defp route(["shell", "new", id | args]), do: ShellCreateCommand.new(id, args)
  defp route(["shell", "scaffold", "list" | args]), do: ScaffoldLibraryCommand.list(args)

  defp route(["shell", "scaffold", "show", scaffold_id | args]),
    do: ScaffoldLibraryCommand.show(scaffold_id, args)

  defp route(["shell", "scaffold", "verify" | args]), do: ScaffoldLibraryCommand.verify(args)
  defp route(["shell", "scaffold", "update" | args]), do: ScaffoldLibraryCommand.update(args)

  defp route(["shell", "scaffold", "outdated", path | args]),
    do: ScaffoldLibraryCommand.outdated(path, args)

  defp route(["shell", "author", "review", path | args]),
    do: ShellAuthorCommand.review(path, args)

  defp route(["shell", "patch", "inspect", path | args]),
    do: ShellPatchCommand.inspect_file(path, args)

  defp route(["shell", "patch", "verify", path | args]), do: ShellPatchCommand.verify(path, args)
  defp route(["shell", "patch", "apply", path | args]), do: ShellPatchCommand.apply(path, args)

  defp route(["shell", "draft" | args]), do: ShellCreateCommand.draft(args)
  defp route(["shell", "normalize", path | args]), do: ShellOpsCommand.normalize(path, args)
  defp route(["shell", "convert", path | args]), do: ShellOpsCommand.convert(path, args)
  defp route(["shell", "fmt", path | args]), do: ShellOpsCommand.fmt(path, args)
  defp route(["shell", "graph", path | args]), do: ShellOpsCommand.graph(path, args)
  defp route(["shell", "lint", path | args]), do: ShellOpsCommand.lint(path, args)
  defp route(["shell", "admit", path | args]), do: ShellOpsCommand.admit(path, args)
  defp route(["shell", "doctor", path | args]), do: ShellOpsCommand.doctor(path, args)
  defp route(["shell", "inventory", path | args]), do: ShellReportsCommand.inventory(path, args)
  defp route(["shell", "impact", path | args]), do: ShellReportsCommand.impact(path, args)
  defp route(["shell", "reload" | args]), do: ShellCacheCommand.reload(args)
  defp route(["shell", "list" | args]), do: ShellCacheCommand.list(args)
  defp route(["shell", "show", shell_id | args]), do: ShellCacheCommand.show(shell_id, args)

  defp route(["shell", "review", path | args]),
    do: ShellLifecycleCommand.lifecycle(:review, path, args)

  defp route(["shell", "approve", path | args]),
    do: ShellLifecycleCommand.lifecycle(:approve, path, args)

  defp route(["shell", "deprecate", path | args]),
    do: ShellLifecycleCommand.lifecycle(:deprecate, path, args)

  defp route(["shell", "retire", path | args]),
    do: ShellLifecycleCommand.lifecycle(:retire, path, args)

  defp route(["shell", "metadata", "set", path | args]),
    do: ShellLifecycleCommand.metadata_set(path, args)

  defp route(["shell", "metadata", "clear", path | args]),
    do: ShellLifecycleCommand.metadata_clear(path, args)

  defp route(["shell", "bulk", "replace-agent", path, old_agent, new_agent | args]),
    do: ShellBulkCommand.replace_agent(path, old_agent, new_agent, args)

  defp route(["shell", "bulk", "replace-tool", path, old_tool, new_tool | args]),
    do: ShellBulkCommand.replace_tool(path, old_tool, new_tool, args)

  defp route(["shot", "library", "list" | args]), do: ShotLibraryCommand.list(args)

  defp route(["shot", "library", "show", template_id | args]),
    do: ShotLibraryCommand.show(template_id, args)

  defp route(["shot", "library", "verify" | args]), do: ShotLibraryCommand.verify(args)
  defp route(["shot", "library", "update" | args]), do: ShotLibraryCommand.update(args)

  defp route(["shot", "library", "outdated", path | args]),
    do: ShotLibraryCommand.outdated(path, args)

  defp route(["shot", "add", path, shot_id | args]),
    do: ShotRefactorCommand.add(path, shot_id, args)

  defp route(["shot", "split", path, shot_id | args]),
    do: ShotRefactorCommand.split(path, shot_id, args)

  defp route(["shot", "merge", path | args]), do: ShotRefactorCommand.merge(path, args)

  defp route(["shot", "gate", path, target_id | args]),
    do: ShotRefactorCommand.gate(path, target_id, args)

  defp route(["shot", "schema", "set", path, shot_id, schema_path | args]),
    do: ShotRefactorCommand.set_schema(path, shot_id, schema_path, args)

  defp route(["shot", "replace-agent", path, old_agent, new_agent | args]),
    do: ShotRefactorCommand.replace_agent(path, old_agent, new_agent, args)

  defp route(["shot", "replace-tool", path, old_tool, new_tool | args]),
    do: ShotRefactorCommand.replace_tool(path, old_tool, new_tool, args)

  defp route(["shot", "rename", path, old_id, new_id | args]),
    do: ShotRefactorCommand.rename(path, old_id, new_id, args)

  defp route(["shot", "move", path, shot_id | args]),
    do: ShotRefactorCommand.move(path, shot_id, args)

  defp route(["shot", "remove", path, shot_id | args]),
    do: ShotRefactorCommand.remove(path, shot_id, args)

  defp route(["round", "run", path | args]), do: RoundCommand.run(path, args)
  defp route(["round", "list" | args]), do: RoundCommand.list(args)
  defp route(["round", "show", round_id | args]), do: RoundCommand.show(round_id, args)
  defp route(["round", "watch", round_id | args]), do: RoundCommand.watch(round_id, args)
  defp route(["round", "audit", round_id | args]), do: AuditCommand.round(round_id, args)

  defp route(["round", "approve", round_id | args]),
    do: RoundControlCommand.safety_decision(:approve, round_id, args)

  defp route(["round", "reject", round_id | args]),
    do: RoundControlCommand.safety_decision(:reject, round_id, args)

  defp route(["round", "cancel", round_id | args]), do: RoundControlCommand.cancel(round_id, args)
  defp route([]), do: {:ok, Usage.text(), 0}

  defp route([command | _]) do
    {:ok, "unknown command: #{command}\n\n" <> Usage.text(), 4}
  end

  defp dispatch_command(["daemon", "serve" | args], _global), do: DaemonCommand.serve(args)

  defp dispatch_command(["round", "watch", round_id | args] = command_args, _global) do
    if ResultEnvelope.requested_format(command_args) == :ndjson,
      do: stream_ndjson(round_id, args, command_args),
      else: stream_human(round_id, args)
  end

  defp dispatch_command(args, global) do
    args
    |> route()
    |> apply_global_output(args, global)
    |> emit(args)
  end

  defp validated_dispatch(args, global) do
    case CommandSpec.resolve(args) do
      {:ok, :root} ->
        dispatch_command(args, global)

      {:ok, spec} ->
        case CommandSpec.validate(spec, args) do
          :ok ->
            dispatch_command(args, global)

          {:error, reason} ->
            reason
            |> command_spec_error(args)
            |> apply_global_output(args, global)
            |> emit(args)
        end

      {:error, :unknown_command} ->
        args
        |> unknown_command()
        |> apply_global_output(args, global)
        |> emit(args)
    end
  end

  defp validated_route(args) do
    case CommandSpec.resolve(args) do
      {:ok, :root} ->
        route(args)

      {:ok, spec} ->
        case CommandSpec.validate(spec, args) do
          :ok -> route(args)
          {:error, reason} -> command_spec_error(reason, args)
        end

      {:error, :unknown_command} ->
        unknown_command(args)
    end
  end

  defp command_spec_error(reason, args) do
    error =
      Error.new(:input_error, :invalid_shell, command_spec_message(reason, args),
        details: %{validation: command_spec_details(reason)}
      )

    format =
      if ResultEnvelope.requested_format(args) in [:json, :ndjson], do: :json, else: :human

    {:ok, CommandHelpers.format_command_error(error, format), ExitCode.for_error(error)}
  end

  defp command_spec_message({:unknown_option, option}, _args), do: "unknown option #{option}"

  defp command_spec_message({:missing_option_value, option}, _args),
    do: "#{option} requires a value"

  defp command_spec_message(
         {:invalid_option_value, "--profile", value, expected},
         ["round", "run" | _rest]
       ) do
    "unsupported resource profile #{inspect(value)}; expected #{human_choices(expected)}"
  end

  defp command_spec_message({:invalid_option_value, option, value, expected}, _args)
       when is_list(expected) do
    "#{option} must be #{human_choices(expected)}; got #{inspect(value)}"
  end

  defp command_spec_message({:invalid_option_value, option, value, expected}, _args) do
    "#{option} must be #{expected}; got #{inspect(value)}"
  end

  defp command_spec_message({:required_option_missing, option}, args) do
    case command_path(args) do
      path when path in [~w(shot gate), ~w(shot merge), ~w(shot split)] ->
        "#{Enum.join(path, " ")} requires #{option}"

      _path ->
        "#{option} is required"
    end
  end

  defp command_spec_message({:option_conflict, "--check", "--write"}, _args),
    do: "use either --check or --write, not both"

  defp command_spec_message({:option_conflict, left, right}, _args),
    do: "#{left} and #{right} cannot be used together"

  defp command_spec_message(
         {:exactly_one_option_required, options},
         ["shot", "move" | rest]
       )
       when options == ~w(--after --before) do
    if "--before" in rest and "--after" in rest,
      do: "shot move accepts exactly one of --before or --after",
      else: "shot move requires --before or --after"
  end

  defp command_spec_message({:exactly_one_option_required, options}, _args),
    do: "exactly one of #{human_choices(options)} is required"

  defp command_spec_message({:option_requires, option, required}, _args),
    do: "#{option} requires #{required}"

  defp human_choices([value]), do: value
  defp human_choices([left, right]), do: "#{left} or #{right}"

  defp human_choices(values) do
    {last, leading} = List.pop_at(values, -1)
    Enum.join(leading, ", ") <> ", or " <> last
  end

  defp command_path(args) do
    case CommandSpec.resolve(args) do
      {:ok, %CommandSpec{path: path}} -> path
      _missing -> []
    end
  end

  defp command_spec_details({:invalid_option_value, option, value, expected}) do
    %{
      kind: "invalid_option_value",
      option: option,
      value: value,
      expected: expected
    }
  end

  defp command_spec_details({:option_conflict, left, right}) do
    %{kind: "option_conflict", options: [left, right]}
  end

  defp command_spec_details({:exactly_one_option_required, options}) do
    %{kind: "exactly_one_option_required", options: options}
  end

  defp command_spec_details({:option_requires, option, required}) do
    %{kind: "option_requires", option: option, required_option: required}
  end

  defp command_spec_details({kind, option}) when is_atom(kind),
    do: %{kind: Atom.to_string(kind), option: option}

  defp unknown_command([command | _]),
    do: {:ok, "unknown command: #{command}\n\n" <> Usage.text(), 4}

  defp parse_global(args),
    do: parse_global(args, %{color: :auto, quiet?: false, verbose?: false}, [])

  defp parse_global([], global, command), do: validate_global(global, Enum.reverse(command))

  # Completion transports already-tokenized command words. Preserve a word or
  # current prefix that happens to spell a global option instead of consuming
  # it as control for the completion subprocess itself.
  defp parse_global([name, value | rest], global, command)
       when name in ["--current", "--word"] do
    parse_global(rest, global, [value, name | command])
  end

  defp parse_global(["--quiet" | rest], global, command),
    do: parse_global(rest, %{global | quiet?: true}, command)

  defp parse_global(["--verbose" | rest], global, command),
    do: parse_global(rest, %{global | verbose?: true}, command)

  defp parse_global(["--no-color" | rest], global, command),
    do: parse_global(rest, %{global | color: :never}, command)

  defp parse_global(["--color", value | rest], global, command) do
    case color(value) do
      {:ok, mode} -> parse_global(rest, %{global | color: mode}, command)
      :error -> {:error, {:invalid_global_color, value}}
    end
  end

  defp parse_global(["--color=" <> value | rest], global, command) do
    case color(value) do
      {:ok, mode} -> parse_global(rest, %{global | color: mode}, command)
      :error -> {:error, {:invalid_global_color, value}}
    end
  end

  defp parse_global([arg | rest], global, command),
    do: parse_global(rest, global, [arg | command])

  defp validate_global(%{quiet?: true, verbose?: true}, _command),
    do: {:error, :quiet_verbose_conflict}

  defp validate_global(global, command), do: {:ok, command, global}

  defp color(value) do
    with {:ok, option} <- CommandSpec.global_option("--color"),
         {:enum, values} <- option.type,
         true <- value in values do
      {:ok, String.to_existing_atom(value)}
    else
      _invalid -> :error
    end
  end

  defp apply_global_output(result, args, global) do
    result
    |> apply_quiet_output(args, global)
    |> ResultEnvelope.wrap(args)
  end

  defp apply_quiet_output({:ok, output, 0}, args, %{quiet?: true}) do
    if ResultEnvelope.machine_format?(args), do: {:ok, output, 0}, else: {:ok, "", 0}
  end

  defp apply_quiet_output(result, _args, _global), do: result

  defp global_error(:quiet_verbose_conflict),
    do: {:ok, "error: --quiet and --verbose cannot be used together\n", 4}

  defp global_error({:invalid_global_color, value}),
    do: {:ok, "error: --color must be auto, always, or never; got #{inspect(value)}\n", 4}

  defp put_global(global), do: Process.put(:twelvgaige_cli_global, global)
  defp clear_global, do: Process.delete(:twelvgaige_cli_global)

  defp emit_deprecation_warnings(args) do
    Enum.each(CommandSpec.deprecations(args), fn alias_spec ->
      IO.write(
        :stderr,
        "warning: #{alias_spec.alias} is deprecated; use #{alias_spec.canonical}; " <>
          "it will be removed in #{alias_spec.remove_in}\n"
      )
    end)
  end

  defp verbose_start(args, %{verbose?: true, color: color}) do
    IO.write(
      :stderr,
      "[twelvgaige] command=#{command_name(args)} version=#{Twelvgaige.version()} color=#{color}\n"
    )
  end

  defp verbose_start(_args, _global), do: :ok

  defp verbose_finish(:ok, started_at, %{verbose?: true}) do
    elapsed = System.monotonic_time(:millisecond) - started_at
    IO.write(:stderr, "[twelvgaige] exit=0 elapsed_ms=#{elapsed}\n")
  end

  defp verbose_finish(_result, _started_at, _global), do: :ok

  defp command_name(args) do
    args
    |> Enum.reject(&String.starts_with?(&1, "-"))
    |> Enum.take(2)
    |> Enum.join(" ")
    |> case do
      "" -> "help"
      name -> name
    end
  end

  defp stream_ndjson(round_id, args, command_args) do
    counter = :atomics.new(1, [])
    command = ResultEnvelope.command(command_args)

    write = fn output ->
      output
      |> String.split("\n", trim: true)
      |> Enum.each(fn line ->
        index = :atomics.add_get(counter, 1, 1) - 1

        payload =
          case Jason.decode(line) do
            {:ok, payload} -> payload
            {:error, _reason} -> unstructured_stream_error(line)
          end

        IO.write(ResultEnvelope.encode_event(payload, command, index))
      end)

      :ok
    end

    case RoundCommand.stream_watch(round_id, args, write) do
      {:ok, _summary} ->
        IO.write(ResultEnvelope.encode_terminal(command, 0, :atomics.get(counter, 1)))
        :ok

      {:error, error} ->
        index = :atomics.add_get(counter, 1, 1) - 1
        IO.write(ResultEnvelope.encode_event(stream_error(error), command, index))
        code = ExitCode.for_error(error)
        IO.write(ResultEnvelope.encode_terminal(command, code, :atomics.get(counter, 1)))
        System.halt(code)
    end
  end

  defp stream_human(round_id, args) do
    case RoundCommand.stream_watch(round_id, args, &IO.write/1) do
      {:ok, _summary} ->
        :ok

      {:error, error} ->
        IO.write(:stderr, CommandHelpers.format_command_error(error, :human))
        System.halt(ExitCode.for_error(error))
    end
  end

  defp stream_error(error) do
    error
    |> CommandHelpers.format_command_error(:json)
    |> Jason.decode!()
  end

  defp unstructured_stream_error(output) do
    %{
      error: %{
        reason: "unstructured_command_output",
        message: output |> String.trim() |> String.slice(0, 2_048)
      }
    }
  end

  defp emit({:ok, output, 0}, _args) do
    IO.write(output)
    :ok
  end

  defp emit({:ok, output, code}, args) do
    if ResultEnvelope.requested_format(args) in [:json, :ndjson],
      do: IO.write(output),
      else: IO.write(:stderr, output)

    System.halt(code)
  end

  defp parse_format("json"), do: :json
  defp parse_format("human"), do: :human
  defp parse_format(_other), do: :human
end
