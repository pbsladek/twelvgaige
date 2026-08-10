defmodule Twelvgaige.CLI.Dispatcher do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.Audit, as: AuditCommand
  alias Twelvgaige.CLI.Commands.Crypto, as: CryptoCommand
  alias Twelvgaige.CLI.Commands.Daemon, as: DaemonCommand
  alias Twelvgaige.CLI.Commands.Operations, as: OperationsCommand
  alias Twelvgaige.CLI.Commands.Round, as: RoundCommand
  alias Twelvgaige.CLI.Commands.RoundControl, as: RoundControlCommand
  alias Twelvgaige.CLI.Commands.SandboxSetup, as: SandboxSetupCommand
  alias Twelvgaige.CLI.Commands.ScaffoldLibrary, as: ScaffoldLibraryCommand
  alias Twelvgaige.CLI.Commands.SessionStart, as: SessionStartCommand
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
  alias Twelvgaige.CLI.Commands.Store, as: StoreCommand
  alias Twelvgaige.CLI.Usage

  def dispatch(["daemon", "serve" | args]), do: DaemonCommand.serve(args)

  def dispatch(["round", "watch", round_id | args]),
    do: RoundCommand.stream_watch(round_id, args, &IO.write/1)

  def dispatch(args) do
    args
    |> run()
    |> emit()
  end

  @spec run([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def run(["--help"]), do: {:ok, Usage.text(), 0}
  def run(["-h"]), do: {:ok, Usage.text(), 0}
  def run(["version"]), do: {:ok, Twelvgaige.version() <> "\n", 0}
  def run(["status"]), do: StatusCommand.run(format: :human)
  def run(["status", "--format", format]), do: StatusCommand.run(format: parse_format(format))
  def run(["crypto", "status"]), do: CryptoCommand.status(format: :human)

  def run(["crypto", "status", "--format", format]),
    do: CryptoCommand.status(format: parse_format(format))

  def run(["crypto", "sqlcipher-spike" | args]), do: CryptoCommand.sqlcipher_spike(args)

  def run(["store", "backup", destination | args]), do: StoreCommand.backup(destination, args)

  def run(["store", "restore", source, destination | args]),
    do: StoreCommand.restore(source, destination, args)

  def run(["store", "migrate-sqlcipher" | args]), do: StoreCommand.migrate_sqlcipher(args)
  def run(["store", "rewrap-envelope", path | args]), do: StoreCommand.rewrap_envelope(path, args)

  def run(["audit", "verify", path | args]), do: AuditCommand.verify_checkpoint(path, args)
  def run(["daemon", "paths" | args]), do: DaemonCommand.paths(args)
  def run(["daemon", "stop" | args]), do: DaemonCommand.stop(args)
  def run(["daemon", "token", "rotate" | args]), do: OperationsCommand.rotate_token(args)
  def run(["session", "start" | args]), do: SessionStartCommand.run(args)
  def run(["session", "list" | args]), do: OperationsCommand.session_list(args)

  def run(["session", "show", session_id | args]),
    do: OperationsCommand.session_show(session_id, args)

  def run(["session", "attach", session_id | args]),
    do: OperationsCommand.session_attach(session_id, args)

  def run(["session", "takeover", session_id | args]),
    do: OperationsCommand.session_takeover(session_id, args)

  def run(["session", "revoke", session_id | args]),
    do: OperationsCommand.session_revoke(session_id, args)

  def run(["sandbox", "health" | args]), do: OperationsCommand.sandbox_health(args)
  def run(["sandbox", "setup" | args]), do: SandboxSetupCommand.run(args)
  def run(["sandbox", "reconcile" | args]), do: OperationsCommand.sandbox_reconcile(args)
  def run(["operations", "dashboard" | args]), do: OperationsCommand.dashboard(args)

  def run(["operations", "audit", "status" | args]),
    do: OperationsCommand.audit_status(args)

  def run(["operations", "audit", "checkpoint" | args]),
    do: OperationsCommand.audit_checkpoint(args)

  def run(["operations", "audit", "export", destination | args]),
    do: OperationsCommand.audit_export(destination, args)

  def run(["operations", "store", "stats" | args]), do: OperationsCommand.store_stats(args)

  def run(["operations", "store", "backup", destination | args]),
    do: OperationsCommand.store_backup(destination, args)

  def run(["operations", "store", "restore", source, destination | args]),
    do: OperationsCommand.store_restore(source, destination, args)

  def run(["operations", "retention", "status" | args]),
    do: OperationsCommand.retention_status(args)

  def run(["operations", "retention", "run" | args]),
    do: OperationsCommand.retention_run(args)

  def run(["operations", "artifact", "inventory" | args]),
    do: OperationsCommand.artifact_inventory(args)

  def run(["operations", "artifact", "rotate" | args]),
    do: OperationsCommand.artifact_rotate(args)

  def run(["operations", "release", "check" | args]),
    do: OperationsCommand.release_check(args)

  def run(["shell", "validate", path]), do: ShellCacheCommand.validate(path, format: :human)

  def run(["shell", "validate", path, "--format", format]),
    do: ShellCacheCommand.validate(path, format: parse_format(format))

  def run(["shell", "new", id | args]), do: ShellCreateCommand.new(id, args)
  def run(["shell", "scaffold", "list" | args]), do: ScaffoldLibraryCommand.list(args)

  def run(["shell", "scaffold", "show", scaffold_id | args]),
    do: ScaffoldLibraryCommand.show(scaffold_id, args)

  def run(["shell", "scaffold", "verify" | args]), do: ScaffoldLibraryCommand.verify(args)
  def run(["shell", "scaffold", "update" | args]), do: ScaffoldLibraryCommand.update(args)

  def run(["shell", "scaffold", "outdated", path | args]),
    do: ScaffoldLibraryCommand.outdated(path, args)

  def run(["shell", "author", "review", path | args]), do: ShellAuthorCommand.review(path, args)

  def run(["shell", "patch", "inspect", path | args]),
    do: ShellPatchCommand.inspect_file(path, args)

  def run(["shell", "patch", "verify", path | args]), do: ShellPatchCommand.verify(path, args)
  def run(["shell", "patch", "apply", path | args]), do: ShellPatchCommand.apply(path, args)

  def run(["shell", "draft" | args]), do: ShellCreateCommand.draft(args)
  def run(["shell", "normalize", path | args]), do: ShellOpsCommand.normalize(path, args)
  def run(["shell", "convert", path | args]), do: ShellOpsCommand.convert(path, args)
  def run(["shell", "fmt", path | args]), do: ShellOpsCommand.fmt(path, args)
  def run(["shell", "graph", path | args]), do: ShellOpsCommand.graph(path, args)
  def run(["shell", "lint", path | args]), do: ShellOpsCommand.lint(path, args)
  def run(["shell", "admit", path | args]), do: ShellOpsCommand.admit(path, args)
  def run(["shell", "doctor", path | args]), do: ShellOpsCommand.doctor(path, args)
  def run(["shell", "inventory", path | args]), do: ShellReportsCommand.inventory(path, args)
  def run(["shell", "impact", path | args]), do: ShellReportsCommand.impact(path, args)
  def run(["shell", "reload" | args]), do: ShellCacheCommand.reload(args)
  def run(["shell", "list" | args]), do: ShellCacheCommand.list(args)
  def run(["shell", "show", shell_id | args]), do: ShellCacheCommand.show(shell_id, args)

  def run(["shell", "review", path | args]),
    do: ShellLifecycleCommand.lifecycle(:review, path, args)

  def run(["shell", "approve", path | args]),
    do: ShellLifecycleCommand.lifecycle(:approve, path, args)

  def run(["shell", "deprecate", path | args]),
    do: ShellLifecycleCommand.lifecycle(:deprecate, path, args)

  def run(["shell", "retire", path | args]),
    do: ShellLifecycleCommand.lifecycle(:retire, path, args)

  def run(["shell", "metadata", "set", path | args]),
    do: ShellLifecycleCommand.metadata_set(path, args)

  def run(["shell", "metadata", "clear", path | args]),
    do: ShellLifecycleCommand.metadata_clear(path, args)

  def run(["shell", "bulk", "replace-agent", path, old_agent, new_agent | args]),
    do: ShellBulkCommand.replace_agent(path, old_agent, new_agent, args)

  def run(["shell", "bulk", "replace-tool", path, old_tool, new_tool | args]),
    do: ShellBulkCommand.replace_tool(path, old_tool, new_tool, args)

  def run(["shot", "library", "list" | args]), do: ShotLibraryCommand.list(args)

  def run(["shot", "library", "show", template_id | args]),
    do: ShotLibraryCommand.show(template_id, args)

  def run(["shot", "library", "verify" | args]), do: ShotLibraryCommand.verify(args)
  def run(["shot", "library", "update" | args]), do: ShotLibraryCommand.update(args)

  def run(["shot", "library", "outdated", path | args]),
    do: ShotLibraryCommand.outdated(path, args)

  def run(["shot", "add", path, shot_id | args]),
    do: ShotRefactorCommand.add(path, shot_id, args)

  def run(["shot", "split", path, shot_id | args]),
    do: ShotRefactorCommand.split(path, shot_id, args)

  def run(["shot", "merge", path | args]), do: ShotRefactorCommand.merge(path, args)

  def run(["shot", "gate", path, target_id | args]),
    do: ShotRefactorCommand.gate(path, target_id, args)

  def run(["shot", "schema", "set", path, shot_id, schema_path | args]),
    do: ShotRefactorCommand.set_schema(path, shot_id, schema_path, args)

  def run(["shot", "replace-agent", path, old_agent, new_agent | args]),
    do: ShotRefactorCommand.replace_agent(path, old_agent, new_agent, args)

  def run(["shot", "replace-tool", path, old_tool, new_tool | args]),
    do: ShotRefactorCommand.replace_tool(path, old_tool, new_tool, args)

  def run(["shot", "rename", path, old_id, new_id | args]),
    do: ShotRefactorCommand.rename(path, old_id, new_id, args)

  def run(["shot", "move", path, shot_id | args]),
    do: ShotRefactorCommand.move(path, shot_id, args)

  def run(["shot", "remove", path, shot_id | args]),
    do: ShotRefactorCommand.remove(path, shot_id, args)

  def run(["round", "run", path | args]), do: RoundCommand.run(path, args)
  def run(["round", "list" | args]), do: RoundCommand.list(args)
  def run(["round", "show", round_id | args]), do: RoundCommand.show(round_id, args)
  def run(["round", "watch", round_id | args]), do: RoundCommand.watch(round_id, args)
  def run(["round", "audit", round_id | args]), do: AuditCommand.round(round_id, args)

  def run(["round", "approve", round_id | args]),
    do: RoundControlCommand.safety_decision(:approve, round_id, args)

  def run(["round", "reject", round_id | args]),
    do: RoundControlCommand.safety_decision(:reject, round_id, args)

  def run(["round", "cancel", round_id | args]), do: RoundControlCommand.cancel(round_id, args)
  def run([]), do: {:ok, Usage.text(), 0}

  def run([command | _]) do
    {:ok, "unknown command: #{command}\n\n" <> Usage.text(), 4}
  end

  defp emit({:ok, output, 0}) do
    IO.write(output)
    :ok
  end

  defp emit({:ok, output, code}) do
    IO.write(:stderr, output)
    System.halt(code)
  end

  defp parse_format("json"), do: :json
  defp parse_format("human"), do: :human
  defp parse_format(_other), do: :human
end
