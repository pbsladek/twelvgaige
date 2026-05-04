defmodule Twelvgaige.CLI.Main do
  @moduledoc """
  Command-line entrypoint for Twelvgaige.
  """

  alias Twelvgaige.Breech.Daemon
  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.Breech.IPC.Server
  alias Twelvgaige.Authoring.AtomicFile
  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.Authoring.Patch, as: AuthoringPatch
  alias Twelvgaige.Authoring.Scaffold
  alias Twelvgaige.Authoring.ShellAuthorReview
  alias Twelvgaige.Authoring.ShellDraft
  alias Twelvgaige.Authoring.ShotLibrary
  alias Twelvgaige.Authoring.ShotRefactor
  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Round.Watch
  alias Twelvgaige.Shell
  alias Twelvgaige.Shell.Admission, as: ShellAdmission
  alias Twelvgaige.Shell.BulkRefactor, as: ShellBulkRefactor
  alias Twelvgaige.Shell.Document, as: ShellDocument
  alias Twelvgaige.Shell.Doctor, as: ShellDoctor
  alias Twelvgaige.Shell.Formatter, as: ShellFormatter
  alias Twelvgaige.Shell.Graph, as: ShellGraph
  alias Twelvgaige.Shell.Impact, as: ShellImpact
  alias Twelvgaige.Shell.Inventory, as: ShellInventory
  alias Twelvgaige.Shell.Lifecycle, as: ShellLifecycle
  alias Twelvgaige.Shell.Lint, as: ShellLint
  alias Twelvgaige.Shell.MetadataRefactor
  alias Twelvgaige.Shot

  @usage """
  twelvgaige - deterministic agent orchestration

  Usage:
    twelvgaige --help
    twelvgaige version
    twelvgaige status [--format human|json]
    twelvgaige crypto status [--format human|json]
    twelvgaige crypto sqlcipher-spike [--path <path>] [--key-env <env>] [--format human|json]
    twelvgaige store backup <destination-path> [--allow-plaintext-export] [--format human|json]
    twelvgaige store restore <source-path> <destination-path> [--replace] [--format human|json]
    twelvgaige store migrate-sqlcipher --source <plaintext.db> --destination <encrypted.db> --key-env <env> [--replace] [--format human|json]
    twelvgaige store rewrap-envelope <envelope.json> --backup <backup.json> --old-key-env <env> --new-key-env <env> [--format human|json]
    twelvgaige audit verify <checkpoint-path|-> [--hmac-env <env>] [--format human|json]
    twelvgaige daemon serve [--transport unix|tcp|npipe] [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige daemon stop [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige daemon paths [--transport unix|tcp|npipe] [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige shell validate <path> [--format human|json]
    twelvgaige shell new <id> [--scaffold single-shot|inspect-analyze-gate-fix-verify] [--scaffold-path <path>] [--format yaml|json|toml] [--output <path>] [--with-mock-agents] [--write] [--force] [--root <path>]
    twelvgaige shell scaffold list [--format human|json] [--root <path>] [--scaffold-path <path>]
    twelvgaige shell scaffold show <scaffold-id> [--format human|json] [--root <path>] [--scaffold-path <path>]
    twelvgaige shell scaffold verify [--write-lock] [--lockfile <path>] [--format human|json] [--root <path>] [--scaffold-path <path>]
    twelvgaige shell scaffold update [--write-lock] [--lockfile <path>] [--format human|json] [--root <path>] [--scaffold-path <path>]
    twelvgaige shell scaffold outdated <path> [--format human|json] [--root <path>] [--scaffold-path <path>]
    twelvgaige shell author review <path> [--provider mock|ollama|openai|anthropic|gemini] [--model <model>] [--allow-remote] [--max-input-bytes <bytes>] [--format human|json] [--root <path>]
    twelvgaige shell patch inspect <patch-file> [--root <path>] [--format human|json]
    twelvgaige shell patch verify <patch-file> [--approval <approval-file>] --root <path> [--format human|json]
    twelvgaige shell patch apply <patch-file> [--approval <approval-file>] --root <path> [--write] [--format human|json]
    twelvgaige shell draft --from <file|-> [--provider mock|ollama|openai|anthropic|gemini] [--model <model>] [--allow-remote] [--max-input-bytes <bytes>] [--format yaml|json|toml] [--output <path> --write] [--force] [--root <path>]
    twelvgaige shell normalize <path> [--format json|yaml|toml]
    twelvgaige shell convert <path> --to json|yaml|toml [--output <path>]
    twelvgaige shell fmt <path> [--check|--write] [--format human|json] [--root <path>]
    twelvgaige shell graph <path> [--format text|json|mermaid] [--root <path>]
    twelvgaige shell lint <path> [--strict] [--format human|json] [--root <path>]
    twelvgaige shell admit <path> [--policy manual|approved|scheduled|none] [--format human|json] [--root <path>]
    twelvgaige shell doctor <path> [--strict] [--format human|json] [--root <path>]
    twelvgaige shell inventory <dir> [--format human|json] [--root <path>] [--output <path>] [--force]
    twelvgaige shell impact <dir> (--agent <id>|--tool <name>|--template <id>) [--format human|json] [--root <path>] [--output <path>] [--force]
    twelvgaige shell reload [path ...] [--format human|json]
    twelvgaige shell list [--kind workflow|agent|all] [--format human|json]
    twelvgaige shell show <shell-id> [--kind workflow|agent] [--format human|json]
    twelvgaige shell review <path> --by <actor> [--scope <scope>] [--evidence-hash <sha256:...>] [--write] [--format human|json] [--root <path>]
    twelvgaige shell approve <path> --by <actor> --scope <scope> [--expires-at <timestamp>] [--evidence-hash <sha256:...>] [--write] [--format human|json] [--root <path>]
    twelvgaige shell deprecate <path> --by <actor> --reason <text> [--write] [--format human|json] [--root <path>]
    twelvgaige shell retire <path> --by <actor> --reason <text> [--write] [--format human|json] [--root <path>]
    twelvgaige shell metadata set <path> [--owner <owner>] [--lifecycle draft|reviewed|approved|scheduled|deprecated|retired] [--write] [--format human|json] [--root <path>]
    twelvgaige shell metadata clear <path> [--review] [--approval] [--write] [--format human|json] [--root <path>]
    twelvgaige shell bulk replace-agent <path> <old-agent-id> <new-agent-id> [--write --yes] [--format human|json] [--root <path>] [--output <path>] [--force]
    twelvgaige shell bulk replace-tool <path> <old-tool-name> <new-tool-name> [--write --yes] [--format human|json] [--root <path>] [--output <path>] [--force]
    twelvgaige shot add <workflow-shell-path> <shot-id> --kind slug|safety [--agent <agent-id>] [--prompt <text>] [--description <text>] [--depends-on <id,id>] [--tool <name>] [--before <target-shot-id>|--after <target-shot-id>] [--write] [--format human|json] [--root <path>]
    twelvgaige shot add <workflow-shell-path> <shot-id> --template <template-id> [--depends-on <id,id>] [--before <target-shot-id>|--after <target-shot-id>] [--write] [--format human|json] [--root <path>] [--library-path <path>]
    twelvgaige shot split <workflow-shell-path> <shot-id> --into <child-id,child-id,...> [--write] [--format human|json] [--root <path>]
    twelvgaige shot merge <workflow-shell-path> <source-shot-id> <source-shot-id> [more-source-shot-ids...] --id <merged-shot-id> [--write] [--format human|json] [--root <path>]
    twelvgaige shot gate <workflow-shell-path> <target-shot-id> --id <gate-shot-id> [--description <text>] [--prompt <text>] [--write] [--format human|json] [--root <path>]
    twelvgaige shot schema set <workflow-shell-path> <shot-id> <schema-json-path> [--write] [--format human|json] [--root <path>]
    twelvgaige shot replace-agent <workflow-shell-path> <old-agent-id> <new-agent-id> [--write] [--format human|json] [--root <path>]
    twelvgaige shot replace-tool <workflow-shell-path> <old-tool-name> <new-tool-name> [--write] [--format human|json] [--root <path>]
    twelvgaige shot library list [--format human|json] [--root <path>] [--library-path <path>]
    twelvgaige shot library show <template-id> [--format human|json] [--root <path>] [--library-path <path>]
    twelvgaige shot library verify [--write-lock] [--lockfile <path>] [--format human|json] [--root <path>] [--library-path <path>]
    twelvgaige shot library update [--write-lock] [--lockfile <path>] [--format human|json] [--root <path>] [--library-path <path>]
    twelvgaige shot library outdated <path> [--format human|json] [--root <path>] [--library-path <path>]
    twelvgaige shot rename <workflow-shell-path> <old-shot-id> <new-shot-id> [--write] [--format human|json] [--root <path>]
    twelvgaige shot move <workflow-shell-path> <shot-id> (--before <target-shot-id>|--after <target-shot-id>) [--write] [--format human|json] [--root <path>]
    twelvgaige shot remove <workflow-shell-path> <shot-id> [--cascade --yes] [--write] [--format human|json] [--root <path>]
    twelvgaige round run <workflow-shell-path-or-id> [--input <json-or-path>] [--agent-shell <path>] [--no-agent-discovery] [--untrusted-root] [--profile minimal|laptop|workstation|server] [--admission none|approved|scheduled] [--format human|json] [--approve-safety] [--detach]
    twelvgaige round list [--format human|json] [--status <status>]
    twelvgaige round show <round-id> [--format human|json]
    twelvgaige round watch <round-id> [--format human|ndjson] [--after-seq <seq>] [--limit <count>] [--follow] [--until-terminal] [--timeout-ms <ms>]
    twelvgaige round audit <round-id> [--format human|json|ndjson|checkpoint] [--after-seq <seq>] [--limit <count>] [--sign-hmac-env <env>]
    twelvgaige round approve <round-id> --shot <safety-shot-id> [--reason <text>] [--format human|json]
    twelvgaige round reject <round-id> --shot <safety-shot-id> [--reason <text>] [--format human|json]
    twelvgaige round cancel <round-id> [--reason <text>] [--format human|json]
  """

  @spec main([String.t()]) :: :ok
  def main(args) do
    start_runtime!()
    main_started(args)
  end

  @spec main_started([String.t()]) :: :ok
  def main_started(args) do
    dispatch(args)
  end

  defp dispatch(["daemon", "serve" | args]), do: serve_daemon(args)

  defp dispatch(["round", "watch", round_id | args]),
    do: stream_watch_round(round_id, args, &IO.write/1)

  defp dispatch(args) do
    args
    |> run()
    |> emit()
  end

  defp start_runtime! do
    with :ok <- prepare_escript_priv(),
         {:ok, _apps} <- Application.ensure_all_started(:twelvgaige) do
      :ok
    else
      {:error, reason} ->
        IO.write(:stderr, "failed to start twelvgaige: #{inspect(reason)}\n")
        System.halt(8)
    end
  end

  @escript_priv_files [
    ~c"exqlite/ebin/exqlite.app",
    ~c"exqlite/priv/sqlite3_nif.so",
    ~c"exqlite/priv/sqlite3_nif.dll",
    ~c"exqlite/priv/sqlite3_nif.dylib"
  ]

  defp prepare_escript_priv do
    script = :escript.script_name() |> List.to_string()

    if File.regular?(script) do
      extract_escript_priv(script)
    else
      :ok
    end
  end

  defp extract_escript_priv(script) do
    with {:ok, entries} <- :escript.extract(String.to_charlist(script), [:compile_source]),
         archive when is_binary(archive) <- Keyword.get(entries, :archive),
         {:ok, files} <- :zip.extract(archive, [:memory, {:file_list, @escript_priv_files}]) do
      root = Path.join(System.tmp_dir!(), "twelvgaige-escript-#{:os.getpid()}")
      Enum.each(files, &write_escript_priv_file(root, &1))
      :code.add_patha(root |> Path.join("exqlite/ebin") |> String.to_charlist())
      :ok
    else
      {:error, {:badarg, _}} -> :ok
      {:error, :bad_central_directory} -> :ok
      {:error, _reason} = error -> error
      nil -> :ok
      _other -> :ok
    end
  end

  defp write_escript_priv_file(root, {path, contents}) do
    path = List.to_string(path)
    destination = Path.join(root, path)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, contents)
  end

  @spec run([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def run(["--help"]), do: {:ok, @usage, 0}
  def run(["-h"]), do: {:ok, @usage, 0}
  def run(["version"]), do: {:ok, Twelvgaige.version() <> "\n", 0}
  def run(["status"]), do: status(format: :human)
  def run(["status", "--format", format]), do: status(format: parse_format(format))
  def run(["crypto", "status"]), do: crypto_status(format: :human)

  def run(["crypto", "status", "--format", format]),
    do: crypto_status(format: parse_format(format))

  def run(["crypto", "sqlcipher-spike" | args]), do: crypto_sqlcipher_spike(args)

  def run(["store", "backup", destination | args]), do: store_backup(destination, args)

  def run(["store", "restore", source, destination | args]),
    do: store_restore(source, destination, args)

  def run(["store", "migrate-sqlcipher" | args]), do: store_migrate_sqlcipher(args)
  def run(["store", "rewrap-envelope", path | args]), do: store_rewrap_envelope(path, args)

  def run(["audit", "verify", path | args]), do: verify_audit_checkpoint(path, args)
  def run(["daemon", "paths" | args]), do: daemon_paths(args)
  def run(["daemon", "stop" | args]), do: stop_daemon(args)
  def run(["shell", "validate", path]), do: validate_shell(path, format: :human)

  def run(["shell", "validate", path, "--format", format]),
    do: validate_shell(path, format: parse_format(format))

  def run(["shell", "new", id | args]), do: new_shell(id, args)
  def run(["shell", "scaffold", "list" | args]), do: list_scaffold_library(args)

  def run(["shell", "scaffold", "show", scaffold_id | args]),
    do: show_scaffold_library(scaffold_id, args)

  def run(["shell", "scaffold", "verify" | args]), do: verify_scaffold_library(args)
  def run(["shell", "scaffold", "update" | args]), do: update_scaffold_library(args)

  def run(["shell", "scaffold", "outdated", path | args]),
    do: outdated_scaffold_library(path, args)

  def run(["shell", "author", "review", path | args]), do: author_review_shell(path, args)
  def run(["shell", "patch", "inspect", path | args]), do: inspect_shell_patch(path, args)
  def run(["shell", "patch", "verify", path | args]), do: verify_shell_patch(path, args)
  def run(["shell", "patch", "apply", path | args]), do: apply_shell_patch(path, args)

  def run(["shell", "draft" | args]), do: draft_shell(args)
  def run(["shell", "normalize", path | args]), do: normalize_shell(path, args)
  def run(["shell", "convert", path | args]), do: convert_shell(path, args)
  def run(["shell", "fmt", path | args]), do: fmt_shell(path, args)
  def run(["shell", "graph", path | args]), do: graph_shell(path, args)
  def run(["shell", "lint", path | args]), do: lint_shell(path, args)
  def run(["shell", "admit", path | args]), do: admit_shell(path, args)
  def run(["shell", "doctor", path | args]), do: doctor_shell(path, args)
  def run(["shell", "inventory", path | args]), do: inventory_shell(path, args)
  def run(["shell", "impact", path | args]), do: impact_shell(path, args)
  def run(["shell", "reload" | args]), do: reload_shells(args)
  def run(["shell", "list" | args]), do: list_shells(args)
  def run(["shell", "show", shell_id | args]), do: show_shell(shell_id, args)
  def run(["shell", "review", path | args]), do: lifecycle_shell(:review, path, args)
  def run(["shell", "approve", path | args]), do: lifecycle_shell(:approve, path, args)
  def run(["shell", "deprecate", path | args]), do: lifecycle_shell(:deprecate, path, args)
  def run(["shell", "retire", path | args]), do: lifecycle_shell(:retire, path, args)
  def run(["shell", "metadata", "set", path | args]), do: metadata_set_shell(path, args)
  def run(["shell", "metadata", "clear", path | args]), do: metadata_clear_shell(path, args)

  def run(["shell", "bulk", "replace-agent", path, old_agent, new_agent | args]),
    do: bulk_replace_agent_shell(path, old_agent, new_agent, args)

  def run(["shell", "bulk", "replace-tool", path, old_tool, new_tool | args]),
    do: bulk_replace_tool_shell(path, old_tool, new_tool, args)

  def run(["shot", "library", "list" | args]), do: list_shot_library(args)

  def run(["shot", "library", "show", template_id | args]),
    do: show_shot_library(template_id, args)

  def run(["shot", "library", "verify" | args]), do: verify_shot_library(args)
  def run(["shot", "library", "update" | args]), do: update_shot_library(args)
  def run(["shot", "library", "outdated", path | args]), do: outdated_shot_library(path, args)

  def run(["shot", "add", path, shot_id | args]), do: add_shot(path, shot_id, args)

  def run(["shot", "split", path, shot_id | args]), do: split_shot(path, shot_id, args)

  def run(["shot", "merge", path | args]), do: merge_shot(path, args)

  def run(["shot", "gate", path, target_id | args]), do: gate_shot(path, target_id, args)

  def run(["shot", "schema", "set", path, shot_id, schema_path | args]),
    do: set_shot_schema(path, shot_id, schema_path, args)

  def run(["shot", "replace-agent", path, old_agent, new_agent | args]),
    do: replace_shot_agent(path, old_agent, new_agent, args)

  def run(["shot", "replace-tool", path, old_tool, new_tool | args]),
    do: replace_shot_tool(path, old_tool, new_tool, args)

  def run(["shot", "rename", path, old_id, new_id | args]),
    do: rename_shot(path, old_id, new_id, args)

  def run(["shot", "move", path, shot_id | args]), do: move_shot(path, shot_id, args)
  def run(["shot", "remove", path, shot_id | args]), do: remove_shot(path, shot_id, args)

  def run(["round", "run", path | args]), do: run_round(path, args)
  def run(["round", "list" | args]), do: list_rounds(args)
  def run(["round", "show", round_id | args]), do: show_round(round_id, args)
  def run(["round", "watch", round_id | args]), do: watch_round(round_id, args)
  def run(["round", "audit", round_id | args]), do: audit_round(round_id, args)
  def run(["round", "approve", round_id | args]), do: safety_decision(:approve, round_id, args)
  def run(["round", "reject", round_id | args]), do: safety_decision(:reject, round_id, args)
  def run(["round", "cancel", round_id | args]), do: cancel_round(round_id, args)
  def run([]), do: {:ok, @usage, 0}

  def run([command | _]) do
    {:ok, "unknown command: #{command}\n\n" <> @usage, 4}
  end

  defp emit({:ok, output, 0}) do
    IO.write(output)
    :ok
  end

  defp emit({:ok, output, code}) do
    IO.write(:stderr, output)
    System.halt(code)
  end

  defp serve_daemon(args) do
    with {:ok, opts} <- parse_daemon_opts(args),
         {:ok, pid} <- Daemon.start_link(daemon_start_opts(opts)) do
      output =
        pid
        |> Server.address()
        |> format_daemon_started(opts[:format])

      IO.write(output)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    else
      {:error, error} ->
        IO.write(:stderr, format_command_error(error, :human))
        System.halt(ExitCode.for_error(error))
    end
  end

  defp daemon_start_opts(opts) do
    opts
    |> Keyword.take([:runtime_dir, :transport, :endpoint_path])
  end

  defp daemon_paths(args) do
    with {:ok, opts} <- parse_daemon_opts(args) do
      {:ok, format_daemon_paths(Twelvgaige.daemon_paths(daemon_start_opts(opts)), opts[:format]),
       0}
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp stop_daemon(args) do
    with {:ok, opts} <- parse_daemon_opts(args) do
      case Twelvgaige.stop_daemon(daemon_stop_opts(opts)) do
        :ok ->
          {:ok, format_daemon_stop(opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp daemon_stop_opts(opts) do
    cond do
      endpoint_path = opts[:endpoint_path] ->
        [endpoint_path: endpoint_path]

      runtime_dir = opts[:runtime_dir] ->
        [endpoint_path: Endpoint.default_path(runtime_dir: runtime_dir)]

      true ->
        []
    end
  end

  defp parse_daemon_opts(args),
    do:
      parse_daemon_opts(args,
        format: :human,
        transport: nil,
        runtime_dir: nil,
        endpoint_path: nil
      )

  defp parse_daemon_opts([], opts) do
    opts =
      opts
      |> compact_nil(:transport)
      |> compact_nil(:runtime_dir)
      |> compact_nil(:endpoint_path)

    {:ok, opts}
  end

  defp parse_daemon_opts(["--format", format | rest], opts) do
    parse_daemon_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_daemon_opts(["--transport", transport | rest], opts)
       when transport in ["unix", "tcp", "npipe"] do
    parse_daemon_opts(rest, Keyword.put(opts, :transport, parse_transport(transport)))
  end

  defp parse_daemon_opts(["--transport", _transport | _rest], _opts) do
    {:error,
     Twelvgaige.Error.new(:input_error, :invalid_shell, "--transport must be unix, tcp, or npipe")}
  end

  defp parse_daemon_opts(["--runtime-dir", runtime_dir | rest], opts) do
    parse_daemon_opts(rest, Keyword.put(opts, :runtime_dir, runtime_dir))
  end

  defp parse_daemon_opts(["--endpoint", endpoint_path | rest], opts) do
    parse_daemon_opts(rest, Keyword.put(opts, :endpoint_path, endpoint_path))
  end

  defp parse_daemon_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_transport("unix"), do: :unix
  defp parse_transport("tcp"), do: :tcp
  defp parse_transport("npipe"), do: :npipe

  defp compact_nil(opts, key) do
    case Keyword.get(opts, key) do
      nil -> Keyword.delete(opts, key)
      _value -> opts
    end
  end

  defp validate_shell(path, opts) do
    format = Keyword.fetch!(opts, :format)

    case Twelvgaige.validate_shell(path) do
      {:ok, shell} -> {:ok, format_shell(shell, format), 0}
      {:error, error} -> {:ok, format_error(error, format), 4}
    end
  end

  defp new_shell(id, args) do
    with {:ok, opts} <- parse_shell_new_opts(args),
         {:ok, format} <- shell_new_format(opts),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- ensure_output_within_root(opts[:output], root),
         {:ok, expansion} <-
           Scaffold.expand(opts[:scaffold], id, scaffold_opts(opts, root)),
         {:ok, workflow_contents} <- ShellDocument.encode(expansion.workflow, format) do
      if opts[:write?] do
        write_new_shell(expansion, workflow_contents, format, opts)
      else
        {:ok, workflow_contents, 0}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp list_scaffold_library(args) do
    with {:ok, opts} <- parse_scaffold_library_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, scaffolds} <- Scaffold.list(scaffold_library_opts(opts, root)) do
      {:ok, format_scaffold_library_list(scaffolds, opts[:format]), 0}
    else
      {:error, error} ->
        format = args |> parse_scaffold_library_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp show_scaffold_library(scaffold_id, args) do
    with {:ok, opts} <- parse_scaffold_library_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, scaffold} <- Scaffold.fetch(scaffold_id, scaffold_library_opts(opts, root)) do
      {:ok, format_scaffold_library_entry(scaffold, opts[:format]), 0}
    else
      {:error, error} ->
        format = args |> parse_scaffold_library_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp verify_scaffold_library(args) do
    with {:ok, opts} <- parse_scaffold_library_verify_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- ensure_output_within_root(opts[:lockfile], root),
         {:ok, report} <- Scaffold.verify(scaffold_library_verify_opts(opts, root)) do
      {:ok, format_scaffold_library_verify(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_scaffold_library_verify_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp update_scaffold_library(args) do
    with {:ok, opts} <- parse_scaffold_library_verify_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- ensure_output_within_root(opts[:lockfile], root),
         {:ok, report} <- Scaffold.update(scaffold_library_verify_opts(opts, root)) do
      {:ok, format_scaffold_library_update(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_scaffold_library_verify_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp outdated_scaffold_library(path, args) do
    with {:ok, opts} <- parse_scaffold_library_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, report} <- Scaffold.outdated(path, scaffold_library_opts(opts, root)) do
      {:ok, format_scaffold_library_outdated(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_scaffold_library_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp draft_shell(args) do
    with {:ok, opts} <- parse_shell_draft_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- ensure_output_within_root(opts[:output], root),
         {:ok, source} <- read_draft_source(opts[:from]),
         {:ok, report} <- ShellDraft.draft(source, shell_draft_opts(opts)) do
      if opts[:write?] do
        write_drafted_shell(report, opts)
      else
        {:ok, report.candidate, 0}
      end
    else
      {:error, error} ->
        {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp normalize_shell(path, args) do
    with {:ok, opts} <- parse_shell_normalize_opts(args),
         {:ok, shell} <- Twelvgaige.validate_shell(path),
         {:ok, contents} <- ShellDocument.encode(shell, opts[:format]) do
      {:ok, contents, 0}
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp convert_shell(path, args) do
    with {:ok, opts} <- parse_shell_convert_opts(args),
         {:ok, shell} <- Twelvgaige.validate_shell(path),
         {:ok, contents} <- ShellDocument.encode(shell, opts[:to]) do
      case opts[:output] do
        nil ->
          {:ok, contents, 0}

        output_path ->
          write_converted_shell(output_path, contents)
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp fmt_shell(path, args) do
    with {:ok, opts} <- parse_shell_fmt_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShellFormatter.format(path) do
      cond do
        opts[:check?] ->
          {:ok, format_shell_fmt(result, opts[:format], :check),
           if(result.changed?, do: 1, else: 0)}

        opts[:write?] ->
          write_formatted_shell(result, opts)

        true ->
          {:ok, format_shell_fmt(result, opts[:format], :dry_run), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shell_fmt_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp graph_shell(path, args) do
    with {:ok, opts} <- parse_shell_graph_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, %Shell.Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         {:ok, graph} <- ShellGraph.build(workflow) do
      {:ok, format_shell_graph(graph, opts[:format]), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "shell graph requires a workflow shell",
            details: %{path: path}
          )

        format = args |> parse_shell_graph_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}

      {:error, error} ->
        format = args |> parse_shell_graph_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp lint_shell(path, args) do
    with {:ok, opts} <- parse_shell_lint_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, report} <- ShellLint.run_target(path, strict?: opts[:strict?]) do
      {:ok, format_shell_lint(report, opts[:format]), report.exit_code}
    else
      {:error, error} ->
        format = args |> parse_shell_lint_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp admit_shell(path, args) do
    with {:ok, opts} <- parse_shell_admit_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, %Shell.Workflow{} = workflow} <- Shell.Loader.load(path, root_opts(opts)),
         {:ok, report} <- ShellAdmission.report(workflow, policy: opts[:policy]) do
      {:ok, format_shell_admission(path, report, opts[:format]), report.exit_code}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "shell admit requires a workflow shell",
            details: %{path: path}
          )

        format = args |> parse_shell_admit_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}

      {:error, error} ->
        format = args |> parse_shell_admit_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp doctor_shell(path, args) do
    with {:ok, opts} <- parse_shell_doctor_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, %Shell.Workflow{} = workflow} <- Twelvgaige.validate_shell(path) do
      report = ShellDoctor.run(workflow, path: path, strict?: opts[:strict?])
      {:ok, format_shell_doctor(report, opts[:format]), report.exit_code}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "shell doctor requires a workflow shell",
            details: %{path: path}
          )

        format = args |> parse_shell_doctor_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}

      {:error, error} ->
        format = args |> parse_shell_doctor_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp inventory_shell(path, args) do
    with {:ok, opts} <- parse_shell_inventory_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         :ok <- ensure_output_within_root(opts[:output], root),
         {:ok, report} <- ShellInventory.run(path) do
      maybe_write_report(
        ShellInventory.to_map(report),
        opts,
        "inventory",
        fn -> format_shell_inventory(report, opts[:format]) end
      )
    else
      {:error, error} ->
        format = args |> parse_shell_inventory_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp impact_shell(path, args) do
    with {:ok, opts} <- parse_shell_impact_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         :ok <- ensure_output_within_root(opts[:output], root),
         {:ok, report} <- ShellImpact.run(path, opts[:selector_kind], opts[:selector_value]) do
      maybe_write_report(
        ShellImpact.to_map(report),
        opts,
        "impact",
        fn -> format_shell_impact(report, opts[:format]) end
      )
    else
      {:error, error} ->
        format = args |> parse_shell_impact_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp list_shot_library(args) do
    with {:ok, opts} <- parse_shot_library_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, templates} <- ShotLibrary.list(shot_library_opts(opts, root)) do
      {:ok, format_shot_library_list(templates, opts[:format]), 0}
    else
      {:error, error} ->
        format = args |> parse_shot_library_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp show_shot_library(template_id, args) do
    with {:ok, opts} <- parse_shot_library_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, template} <- ShotLibrary.fetch(template_id, shot_library_opts(opts, root)) do
      {:ok, format_shot_library_template(template, opts[:format]), 0}
    else
      {:error, error} ->
        format = args |> parse_shot_library_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp verify_shot_library(args) do
    with {:ok, opts} <- parse_shot_library_verify_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- ensure_output_within_root(opts[:lockfile], root),
         {:ok, report} <- ShotLibrary.verify(shot_library_verify_opts(opts, root)) do
      {:ok, format_shot_library_verify(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_shot_library_verify_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp update_shot_library(args) do
    with {:ok, opts} <- parse_shot_library_verify_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- ensure_output_within_root(opts[:lockfile], root),
         {:ok, report} <- ShotLibrary.update(shot_library_verify_opts(opts, root)) do
      {:ok, format_shot_library_update(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_shot_library_verify_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp outdated_shot_library(path, args) do
    with {:ok, opts} <- parse_shot_library_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, report} <- ShotLibrary.outdated(path, shot_library_opts(opts, root)) do
      {:ok, format_shot_library_outdated(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_shot_library_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp author_review_shell(path, args) do
    with {:ok, opts} <- parse_shell_author_review_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, report} <- ShellAuthorReview.review(path, shell_author_review_opts(opts)) do
      {:ok, format_shell_author_review(report, opts[:format]), report.exit_code}
    else
      {:error, error} ->
        format = args |> parse_shell_author_review_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp inspect_shell_patch(path, args) do
    with {:ok, opts} <- parse_shell_patch_inspect_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, report} <- AuthoringPatch.inspect_file(path, patch_opts(opts, root)) do
      {:ok, format_shell_patch_report(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_shell_patch_inspect_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp verify_shell_patch(path, args) do
    with {:ok, opts} <- parse_shell_patch_verify_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, report} <- AuthoringPatch.verify_file(path, patch_verify_opts(opts, root)) do
      {:ok, format_shell_patch_report(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_shell_patch_verify_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp apply_shell_patch(path, args) do
    with {:ok, opts} <- parse_shell_patch_apply_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         {:ok, report} <- AuthoringPatch.apply_file(path, patch_apply_opts(opts, root)) do
      {:ok, format_shell_patch_report(report, opts[:format]), report["exit_code"]}
    else
      {:error, error} ->
        format = args |> parse_shell_patch_apply_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp add_shot(path, shot_id, args) do
    with {:ok, opts} <- parse_shot_add_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, shot} <- build_added_shot(shot_id, opts, root),
         {:ok, result} <-
           ShotRefactor.add(path, shot,
             position: Keyword.get(opts, :position, :end),
             target_id: Keyword.get(opts, :target_id)
           ) do
      if opts[:write?] do
        write_added_shot(result, opts)
      else
        {:ok, format_shot_add(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shot_add_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp gate_shot(path, target_id, args) do
    with {:ok, opts} <- parse_shot_gate_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <-
           ShotRefactor.gate(path, target_id, opts[:gate_id],
             description: opts[:description],
             prompt: opts[:prompt]
           ) do
      if opts[:write?] do
        write_gated_shot(result, opts)
      else
        {:ok, format_shot_gate(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shot_gate_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp split_shot(path, shot_id, args) do
    with {:ok, opts} <- parse_shot_split_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShotRefactor.split(path, shot_id, opts[:child_ids]),
         {:ok, lint_report} <- lint_split_candidate(path, result.workflow),
         result = Map.put(result, :lint_report, ShellLint.to_map(lint_report)) do
      if opts[:write?] do
        write_split_shot(result, opts)
      else
        {:ok, format_shot_split(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shot_split_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp merge_shot(path, args) do
    with {:ok, opts} <- parse_shot_merge_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShotRefactor.merge(path, opts[:source_ids], opts[:new_id]),
         {:ok, lint_report} <- lint_merge_candidate(path, result.workflow),
         result = Map.put(result, :lint_report, ShellLint.to_map(lint_report)) do
      if opts[:write?] do
        write_merged_shot(result, opts)
      else
        {:ok, format_shot_merge(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shot_merge_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp set_shot_schema(path, shot_id, schema_path, args) do
    with {:ok, opts} <- parse_shot_schema_set_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         :ok <- AuthoringRoot.ensure_within_root(schema_path, root),
         {:ok, schema} <- read_schema_file(schema_path),
         {:ok, result} <- ShotRefactor.set_schema(path, shot_id, schema) do
      if opts[:write?] do
        write_schema_set_shot(result, opts)
      else
        {:ok, format_shot_schema_set(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shot_schema_set_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp replace_shot_agent(path, old_agent, new_agent, args) do
    with {:ok, opts} <- parse_shot_replace_agent_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShotRefactor.replace_agent(path, old_agent, new_agent),
         {:ok, lint_report} <- lint_replaced_agent_candidate(path, result.workflow, new_agent),
         result = Map.put(result, :lint_report, ShellLint.to_map(lint_report)) do
      if opts[:write?] do
        write_replaced_agent_shot(result, opts)
      else
        {:ok, format_shot_replace_agent(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shot_replace_agent_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp replace_shot_tool(path, old_tool, new_tool, args) do
    with {:ok, opts} <- parse_shot_replace_tool_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShotRefactor.replace_tool(path, old_tool, new_tool),
         {:ok, lint_report} <- lint_replaced_tool_candidate(path, result.workflow, new_tool),
         result = Map.put(result, :lint_report, ShellLint.to_map(lint_report)) do
      if opts[:write?] do
        write_replaced_tool_shot(result, opts)
      else
        {:ok, format_shot_replace_tool(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shot_replace_tool_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp rename_shot(path, old_id, new_id, args) do
    with {:ok, opts} <- parse_shot_rename_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- ShotRefactor.rename(path, old_id, new_id) do
      if opts[:write?] do
        write_renamed_shot(result, opts)
      else
        {:ok, format_shot_rename(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shot_rename_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp remove_shot(path, shot_id, args) do
    with {:ok, opts} <- parse_shot_remove_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <-
           ShotRefactor.remove(path, shot_id, cascade?: opts[:cascade?], yes?: opts[:yes?]) do
      if opts[:write?] do
        write_removed_shot(result, opts)
      else
        {:ok, format_shot_remove(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shot_remove_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp move_shot(path, shot_id, args) do
    with {:ok, opts} <- parse_shot_move_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <-
           ShotRefactor.move(path, shot_id, opts[:position], opts[:target_id]) do
      if opts[:write?] do
        write_moved_shot(result, opts)
      else
        {:ok, format_shot_move(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shot_move_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp write_new_shell(expansion, workflow_contents, format, opts) do
    case opts[:output] do
      nil ->
        Twelvgaige.Error.new(:input_error, :invalid_shell, "--output is required with --write")
        |> format_authoring_write_error()

      workflow_path ->
        with :ok <- ensure_can_write(workflow_path, opts),
             {:ok, agent_writes} <-
               new_shell_agent_writes(expansion.agents, workflow_path, format, opts),
             :ok <- write_authoring_file(workflow_path, workflow_contents),
             :ok <- write_agent_shells(agent_writes) do
          output =
            [
              "created workflow shell: #{workflow_path}"
              | Enum.map(agent_writes, fn {path, _contents} -> "created agent shell: #{path}" end)
            ]
            |> Enum.join("\n")
            |> Kernel.<>("\n")

          {:ok, output, 0}
        else
          {:error, error} -> format_authoring_write_error(error)
        end
    end
  end

  defp write_drafted_shell(report, opts) do
    case opts[:output] do
      nil ->
        Twelvgaige.Error.new(:input_error, :invalid_shell, "--output is required with --write")
        |> format_authoring_write_error()

      output_path ->
        with :ok <- ensure_can_write(output_path, opts),
             :ok <- write_authoring_file(output_path, report.candidate),
             {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(output_path),
             {:ok, lint_report} <- ShellLint.run_path(output_path, strict?: true),
             :ok <- ensure_lint_ok(lint_report) do
          {:ok, "created draft workflow shell: #{output_path}\n", 0}
        else
          {:ok, _other_shell} ->
            error =
              Twelvgaige.Error.new(
                :input_error,
                :invalid_shell,
                "drafted shell did not validate as a workflow",
                details: %{path: output_path}
              )

            format_authoring_write_error(error)

          {:error, error} ->
            format_authoring_write_error(error)
        end
    end
  end

  defp ensure_lint_ok(%{status: :ok}), do: :ok

  defp ensure_lint_ok(report) do
    {:error,
     Twelvgaige.Error.new(:compile_error, :invalid_shell, "drafted shell failed strict lint",
       details: %{lint: ShellLint.to_map(report)}
     )}
  end

  defp write_formatted_shell(result, opts) do
    if result.changed? do
      with :ok <- write_authoring_file(result.path, result.candidate),
           {:ok, _shell} <- Twelvgaige.validate_shell(result.path) do
        {:ok, format_shell_fmt(result, opts[:format], :write), 0}
      else
        {:error, error} -> format_authoring_write_error(error)
      end
    else
      {:ok, format_shell_fmt(result, opts[:format], :write), 0}
    end
  end

  defp write_lifecycle_shell(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{} = workflow} <- Twelvgaige.validate_shell(result.path),
         true <- lifecycle_binding_current?(workflow, result.action) do
      {:ok, format_shell_lifecycle(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "lifecycle shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      false ->
        error =
          Twelvgaige.Error.new(
            :compile_error,
            :invalid_shell,
            "lifecycle binding digest was not current after write",
            details: %{path: result.path, action: Atom.to_string(result.action)}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp lifecycle_binding_current?(workflow, :review),
    do: Twelvgaige.Shell.Digest.current_binding?(workflow, :review)

  defp lifecycle_binding_current?(workflow, :approve),
    do: Twelvgaige.Shell.Digest.current_binding?(workflow, :approval)

  defp lifecycle_binding_current?(_workflow, action) when action in [:deprecate, :retire],
    do: true

  defp write_metadata_shell(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shell_metadata(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "metadata shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp format_authoring_write_error(error) do
    {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
  end

  defp new_shell_agent_writes([], _workflow_path, _format, _opts), do: {:ok, []}

  defp new_shell_agent_writes(agents, workflow_path, format, opts) do
    agent_dir = Path.join(Path.dirname(workflow_path), "agents")
    extension = shell_document_extension(format)

    Enum.reduce_while(agents, {:ok, []}, fn agent, {:ok, writes} ->
      path = Path.join(agent_dir, "#{Map.fetch!(agent, "id")}#{extension}")

      with :ok <- ensure_can_write(path, opts),
           {:ok, contents} <- ShellDocument.encode(agent, format) do
        {:cont, {:ok, writes ++ [{path, contents}]}}
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp write_agent_shells(writes) do
    Enum.reduce_while(writes, :ok, fn {path, contents}, :ok ->
      case write_authoring_file(path, contents) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp write_authoring_file(path, contents) do
    AtomicFile.write(path, contents)
  end

  defp ensure_can_write(path, opts) do
    if File.exists?(path) and not opts[:force?] do
      {:error,
       Twelvgaige.Error.new(:input_error, :invalid_shell, "output file already exists",
         details: %{path: path}
       )}
    else
      :ok
    end
  end

  defp ensure_output_within_root(nil, _root), do: :ok
  defp ensure_output_within_root(path, root), do: AuthoringRoot.ensure_within_root(path, root)

  defp maybe_write_report(report_map, opts, label, stdout_fun) do
    case opts[:output] do
      nil ->
        {:ok, stdout_fun.(), 0}

      output_path ->
        with :ok <- ensure_can_write(output_path, opts),
             :ok <-
               write_authoring_file(output_path, Jason.encode!(report_map, pretty: true) <> "\n") do
          {:ok, "wrote #{label} report: #{output_path}\n", 0}
        else
          {:error, error} -> format_authoring_write_error(error)
        end
    end
  end

  defp maybe_write_bulk_report(report, opts) do
    case opts[:output] do
      nil ->
        {:ok, format_shell_bulk_refactor(report, opts[:format]), report.exit_code}

      output_path ->
        with :ok <- ensure_can_write(output_path, opts),
             :ok <-
               write_authoring_file(
                 output_path,
                 Jason.encode!(ShellBulkRefactor.to_map(report), pretty: true) <> "\n"
               ) do
          {:ok, "wrote #{bulk_refactor_label(report)} report: #{output_path}\n", report.exit_code}
        else
          {:error, error} -> format_authoring_write_error(error)
        end
    end
  end

  defp bulk_refactor_label(%{operation: operation}) do
    "bulk " <> (operation |> Atom.to_string() |> String.replace("_", "-"))
  end

  defp write_renamed_shot(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shot_rename(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "renamed shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp write_removed_shot(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shot_remove(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "refactored shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp write_moved_shot(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shot_move(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "refactored shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp write_added_shot(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shot_add(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "refactored shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp write_split_shot(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shot_split(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "refactored shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp write_merged_shot(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shot_merge(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "refactored shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp write_gated_shot(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shot_gate(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "refactored shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp write_schema_set_shot(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shot_schema_set(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "refactored shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp write_replaced_agent_shot(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shot_replace_agent(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "refactored shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp write_replaced_tool_shot(result, opts) do
    with :ok <- write_authoring_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{}} <- Twelvgaige.validate_shell(result.path) do
      {:ok, format_shot_replace_tool(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "refactored shell did not validate as a workflow",
            details: %{path: result.path}
          )

        format_authoring_write_error(error)

      {:error, error} ->
        format_authoring_write_error(error)
    end
  end

  defp write_converted_shell(output_path, contents) do
    with :ok <- File.mkdir_p(Path.dirname(output_path)),
         :ok <- File.write(output_path, contents) do
      {:ok, "converted shell: #{output_path}\n", 0}
    else
      {:error, reason} ->
        error =
          Twelvgaige.Error.new(:input_error, :invalid_shell, "unable to write converted shell",
            details: %{path: output_path, reason: inspect(reason)}
          )

        {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp reload_shells(args) do
    with {:ok, opts} <- parse_shell_reload_opts(args) do
      reload_opts =
        case Keyword.fetch!(opts, :paths) do
          [] -> []
          paths -> [paths: paths]
        end

      case Twelvgaige.reload_shells(reload_opts) do
        {:ok, summary} ->
          {:ok, format_shell_reload(summary, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp list_shells(args) do
    with {:ok, opts} <- parse_shell_list_opts(args),
         {:ok, shells} <- cached_shells(opts[:kind]) do
      {:ok, format_shell_list(shells, opts[:format]), 0}
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp show_shell(shell_id, args) do
    with {:ok, opts} <- parse_shell_show_opts(args) do
      case Twelvgaige.get_shell(shell_id, kind: opts[:kind]) do
        {:ok, shell} ->
          {:ok, format_shell_detail(shell, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp lifecycle_shell(action, path, args) do
    with {:ok, opts} <- parse_shell_lifecycle_args(args, action),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- run_lifecycle_action(action, path, opts) do
      if opts[:write?] do
        write_lifecycle_shell(result, opts)
      else
        {:ok, format_shell_lifecycle(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shell_lifecycle_error_format(action)
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp metadata_set_shell(path, args) do
    with {:ok, opts} <- parse_shell_metadata_set_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- MetadataRefactor.set(path, metadata_set_changes(opts)) do
      if opts[:write?] do
        write_metadata_shell(result, opts)
      else
        {:ok, format_shell_metadata(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shell_metadata_set_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp metadata_clear_shell(path, args) do
    with {:ok, opts} <- parse_shell_metadata_clear_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- MetadataRefactor.clear(path, opts[:fields]) do
      if opts[:write?] do
        write_metadata_shell(result, opts)
      else
        {:ok, format_shell_metadata(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_shell_metadata_clear_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp bulk_replace_agent_shell(path, old_agent, new_agent, args) do
    with {:ok, opts} <- parse_shell_bulk_replace_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         :ok <- ensure_output_within_root(opts[:output], root),
         {:ok, report} <-
           ShellBulkRefactor.replace_agent(path, old_agent, new_agent,
             write?: opts[:write?],
             yes?: opts[:yes?]
           ) do
      maybe_write_bulk_report(report, opts)
    else
      {:error, error} ->
        format = args |> parse_shell_bulk_replace_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp bulk_replace_tool_shell(path, old_tool, new_tool, args) do
    with {:ok, opts} <- parse_shell_bulk_replace_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         :ok <- ensure_output_within_root(opts[:output], root),
         {:ok, report} <-
           ShellBulkRefactor.replace_tool(path, old_tool, new_tool,
             write?: opts[:write?],
             yes?: opts[:yes?]
           ) do
      maybe_write_bulk_report(report, opts)
    else
      {:error, error} ->
        format = args |> parse_shell_bulk_replace_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp run_lifecycle_action(:review, path, opts) do
    ShellLifecycle.review(path,
      by: opts[:by],
      scope: opts[:scope],
      evidence_hash: opts[:evidence_hash]
    )
  end

  defp run_lifecycle_action(:approve, path, opts) do
    ShellLifecycle.approve(path,
      by: opts[:by],
      scope: opts[:scope],
      expires_at: opts[:expires_at],
      evidence_hash: opts[:evidence_hash]
    )
  end

  defp run_lifecycle_action(:deprecate, path, opts) do
    ShellLifecycle.deprecate(path,
      by: opts[:by],
      reason: opts[:reason],
      scope: opts[:scope]
    )
  end

  defp run_lifecycle_action(:retire, path, opts) do
    ShellLifecycle.retire(path,
      by: opts[:by],
      reason: opts[:reason],
      scope: opts[:scope]
    )
  end

  defp metadata_set_changes(opts) do
    [owner: opts[:owner], lifecycle: opts[:lifecycle]]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp parse_shell_reload_opts(args),
    do: parse_shell_reload_opts(args, format: :human, paths: [])

  defp parse_shell_new_opts(args) do
    parse_shell_new_opts(args,
      scaffold: "single-shot",
      scaffold_paths: [],
      format: nil,
      output: nil,
      write?: false,
      force?: false,
      with_mock_agents?: false,
      root: nil
    )
  end

  defp parse_shell_new_opts([], opts), do: {:ok, opts}

  defp parse_shell_new_opts(["--scaffold", scaffold | rest], opts) do
    parse_shell_new_opts(rest, Keyword.put(opts, :scaffold, scaffold))
  end

  defp parse_shell_new_opts(["--scaffold-path", path | rest], opts) do
    parse_shell_new_opts(rest, Keyword.update!(opts, :scaffold_paths, &(&1 ++ [path])))
  end

  defp parse_shell_new_opts(["--format", format | rest], opts) do
    case parse_shell_document_format(format) do
      {:ok, format} -> parse_shell_new_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_new_opts(["--output", output | rest], opts) do
    parse_shell_new_opts(rest, Keyword.put(opts, :output, output))
  end

  defp parse_shell_new_opts(["--root", root | rest], opts) do
    parse_shell_new_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_new_opts(["--with-mock-agents" | rest], opts) do
    parse_shell_new_opts(rest, Keyword.put(opts, :with_mock_agents?, true))
  end

  defp parse_shell_new_opts(["--write" | rest], opts) do
    parse_shell_new_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shell_new_opts(["--dry-run" | rest], opts) do
    parse_shell_new_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shell_new_opts(["--force" | rest], opts) do
    parse_shell_new_opts(rest, Keyword.put(opts, :force?, true))
  end

  defp parse_shell_new_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_draft_opts(args) do
    parse_shell_draft_opts(args,
      from: nil,
      provider: "mock",
      model: "mock-model",
      allow_remote?: false,
      max_input_bytes: 64 * 1024,
      format: :yaml,
      output: nil,
      write?: false,
      force?: false,
      root: nil
    )
  end

  defp parse_shell_draft_opts([], opts) do
    cond do
      is_nil(opts[:from]) ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "shell draft requires --from")}

      opts[:output] && not opts[:write?] ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "shell draft requires --write when --output is provided"
         )}

      true ->
        {:ok, opts}
    end
  end

  defp parse_shell_draft_opts(["--from", from | rest], opts) do
    parse_shell_draft_opts(rest, Keyword.put(opts, :from, from))
  end

  defp parse_shell_draft_opts(["--provider", provider | rest], opts) do
    parse_shell_draft_opts(rest, Keyword.put(opts, :provider, provider))
  end

  defp parse_shell_draft_opts(["--model", model | rest], opts) do
    parse_shell_draft_opts(rest, Keyword.put(opts, :model, model))
  end

  defp parse_shell_draft_opts(["--allow-remote" | rest], opts) do
    parse_shell_draft_opts(rest, Keyword.put(opts, :allow_remote?, true))
  end

  defp parse_shell_draft_opts(["--max-input-bytes", value | rest], opts) do
    case parse_positive_integer(value, "--max-input-bytes") do
      {:ok, max_input_bytes} ->
        parse_shell_draft_opts(rest, Keyword.put(opts, :max_input_bytes, max_input_bytes))

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_shell_draft_opts(["--format", format | rest], opts) do
    case parse_shell_document_format(format) do
      {:ok, format} -> parse_shell_draft_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_draft_opts(["--output", output | rest], opts) do
    parse_shell_draft_opts(rest, Keyword.put(opts, :output, output))
  end

  defp parse_shell_draft_opts(["--write" | rest], opts) do
    parse_shell_draft_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shell_draft_opts(["--dry-run" | rest], opts) do
    parse_shell_draft_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shell_draft_opts(["--force" | rest], opts) do
    parse_shell_draft_opts(rest, Keyword.put(opts, :force?, true))
  end

  defp parse_shell_draft_opts(["--root", root | rest], opts) do
    parse_shell_draft_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_draft_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_author_review_opts(args) do
    parse_shell_author_review_opts(args,
      provider: "mock",
      model: "mock-model",
      allow_remote?: false,
      max_input_bytes: 64 * 1024,
      format: :human,
      root: nil
    )
  end

  defp parse_shell_author_review_opts([], opts), do: {:ok, opts}

  defp parse_shell_author_review_opts(["--provider", provider | rest], opts) do
    parse_shell_author_review_opts(rest, Keyword.put(opts, :provider, provider))
  end

  defp parse_shell_author_review_opts(["--model", model | rest], opts) do
    parse_shell_author_review_opts(rest, Keyword.put(opts, :model, model))
  end

  defp parse_shell_author_review_opts(["--allow-remote" | rest], opts) do
    parse_shell_author_review_opts(rest, Keyword.put(opts, :allow_remote?, true))
  end

  defp parse_shell_author_review_opts(["--max-input-bytes", value | rest], opts) do
    case parse_positive_integer(value, "--max-input-bytes") do
      {:ok, max_input_bytes} ->
        parse_shell_author_review_opts(rest, Keyword.put(opts, :max_input_bytes, max_input_bytes))

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_shell_author_review_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_author_review_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_author_review_opts(["--root", root | rest], opts) do
    parse_shell_author_review_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_author_review_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_author_review_error_format(args) do
    args
    |> parse_shell_author_review_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_patch_inspect_opts(args),
    do: parse_shell_patch_inspect_opts(args, format: :human, root: nil)

  defp parse_shell_patch_inspect_opts([], opts), do: {:ok, opts}

  defp parse_shell_patch_inspect_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_patch_inspect_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_patch_inspect_opts(["--root", root | rest], opts) do
    parse_shell_patch_inspect_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_patch_inspect_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_patch_inspect_error_format(args) do
    args
    |> parse_shell_patch_inspect_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_patch_verify_opts(args),
    do: parse_shell_patch_verify_opts(args, format: :human, root: nil, approval: nil)

  defp parse_shell_patch_verify_opts([], opts), do: {:ok, opts}

  defp parse_shell_patch_verify_opts(["--approval", approval | rest], opts) do
    parse_shell_patch_verify_opts(rest, Keyword.put(opts, :approval, approval))
  end

  defp parse_shell_patch_verify_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_patch_verify_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_patch_verify_opts(["--root", root | rest], opts) do
    parse_shell_patch_verify_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_patch_verify_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_patch_verify_error_format(args) do
    args
    |> parse_shell_patch_verify_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_patch_apply_opts(args),
    do:
      parse_shell_patch_apply_opts(args,
        format: :human,
        root: nil,
        approval: nil,
        write?: false
      )

  defp parse_shell_patch_apply_opts([], opts), do: {:ok, opts}

  defp parse_shell_patch_apply_opts(["--approval", approval | rest], opts) do
    parse_shell_patch_apply_opts(rest, Keyword.put(opts, :approval, approval))
  end

  defp parse_shell_patch_apply_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_patch_apply_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_patch_apply_opts(["--root", root | rest], opts) do
    parse_shell_patch_apply_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_patch_apply_opts(["--write" | rest], opts) do
    parse_shell_patch_apply_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shell_patch_apply_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_patch_apply_error_format(args) do
    args
    |> parse_shell_patch_apply_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_normalize_opts(args), do: parse_shell_normalize_opts(args, format: :json)

  defp parse_shell_normalize_opts([], opts), do: {:ok, opts}

  defp parse_shell_normalize_opts(["--format", format | rest], opts) do
    case parse_shell_document_format(format) do
      {:ok, format} -> parse_shell_normalize_opts(rest, Keyword.put(opts, :format, format))
      {:error, _error} = error -> error
    end
  end

  defp parse_shell_normalize_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_convert_opts(args), do: parse_shell_convert_opts(args, to: nil, output: nil)

  defp parse_shell_convert_opts([], opts) do
    if is_nil(Keyword.get(opts, :to)) do
      {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--to is required")}
    else
      {:ok, opts}
    end
  end

  defp parse_shell_convert_opts(["--to", format | rest], opts) do
    case parse_shell_document_format(format) do
      {:ok, format} -> parse_shell_convert_opts(rest, Keyword.put(opts, :to, format))
      {:error, _error} = error -> error
    end
  end

  defp parse_shell_convert_opts(["--output", output | rest], opts) do
    parse_shell_convert_opts(rest, Keyword.put(opts, :output, output))
  end

  defp parse_shell_convert_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_fmt_opts(args),
    do: parse_shell_fmt_opts(args, format: :human, root: nil, check?: false, write?: false)

  defp parse_shell_fmt_opts([], opts) do
    if opts[:check?] and opts[:write?] do
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shell fmt accepts either --check or --write, not both"
       )}
    else
      {:ok, opts}
    end
  end

  defp parse_shell_fmt_opts(["--check" | rest], opts) do
    parse_shell_fmt_opts(rest, Keyword.put(opts, :check?, true))
  end

  defp parse_shell_fmt_opts(["--write" | rest], opts) do
    parse_shell_fmt_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shell_fmt_opts(["--dry-run" | rest], opts) do
    parse_shell_fmt_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shell_fmt_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_fmt_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_fmt_opts(["--root", root | rest], opts) do
    parse_shell_fmt_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_fmt_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_fmt_error_format(args) do
    args
    |> parse_shell_fmt_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_graph_opts(args), do: parse_shell_graph_opts(args, format: :text, root: nil)

  defp parse_shell_graph_opts([], opts), do: {:ok, opts}

  defp parse_shell_graph_opts(["--format", format | rest], opts) do
    case parse_shell_graph_format(format) do
      {:ok, format} -> parse_shell_graph_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_graph_opts(["--root", root | rest], opts) do
    parse_shell_graph_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_graph_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_graph_error_format(args) do
    args
    |> parse_shell_graph_opts()
    |> case do
      {:ok, opts} -> graph_error_format(opts[:format])
      {:error, _error} -> :human
    end
  end

  defp parse_shell_lint_opts(args),
    do: parse_shell_lint_opts(args, format: :human, root: nil, strict?: false)

  defp parse_shell_lint_opts([], opts), do: {:ok, opts}

  defp parse_shell_lint_opts(["--strict" | rest], opts) do
    parse_shell_lint_opts(rest, Keyword.put(opts, :strict?, true))
  end

  defp parse_shell_lint_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_lint_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_lint_opts(["--root", root | rest], opts) do
    parse_shell_lint_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_lint_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_lint_error_format(args) do
    args
    |> parse_shell_lint_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_admit_opts(args),
    do: parse_shell_admit_opts(args, format: :human, root: nil, policy: :manual)

  defp parse_shell_admit_opts([], opts), do: {:ok, opts}

  defp parse_shell_admit_opts(["--policy", policy | rest], opts) do
    case ShellAdmission.normalize_policy(policy) do
      {:ok, policy} -> parse_shell_admit_opts(rest, Keyword.put(opts, :policy, policy))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_admit_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_admit_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_admit_opts(["--root", root | rest], opts) do
    parse_shell_admit_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_admit_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_admit_error_format(args) do
    args
    |> parse_shell_admit_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_doctor_opts(args),
    do: parse_shell_doctor_opts(args, format: :human, root: nil, strict?: false)

  defp parse_shell_doctor_opts([], opts), do: {:ok, opts}

  defp parse_shell_doctor_opts(["--strict" | rest], opts) do
    parse_shell_doctor_opts(rest, Keyword.put(opts, :strict?, true))
  end

  defp parse_shell_doctor_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_doctor_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_doctor_opts(["--root", root | rest], opts) do
    parse_shell_doctor_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_doctor_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_doctor_error_format(args) do
    args
    |> parse_shell_doctor_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_inventory_opts(args),
    do: parse_shell_inventory_opts(args, format: :human, root: nil, output: nil, force?: false)

  defp parse_shell_inventory_opts([], opts), do: {:ok, opts}

  defp parse_shell_inventory_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_inventory_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_inventory_opts(["--root", root | rest], opts) do
    parse_shell_inventory_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_inventory_opts(["--output", output | rest], opts) do
    parse_shell_inventory_opts(rest, Keyword.put(opts, :output, output))
  end

  defp parse_shell_inventory_opts(["--force" | rest], opts) do
    parse_shell_inventory_opts(rest, Keyword.put(opts, :force?, true))
  end

  defp parse_shell_inventory_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_inventory_error_format(args) do
    args
    |> parse_shell_inventory_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_impact_opts(args) do
    parse_shell_impact_opts(args,
      format: :human,
      root: nil,
      output: nil,
      force?: false,
      selector_kind: nil,
      selector_value: nil
    )
  end

  defp parse_shell_impact_opts([], opts) do
    if opts[:selector_kind] && opts[:selector_value] do
      {:ok, opts}
    else
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shell impact requires --agent, --tool, or --template"
       )}
    end
  end

  defp parse_shell_impact_opts(["--agent", value | rest], opts),
    do: put_impact_selector(rest, opts, :agent, value)

  defp parse_shell_impact_opts(["--tool", value | rest], opts),
    do: put_impact_selector(rest, opts, :tool, value)

  defp parse_shell_impact_opts(["--template", value | rest], opts),
    do: put_impact_selector(rest, opts, :template, value)

  defp parse_shell_impact_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_impact_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_impact_opts(["--root", root | rest], opts) do
    parse_shell_impact_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shell_impact_opts(["--output", output | rest], opts) do
    parse_shell_impact_opts(rest, Keyword.put(opts, :output, output))
  end

  defp parse_shell_impact_opts(["--force" | rest], opts) do
    parse_shell_impact_opts(rest, Keyword.put(opts, :force?, true))
  end

  defp parse_shell_impact_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp put_impact_selector(rest, opts, selector_kind, selector_value) do
    if opts[:selector_kind] do
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shell impact accepts exactly one selector"
       )}
    else
      opts =
        opts
        |> Keyword.put(:selector_kind, selector_kind)
        |> Keyword.put(:selector_value, selector_value)

      parse_shell_impact_opts(rest, opts)
    end
  end

  defp parse_shell_impact_error_format(args) do
    args
    |> parse_shell_impact_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shot_rename_opts(args),
    do: parse_shot_rename_opts(args, format: :human, root: nil, write?: false)

  defp parse_shot_rename_opts([], opts), do: {:ok, opts}

  defp parse_shot_rename_opts(["--write" | rest], opts) do
    parse_shot_rename_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shot_rename_opts(["--dry-run" | rest], opts) do
    parse_shot_rename_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shot_rename_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_rename_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_rename_opts(["--root", root | rest], opts) do
    parse_shot_rename_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_rename_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shot_rename_error_format(args) do
    args
    |> parse_shot_rename_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shot_add_opts(args),
    do:
      parse_shot_add_opts(args,
        format: :human,
        root: nil,
        library_paths: [],
        write?: false,
        template: nil,
        kind: nil,
        agent: nil,
        prompt: nil,
        description: nil,
        depends_on: [],
        tools: [],
        position: :end,
        target_id: nil
      )

  defp parse_shot_add_opts([], opts) do
    if opts[:kind] || opts[:template] do
      {:ok, opts}
    else
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shot add requires --kind or --template"
       )}
    end
  end

  defp parse_shot_add_opts(["--kind", kind | rest], opts) when kind in ["slug", "safety"] do
    parse_shot_add_opts(rest, Keyword.put(opts, :kind, kind))
  end

  defp parse_shot_add_opts(["--kind", _kind | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--kind must be slug or safety")}
  end

  defp parse_shot_add_opts(["--agent", agent | rest], opts) do
    parse_shot_add_opts(rest, Keyword.put(opts, :agent, agent))
  end

  defp parse_shot_add_opts(["--template", template | rest], opts) do
    parse_shot_add_opts(rest, Keyword.put(opts, :template, template))
  end

  defp parse_shot_add_opts(["--prompt", prompt | rest], opts) do
    parse_shot_add_opts(rest, Keyword.put(opts, :prompt, prompt))
  end

  defp parse_shot_add_opts(["--description", description | rest], opts) do
    parse_shot_add_opts(rest, Keyword.put(opts, :description, description))
  end

  defp parse_shot_add_opts(["--depends-on", depends_on | rest], opts) do
    parse_shot_add_opts(rest, Keyword.update!(opts, :depends_on, &(&1 ++ csv_values(depends_on))))
  end

  defp parse_shot_add_opts(["--tool", tool | rest], opts) do
    parse_shot_add_opts(rest, Keyword.update!(opts, :tools, &(&1 ++ [tool])))
  end

  defp parse_shot_add_opts(["--before", target_id | rest], opts),
    do: put_add_target(rest, opts, :before, target_id)

  defp parse_shot_add_opts(["--after", target_id | rest], opts),
    do: put_add_target(rest, opts, :after, target_id)

  defp parse_shot_add_opts(["--write" | rest], opts) do
    parse_shot_add_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shot_add_opts(["--dry-run" | rest], opts) do
    parse_shot_add_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shot_add_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_add_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_add_opts(["--root", root | rest], opts) do
    parse_shot_add_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_add_opts(["--library-path", path | rest], opts) do
    parse_shot_add_opts(rest, Keyword.update!(opts, :library_paths, &(&1 ++ [path])))
  end

  defp parse_shot_add_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp put_add_target(rest, opts, position, target_id) do
    if opts[:target_id] do
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shot add accepts exactly one --before or --after target"
       )}
    else
      opts =
        opts
        |> Keyword.put(:position, position)
        |> Keyword.put(:target_id, target_id)

      parse_shot_add_opts(rest, opts)
    end
  end

  defp parse_shot_add_error_format(args) do
    args
    |> parse_shot_add_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shot_gate_opts(args),
    do:
      parse_shot_gate_opts(args,
        format: :human,
        root: nil,
        write?: false,
        gate_id: nil,
        description: nil,
        prompt: nil
      )

  defp parse_shot_gate_opts([], opts) do
    case opts[:gate_id] do
      gate_id when is_binary(gate_id) and gate_id != "" ->
        {:ok, opts}

      _missing ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "shot gate requires --id")}
    end
  end

  defp parse_shot_gate_opts(["--id", gate_id | rest], opts) do
    parse_shot_gate_opts(rest, Keyword.put(opts, :gate_id, gate_id))
  end

  defp parse_shot_gate_opts(["--description", description | rest], opts) do
    parse_shot_gate_opts(rest, Keyword.put(opts, :description, description))
  end

  defp parse_shot_gate_opts(["--prompt", prompt | rest], opts) do
    parse_shot_gate_opts(rest, Keyword.put(opts, :prompt, prompt))
  end

  defp parse_shot_gate_opts(["--write" | rest], opts) do
    parse_shot_gate_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shot_gate_opts(["--dry-run" | rest], opts) do
    parse_shot_gate_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shot_gate_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_gate_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_gate_opts(["--root", root | rest], opts) do
    parse_shot_gate_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_gate_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shot_gate_error_format(args) do
    args
    |> parse_shot_gate_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shot_split_opts(args),
    do: parse_shot_split_opts(args, format: :human, root: nil, write?: false, child_ids: nil)

  defp parse_shot_split_opts([], opts) do
    case opts[:child_ids] do
      child_ids when is_list(child_ids) and child_ids != [] ->
        {:ok, opts}

      _missing ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "shot split requires --into")}
    end
  end

  defp parse_shot_split_opts(["--into", child_ids | rest], opts) do
    parse_shot_split_opts(rest, Keyword.put(opts, :child_ids, csv_values(child_ids)))
  end

  defp parse_shot_split_opts(["--write" | rest], opts) do
    parse_shot_split_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shot_split_opts(["--dry-run" | rest], opts) do
    parse_shot_split_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shot_split_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_split_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_split_opts(["--root", root | rest], opts) do
    parse_shot_split_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_split_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shot_split_error_format(args) do
    args
    |> parse_shot_split_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shot_merge_opts(args),
    do:
      parse_shot_merge_opts(args,
        format: :human,
        root: nil,
        write?: false,
        source_ids: [],
        new_id: nil
      )

  defp parse_shot_merge_opts([], opts) do
    cond do
      length(opts[:source_ids]) < 2 ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "shot merge requires at least two source shot ids"
         )}

      is_nil(opts[:new_id]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "shot merge requires --id")}

      true ->
        {:ok, opts}
    end
  end

  defp parse_shot_merge_opts(["--id", new_id | rest], opts) do
    parse_shot_merge_opts(rest, Keyword.put(opts, :new_id, new_id))
  end

  defp parse_shot_merge_opts(["--write" | rest], opts) do
    parse_shot_merge_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shot_merge_opts(["--dry-run" | rest], opts) do
    parse_shot_merge_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shot_merge_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_merge_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_merge_opts(["--root", root | rest], opts) do
    parse_shot_merge_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_merge_opts(["--" <> _ = unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shot_merge_opts([source_id | rest], opts) do
    parse_shot_merge_opts(rest, Keyword.update!(opts, :source_ids, &(&1 ++ [source_id])))
  end

  defp parse_shot_merge_error_format(args) do
    args
    |> parse_shot_merge_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shot_schema_set_opts(args),
    do: parse_shot_schema_set_opts(args, format: :human, root: nil, write?: false)

  defp parse_shot_schema_set_opts([], opts), do: {:ok, opts}

  defp parse_shot_schema_set_opts(["--write" | rest], opts) do
    parse_shot_schema_set_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shot_schema_set_opts(["--dry-run" | rest], opts) do
    parse_shot_schema_set_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shot_schema_set_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_schema_set_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_schema_set_opts(["--root", root | rest], opts) do
    parse_shot_schema_set_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_schema_set_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shot_schema_set_error_format(args) do
    args
    |> parse_shot_schema_set_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shot_replace_agent_opts(args),
    do: parse_shot_replace_agent_opts(args, format: :human, root: nil, write?: false)

  defp parse_shot_replace_agent_opts([], opts), do: {:ok, opts}

  defp parse_shot_replace_agent_opts(["--write" | rest], opts) do
    parse_shot_replace_agent_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shot_replace_agent_opts(["--dry-run" | rest], opts) do
    parse_shot_replace_agent_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shot_replace_agent_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_replace_agent_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_replace_agent_opts(["--root", root | rest], opts) do
    parse_shot_replace_agent_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_replace_agent_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shot_replace_agent_error_format(args) do
    args
    |> parse_shot_replace_agent_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shot_replace_tool_opts(args),
    do: parse_shot_replace_tool_opts(args, format: :human, root: nil, write?: false)

  defp parse_shot_replace_tool_opts([], opts), do: {:ok, opts}

  defp parse_shot_replace_tool_opts(["--write" | rest], opts) do
    parse_shot_replace_tool_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shot_replace_tool_opts(["--dry-run" | rest], opts) do
    parse_shot_replace_tool_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shot_replace_tool_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_replace_tool_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_replace_tool_opts(["--root", root | rest], opts) do
    parse_shot_replace_tool_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_replace_tool_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shot_replace_tool_error_format(args) do
    args
    |> parse_shot_replace_tool_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shot_library_opts(args),
    do: parse_shot_library_opts(args, format: :human, root: nil, library_paths: [])

  defp parse_shot_library_opts([], opts), do: {:ok, opts}

  defp parse_shot_library_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_library_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_library_opts(["--root", root | rest], opts) do
    parse_shot_library_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_library_opts(["--library-path", path | rest], opts) do
    parse_shot_library_opts(rest, Keyword.update!(opts, :library_paths, &(&1 ++ [path])))
  end

  defp parse_shot_library_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shot_library_error_format(args) do
    args
    |> parse_shot_library_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp shot_library_opts(opts, root) do
    [library_paths: opts[:library_paths], root: root[:root]]
  end

  defp parse_shot_library_verify_opts(args),
    do:
      parse_shot_library_verify_opts(args,
        format: :human,
        root: nil,
        library_paths: [],
        lockfile: nil,
        write_lock?: false
      )

  defp parse_shot_library_verify_opts([], opts), do: {:ok, opts}

  defp parse_shot_library_verify_opts(["--write-lock" | rest], opts) do
    parse_shot_library_verify_opts(rest, Keyword.put(opts, :write_lock?, true))
  end

  defp parse_shot_library_verify_opts(["--lockfile", lockfile | rest], opts) do
    parse_shot_library_verify_opts(rest, Keyword.put(opts, :lockfile, lockfile))
  end

  defp parse_shot_library_verify_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_library_verify_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_library_verify_opts(["--root", root | rest], opts) do
    parse_shot_library_verify_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_library_verify_opts(["--library-path", path | rest], opts) do
    parse_shot_library_verify_opts(rest, Keyword.update!(opts, :library_paths, &(&1 ++ [path])))
  end

  defp parse_shot_library_verify_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shot_library_verify_error_format(args) do
    args
    |> parse_shot_library_verify_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp shot_library_verify_opts(opts, root) do
    [
      library_paths: opts[:library_paths],
      root: root[:root],
      lockfile: opts[:lockfile],
      write_lock?: opts[:write_lock?]
    ]
  end

  defp parse_scaffold_library_opts(args),
    do: parse_scaffold_library_opts(args, format: :human, root: nil, scaffold_paths: [])

  defp parse_scaffold_library_opts([], opts), do: {:ok, opts}

  defp parse_scaffold_library_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_scaffold_library_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_scaffold_library_opts(["--root", root | rest], opts) do
    parse_scaffold_library_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_scaffold_library_opts(["--scaffold-path", path | rest], opts) do
    parse_scaffold_library_opts(rest, Keyword.update!(opts, :scaffold_paths, &(&1 ++ [path])))
  end

  defp parse_scaffold_library_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_scaffold_library_error_format(args) do
    args
    |> parse_scaffold_library_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp scaffold_library_opts(opts, root) do
    [scaffold_paths: opts[:scaffold_paths], root: root[:root]]
  end

  defp parse_scaffold_library_verify_opts(args),
    do:
      parse_scaffold_library_verify_opts(args,
        format: :human,
        root: nil,
        scaffold_paths: [],
        lockfile: nil,
        write_lock?: false
      )

  defp parse_scaffold_library_verify_opts([], opts), do: {:ok, opts}

  defp parse_scaffold_library_verify_opts(["--write-lock" | rest], opts) do
    parse_scaffold_library_verify_opts(rest, Keyword.put(opts, :write_lock?, true))
  end

  defp parse_scaffold_library_verify_opts(["--lockfile", lockfile | rest], opts) do
    parse_scaffold_library_verify_opts(rest, Keyword.put(opts, :lockfile, lockfile))
  end

  defp parse_scaffold_library_verify_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} ->
        parse_scaffold_library_verify_opts(rest, Keyword.put(opts, :format, format))

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_scaffold_library_verify_opts(["--root", root | rest], opts) do
    parse_scaffold_library_verify_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_scaffold_library_verify_opts(["--scaffold-path", path | rest], opts) do
    parse_scaffold_library_verify_opts(
      rest,
      Keyword.update!(opts, :scaffold_paths, &(&1 ++ [path]))
    )
  end

  defp parse_scaffold_library_verify_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_scaffold_library_verify_error_format(args) do
    args
    |> parse_scaffold_library_verify_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp scaffold_library_verify_opts(opts, root) do
    [
      scaffold_paths: opts[:scaffold_paths],
      root: root[:root],
      lockfile: opts[:lockfile],
      write_lock?: opts[:write_lock?]
    ]
  end

  defp scaffold_opts(opts, root) do
    [
      scaffold_paths: opts[:scaffold_paths],
      root: root[:root],
      with_mock_agents?: opts[:with_mock_agents?]
    ]
  end

  defp build_added_shot(shot_id, opts, root) do
    if opts[:template] do
      ShotLibrary.expand(opts[:template], shot_id,
        agent: opts[:agent],
        prompt: opts[:prompt],
        description: opts[:description],
        depends_on: opts[:depends_on],
        tools: opts[:tools],
        library_paths: opts[:library_paths],
        root: root[:root]
      )
    else
      shot =
        %{
          "id" => shot_id,
          "kind" => opts[:kind],
          "agent" => opts[:agent],
          "description" => opts[:description],
          "depends_on" => non_empty(opts[:depends_on]),
          "tools" => non_empty(opts[:tools]),
          "prompt" => opts[:prompt]
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      {:ok, shot}
    end
  end

  defp read_schema_file(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, schema} <- Jason.decode(contents) do
      if is_map(schema) do
        {:ok, schema}
      else
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "schema file must contain a JSON object",
           details: %{path: path}
         )}
      end
    else
      {:error, %Jason.DecodeError{} = error} ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "failed to parse schema JSON file",
           details: %{path: path, reason: Exception.message(error)}
         )}

      {:error, reason} ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "unable to read schema file",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp lint_replaced_agent_candidate(path, workflow, new_agent) do
    with {:ok, agents} <- Shell.Loader.load_agents_for_workflow(path),
         :ok <- ensure_replacement_agent_discovered(new_agent, agents) do
      report = ShellLint.run(workflow, path: path, strict?: true, agents: agents)

      if report.status == :ok do
        {:ok, report}
      else
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "replacement agent failed contextual lint",
           details: %{agent: new_agent, findings: ShellLint.to_map(report).findings}
         )}
      end
    else
      {:error, %Twelvgaige.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "agent shell discovery failed",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp ensure_replacement_agent_discovered(new_agent, agents) do
    if Enum.any?(agents, &(&1.id == new_agent)) do
      :ok
    else
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "replacement agent shell was not discovered",
         details: %{agent: new_agent, discovered_agents: Enum.map(agents, & &1.id)}
       )}
    end
  end

  defp lint_replaced_tool_candidate(path, workflow, new_tool) do
    case Shell.Loader.load_agents_for_workflow(path) do
      {:ok, agents} ->
        report = ShellLint.run(workflow, path: path, strict?: true, agents: agents)

        if report.status == :ok do
          {:ok, report}
        else
          {:error,
           Twelvgaige.Error.new(
             :input_error,
             :invalid_shell,
             "replacement tool failed contextual lint",
             details: %{tool: new_tool, findings: ShellLint.to_map(report).findings}
           )}
        end

      {:error, %Twelvgaige.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "agent shell discovery failed",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp lint_split_candidate(path, workflow) do
    case Shell.Loader.load_agents_for_workflow(path) do
      {:ok, agents} ->
        report = ShellLint.run(workflow, path: path, strict?: true, agents: agents)

        if report.status == :ok do
          {:ok, report}
        else
          {:error,
           Twelvgaige.Error.new(
             :input_error,
             :invalid_shell,
             "split workflow failed contextual lint",
             details: %{findings: ShellLint.to_map(report).findings}
           )}
        end

      {:error, %Twelvgaige.Error{} = error} ->
        {:error, error}

      {:error, reason} ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "agent shell discovery failed",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp lint_merge_candidate(path, workflow), do: lint_split_candidate(path, workflow)

  defp csv_values(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp non_empty([]), do: nil
  defp non_empty(values), do: values

  defp parse_shot_remove_opts(args),
    do:
      parse_shot_remove_opts(args,
        format: :human,
        root: nil,
        write?: false,
        cascade?: false,
        yes?: false
      )

  defp parse_shot_remove_opts([], opts), do: {:ok, opts}

  defp parse_shot_remove_opts(["--write" | rest], opts) do
    parse_shot_remove_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shot_remove_opts(["--dry-run" | rest], opts) do
    parse_shot_remove_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shot_remove_opts(["--cascade" | rest], opts) do
    parse_shot_remove_opts(rest, Keyword.put(opts, :cascade?, true))
  end

  defp parse_shot_remove_opts(["--yes" | rest], opts) do
    parse_shot_remove_opts(rest, Keyword.put(opts, :yes?, true))
  end

  defp parse_shot_remove_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_remove_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_remove_opts(["--root", root | rest], opts) do
    parse_shot_remove_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_remove_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shot_remove_error_format(args) do
    args
    |> parse_shot_remove_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shot_move_opts(args),
    do:
      parse_shot_move_opts(args,
        format: :human,
        root: nil,
        write?: false,
        position: nil,
        target_id: nil
      )

  defp parse_shot_move_opts([], opts) do
    if opts[:position] && opts[:target_id] do
      {:ok, opts}
    else
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shot move requires --before or --after"
       )}
    end
  end

  defp parse_shot_move_opts(["--before", target_id | rest], opts),
    do: put_move_target(rest, opts, :before, target_id)

  defp parse_shot_move_opts(["--after", target_id | rest], opts),
    do: put_move_target(rest, opts, :after, target_id)

  defp parse_shot_move_opts(["--write" | rest], opts) do
    parse_shot_move_opts(rest, Keyword.put(opts, :write?, true))
  end

  defp parse_shot_move_opts(["--dry-run" | rest], opts) do
    parse_shot_move_opts(rest, Keyword.put(opts, :write?, false))
  end

  defp parse_shot_move_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shot_move_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shot_move_opts(["--root", root | rest], opts) do
    parse_shot_move_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_shot_move_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp put_move_target(rest, opts, position, target_id) do
    if opts[:position] do
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shot move accepts exactly one --before or --after target"
       )}
    else
      opts =
        opts
        |> Keyword.put(:position, position)
        |> Keyword.put(:target_id, target_id)

      parse_shot_move_opts(rest, opts)
    end
  end

  defp parse_shot_move_error_format(args) do
    args
    |> parse_shot_move_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_reload_opts([], opts), do: {:ok, opts}

  defp parse_shell_reload_opts(["--format", format | rest], opts) do
    parse_shell_reload_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_shell_reload_opts([path | rest], opts) do
    if String.starts_with?(path, "--") do
      {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{path}")}
    else
      parse_shell_reload_opts(rest, Keyword.update!(opts, :paths, &(&1 ++ [path])))
    end
  end

  defp parse_shell_list_opts(args), do: parse_shell_list_opts(args, format: :human, kind: :all)

  defp parse_shell_list_opts([], opts), do: {:ok, opts}

  defp parse_shell_list_opts(["--format", format | rest], opts) do
    parse_shell_list_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_shell_list_opts(["--kind", kind | rest], opts) do
    case parse_shell_kind(kind, [:workflow, :agent, :all]) do
      {:ok, kind} -> parse_shell_list_opts(rest, Keyword.put(opts, :kind, kind))
      {:error, _error} = error -> error
    end
  end

  defp parse_shell_list_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_show_opts(args), do: parse_shell_show_opts(args, format: :human, kind: :any)

  defp parse_shell_show_opts([], opts), do: {:ok, opts}

  defp parse_shell_show_opts(["--format", format | rest], opts) do
    parse_shell_show_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_shell_show_opts(["--kind", kind | rest], opts) do
    case parse_shell_kind(kind, [:workflow, :agent]) do
      {:ok, kind} -> parse_shell_show_opts(rest, Keyword.put(opts, :kind, kind))
      {:error, _error} = error -> error
    end
  end

  defp parse_shell_show_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_lifecycle_args(args, action) do
    parse_shell_lifecycle_opts(args,
      action: action,
      by: nil,
      scope: nil,
      reason: nil,
      evidence_hash: nil,
      expires_at: nil,
      write?: false,
      format: :human,
      root: nil
    )
  end

  defp parse_shell_lifecycle_opts([], opts) do
    cond do
      is_nil(opts[:by]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--by is required")}

      opts[:action] == :approve and is_nil(opts[:scope]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--scope is required")}

      opts[:action] in [:deprecate, :retire] and is_nil(opts[:reason]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--reason is required")}

      true ->
        {:ok, opts}
    end
  end

  defp parse_shell_lifecycle_opts(["--by", by | rest], opts),
    do: parse_shell_lifecycle_opts(rest, Keyword.put(opts, :by, by))

  defp parse_shell_lifecycle_opts(["--scope", scope | rest], opts),
    do: parse_shell_lifecycle_opts(rest, Keyword.put(opts, :scope, scope))

  defp parse_shell_lifecycle_opts(["--reason", reason | rest], opts),
    do: parse_shell_lifecycle_opts(rest, Keyword.put(opts, :reason, reason))

  defp parse_shell_lifecycle_opts(["--evidence-hash", evidence_hash | rest], opts),
    do: parse_shell_lifecycle_opts(rest, Keyword.put(opts, :evidence_hash, evidence_hash))

  defp parse_shell_lifecycle_opts(["--expires-at", expires_at | rest], opts),
    do: parse_shell_lifecycle_opts(rest, Keyword.put(opts, :expires_at, expires_at))

  defp parse_shell_lifecycle_opts(["--write" | rest], opts),
    do: parse_shell_lifecycle_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_shell_lifecycle_opts(["--dry-run" | rest], opts),
    do: parse_shell_lifecycle_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_shell_lifecycle_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_lifecycle_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_lifecycle_opts(["--root", root | rest], opts),
    do: parse_shell_lifecycle_opts(rest, Keyword.put(opts, :root, root))

  defp parse_shell_lifecycle_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_lifecycle_error_format(args, action) do
    args
    |> parse_shell_lifecycle_args(action)
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_metadata_set_opts(args),
    do:
      parse_shell_metadata_set_opts(args,
        owner: nil,
        lifecycle: nil,
        write?: false,
        format: :human,
        root: nil
      )

  defp parse_shell_metadata_set_opts([], opts) do
    if opts[:owner] || opts[:lifecycle] do
      {:ok, opts}
    else
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shell metadata set requires --owner or --lifecycle"
       )}
    end
  end

  defp parse_shell_metadata_set_opts(["--owner", owner | rest], opts),
    do: parse_shell_metadata_set_opts(rest, Keyword.put(opts, :owner, owner))

  defp parse_shell_metadata_set_opts(["--lifecycle", lifecycle | rest], opts),
    do: parse_shell_metadata_set_opts(rest, Keyword.put(opts, :lifecycle, lifecycle))

  defp parse_shell_metadata_set_opts(["--write" | rest], opts),
    do: parse_shell_metadata_set_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_shell_metadata_set_opts(["--dry-run" | rest], opts),
    do: parse_shell_metadata_set_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_shell_metadata_set_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_metadata_set_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_metadata_set_opts(["--root", root | rest], opts),
    do: parse_shell_metadata_set_opts(rest, Keyword.put(opts, :root, root))

  defp parse_shell_metadata_set_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_metadata_set_error_format(args) do
    args
    |> parse_shell_metadata_set_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_metadata_clear_opts(args),
    do:
      parse_shell_metadata_clear_opts(args,
        fields: [],
        write?: false,
        format: :human,
        root: nil
      )

  defp parse_shell_metadata_clear_opts([], opts) do
    if opts[:fields] == [] do
      {:error,
       Twelvgaige.Error.new(
         :input_error,
         :invalid_shell,
         "shell metadata clear requires --review or --approval"
       )}
    else
      {:ok, opts}
    end
  end

  defp parse_shell_metadata_clear_opts(["--review" | rest], opts),
    do: parse_shell_metadata_clear_opts(rest, add_metadata_clear_field(opts, "review"))

  defp parse_shell_metadata_clear_opts(["--approval" | rest], opts),
    do: parse_shell_metadata_clear_opts(rest, add_metadata_clear_field(opts, "approval"))

  defp parse_shell_metadata_clear_opts(["--write" | rest], opts),
    do: parse_shell_metadata_clear_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_shell_metadata_clear_opts(["--dry-run" | rest], opts),
    do: parse_shell_metadata_clear_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_shell_metadata_clear_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_metadata_clear_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_metadata_clear_opts(["--root", root | rest], opts),
    do: parse_shell_metadata_clear_opts(rest, Keyword.put(opts, :root, root))

  defp parse_shell_metadata_clear_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp add_metadata_clear_field(opts, field) do
    Keyword.update!(opts, :fields, &Enum.uniq(&1 ++ [field]))
  end

  defp parse_shell_metadata_clear_error_format(args) do
    args
    |> parse_shell_metadata_clear_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_bulk_replace_opts(args),
    do:
      parse_shell_bulk_replace_opts(args,
        format: :human,
        root: nil,
        output: nil,
        force?: false,
        write?: false,
        yes?: false
      )

  defp parse_shell_bulk_replace_opts([], opts), do: {:ok, opts}

  defp parse_shell_bulk_replace_opts(["--write" | rest], opts),
    do: parse_shell_bulk_replace_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_shell_bulk_replace_opts(["--dry-run" | rest], opts),
    do: parse_shell_bulk_replace_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_shell_bulk_replace_opts(["--yes" | rest], opts),
    do: parse_shell_bulk_replace_opts(rest, Keyword.put(opts, :yes?, true))

  defp parse_shell_bulk_replace_opts(["--format", format | rest], opts) do
    case parse_shell_lint_format(format) do
      {:ok, format} -> parse_shell_bulk_replace_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_shell_bulk_replace_opts(["--root", root | rest], opts),
    do: parse_shell_bulk_replace_opts(rest, Keyword.put(opts, :root, root))

  defp parse_shell_bulk_replace_opts(["--output", output | rest], opts),
    do: parse_shell_bulk_replace_opts(rest, Keyword.put(opts, :output, output))

  defp parse_shell_bulk_replace_opts(["--force" | rest], opts),
    do: parse_shell_bulk_replace_opts(rest, Keyword.put(opts, :force?, true))

  defp parse_shell_bulk_replace_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_bulk_replace_error_format(args) do
    args
    |> parse_shell_bulk_replace_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_shell_kind(kind, allowed) do
    parsed =
      case kind do
        "workflow" -> :workflow
        "agent" -> :agent
        "all" -> :all
        _other -> :invalid
      end

    if parsed in allowed do
      {:ok, parsed}
    else
      allowed = allowed |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")

      {:error,
       Twelvgaige.Error.new(:input_error, :invalid_shell, "--kind must be one of #{allowed}")}
    end
  end

  defp cached_shells(:workflow), do: Twelvgaige.list_shells()
  defp cached_shells(:agent), do: Twelvgaige.list_agents()

  defp cached_shells(:all) do
    with {:ok, workflows} <- Twelvgaige.list_shells(),
         {:ok, agents} <- Twelvgaige.list_agents() do
      {:ok, Enum.sort_by(workflows ++ agents, &{shell_kind(&1), &1.id})}
    end
  end

  defp status(opts) do
    format = Keyword.fetch!(opts, :format)

    case Twelvgaige.status() do
      {:ok, status} -> {:ok, format_status(status, format), 0}
      {:error, :daemon_unavailable} -> {:ok, "daemon unavailable\n", 5}
      {:error, error} -> {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp crypto_status(opts) do
    format = Keyword.fetch!(opts, :format)
    {:ok, format_crypto_status(Twelvgaige.crypto_status(), format), 0}
  end

  defp crypto_sqlcipher_spike(args) do
    with {:ok, opts} <- parse_sqlcipher_spike_opts(args) do
      case Twelvgaige.sqlcipher_spike(sqlcipher_spike_opts(opts)) do
        {:ok, report} ->
          {:ok, format_sqlcipher_spike(report, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_sqlcipher_spike_error(error, opts[:format]), 4}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_sqlcipher_spike_opts(args),
    do: parse_sqlcipher_spike_opts(args, format: :human, path: nil, key_env: nil)

  defp parse_sqlcipher_spike_opts([], opts), do: {:ok, opts}

  defp parse_sqlcipher_spike_opts(["--format", format | rest], opts) do
    parse_sqlcipher_spike_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_sqlcipher_spike_opts(["--path", path | rest], opts) do
    parse_sqlcipher_spike_opts(rest, Keyword.put(opts, :path, path))
  end

  defp parse_sqlcipher_spike_opts(["--key-env", env | rest], opts) do
    parse_sqlcipher_spike_opts(rest, Keyword.put(opts, :key_env, env))
  end

  defp parse_sqlcipher_spike_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp sqlcipher_spike_opts(opts) do
    []
    |> maybe_put(:path, opts[:path])
    |> maybe_put(:key_env, opts[:key_env])
  end

  defp store_backup(destination, args) do
    with {:ok, opts} <- parse_store_backup_opts(args) do
      case Twelvgaige.store_backup(destination,
             allow_plaintext_export?: opts[:allow_plaintext_export?]
           ) do
        {:ok, report} ->
          {:ok, format_store_backup(report, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_store_error(error, opts[:format]), store_error_exit_code(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp store_restore(source, destination, args) do
    with {:ok, opts} <- parse_store_restore_opts(args) do
      case Twelvgaige.store_restore_backup(source, destination, replace?: opts[:replace?]) do
        {:ok, report} ->
          {:ok, format_store_restore(report, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_store_error(error, opts[:format]), store_error_exit_code(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp store_migrate_sqlcipher(args) do
    with {:ok, opts} <- parse_store_migrate_sqlcipher_opts(args) do
      case Twelvgaige.store_migrate_plaintext_to_encrypted(opts[:source], opts[:destination],
             key_env: opts[:key_env],
             replace?: opts[:replace?]
           ) do
        {:ok, report} ->
          {:ok, format_store_migration(report, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_store_error(error, opts[:format]), store_error_exit_code(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp store_rewrap_envelope(path, args) do
    with {:ok, opts} <- parse_store_rewrap_envelope_opts(args) do
      case Twelvgaige.store_rewrap_envelope(path,
             backup: opts[:backup],
             old_key_env: opts[:old_key_env],
             new_key_env: opts[:new_key_env]
           ) do
        {:ok, report} ->
          {:ok, format_store_rewrap(report, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_store_error(error, opts[:format]), store_error_exit_code(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_store_backup_opts(args),
    do: parse_store_backup_opts(args, format: :human, allow_plaintext_export?: false)

  defp parse_store_backup_opts([], opts), do: {:ok, opts}

  defp parse_store_backup_opts(["--allow-plaintext-export" | rest], opts) do
    parse_store_backup_opts(rest, Keyword.put(opts, :allow_plaintext_export?, true))
  end

  defp parse_store_backup_opts(["--format", format | rest], opts) do
    parse_store_backup_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_store_backup_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_store_restore_opts(args),
    do: parse_store_restore_opts(args, format: :human, replace?: false)

  defp parse_store_restore_opts([], opts), do: {:ok, opts}

  defp parse_store_restore_opts(["--replace" | rest], opts) do
    parse_store_restore_opts(rest, Keyword.put(opts, :replace?, true))
  end

  defp parse_store_restore_opts(["--format", format | rest], opts) do
    parse_store_restore_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_store_restore_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_store_migrate_sqlcipher_opts(args),
    do:
      parse_store_migrate_sqlcipher_opts(args,
        format: :human,
        source: nil,
        destination: nil,
        key_env: nil,
        replace?: false
      )

  defp parse_store_migrate_sqlcipher_opts([], opts) do
    cond do
      is_nil(opts[:source]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--source is required")}

      is_nil(opts[:destination]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--destination is required")}

      is_nil(opts[:key_env]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--key-env is required")}

      true ->
        {:ok, opts}
    end
  end

  defp parse_store_migrate_sqlcipher_opts(["--source", source | rest], opts) do
    parse_store_migrate_sqlcipher_opts(rest, Keyword.put(opts, :source, source))
  end

  defp parse_store_migrate_sqlcipher_opts(["--destination", destination | rest], opts) do
    parse_store_migrate_sqlcipher_opts(rest, Keyword.put(opts, :destination, destination))
  end

  defp parse_store_migrate_sqlcipher_opts(["--key-env", key_env | rest], opts) do
    parse_store_migrate_sqlcipher_opts(rest, Keyword.put(opts, :key_env, key_env))
  end

  defp parse_store_migrate_sqlcipher_opts(["--replace" | rest], opts) do
    parse_store_migrate_sqlcipher_opts(rest, Keyword.put(opts, :replace?, true))
  end

  defp parse_store_migrate_sqlcipher_opts(["--format", format | rest], opts) do
    parse_store_migrate_sqlcipher_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_store_migrate_sqlcipher_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_store_rewrap_envelope_opts(args),
    do:
      parse_store_rewrap_envelope_opts(args,
        format: :human,
        backup: nil,
        old_key_env: nil,
        new_key_env: nil
      )

  defp parse_store_rewrap_envelope_opts([], opts) do
    cond do
      is_nil(opts[:backup]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--backup is required")}

      is_nil(opts[:old_key_env]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--old-key-env is required")}

      is_nil(opts[:new_key_env]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--new-key-env is required")}

      true ->
        {:ok, opts}
    end
  end

  defp parse_store_rewrap_envelope_opts(["--backup", backup | rest], opts) do
    parse_store_rewrap_envelope_opts(rest, Keyword.put(opts, :backup, backup))
  end

  defp parse_store_rewrap_envelope_opts(["--old-key-env", env | rest], opts) do
    parse_store_rewrap_envelope_opts(rest, Keyword.put(opts, :old_key_env, env))
  end

  defp parse_store_rewrap_envelope_opts(["--new-key-env", env | rest], opts) do
    parse_store_rewrap_envelope_opts(rest, Keyword.put(opts, :new_key_env, env))
  end

  defp parse_store_rewrap_envelope_opts(["--format", format | rest], opts) do
    parse_store_rewrap_envelope_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_store_rewrap_envelope_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, _key, ""), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp run_round(path, args) do
    with {:ok, opts} <- parse_round_opts(args),
         {:ok, input} <- read_input(opts.input) do
      format = opts.format

      case run_round_mode(path, input, opts) do
        {:ok, %Snapshot{} = snapshot} ->
          {:ok, format_snapshot(snapshot, format), ExitCode.for_snapshot(snapshot)}

        {:ok, round_id} when is_binary(round_id) ->
          {:ok, format_detached_round(round_id, format), 0}

        {:error, error} ->
          {:ok, format_command_error(error, format), ExitCode.for_error(error)}
      end
    else
      {:error, error} ->
        {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_round_opts(args),
    do:
      parse_round_opts(args, %{
        input: nil,
        format: :human,
        profile: nil,
        admission_policy: nil,
        approve_safety?: false,
        detach?: false,
        agent_shells: [],
        discover_agents?: true,
        trusted_root?: true
      })

  defp parse_round_opts([], %{input: nil} = opts), do: {:ok, %{opts | input: "{}"}}

  defp parse_round_opts([], opts), do: {:ok, opts}

  defp parse_round_opts(["--input", input | rest], opts) do
    parse_round_opts(rest, %{opts | input: input})
  end

  defp parse_round_opts(["--format", format | rest], opts) do
    parse_round_opts(rest, %{opts | format: parse_format(format)})
  end

  defp parse_round_opts(["--profile", profile | rest], opts) do
    case Twelvgaige.RuntimeProfile.normalize(profile) do
      {:ok, profile} ->
        parse_round_opts(rest, %{opts | profile: profile})

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_round_opts(["--admission", policy | rest], opts) do
    case ShellAdmission.normalize_policy(policy) do
      {:ok, :manual} ->
        parse_round_opts(rest, %{opts | admission_policy: nil})

      {:ok, policy} ->
        parse_round_opts(rest, %{opts | admission_policy: policy})

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_round_opts(["--agent-shell", path | rest], opts) do
    parse_round_opts(rest, %{opts | agent_shells: opts.agent_shells ++ [path]})
  end

  defp parse_round_opts(["--no-agent-discovery" | rest], opts) do
    parse_round_opts(rest, %{opts | discover_agents?: false})
  end

  defp parse_round_opts(["--untrusted-root" | rest], opts) do
    parse_round_opts(rest, %{opts | trusted_root?: false})
  end

  defp parse_round_opts(["--approve-safety" | rest], opts) do
    parse_round_opts(rest, %{opts | approve_safety?: true})
  end

  defp parse_round_opts(["--detach" | rest], opts) do
    parse_round_opts(rest, %{opts | detach?: true})
  end

  defp parse_round_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_format("json"), do: :json
  defp parse_format("human"), do: :human
  defp parse_format(_other), do: :human

  defp parse_shell_document_format("json"), do: {:ok, :json}
  defp parse_shell_document_format("yaml"), do: {:ok, :yaml}
  defp parse_shell_document_format("toml"), do: {:ok, :toml}

  defp parse_shell_document_format(_format) do
    {:error,
     Twelvgaige.Error.new(:input_error, :invalid_shell, "format must be json, yaml, or toml")}
  end

  defp shell_new_format(opts) do
    case Keyword.get(opts, :format) do
      nil -> infer_shell_document_format(Keyword.get(opts, :output))
      format -> {:ok, format}
    end
  end

  defp infer_shell_document_format(nil), do: {:ok, :yaml}

  defp infer_shell_document_format(path) do
    case path |> Path.extname() |> String.downcase() do
      ".json" -> {:ok, :json}
      ".toml" -> {:ok, :toml}
      ".yaml" -> {:ok, :yaml}
      ".yml" -> {:ok, :yaml}
      _extension -> {:ok, :yaml}
    end
  end

  defp shell_document_extension(:json), do: ".json"
  defp shell_document_extension(:toml), do: ".toml"
  defp shell_document_extension(:yaml), do: ".yaml"

  defp parse_shell_graph_format("text"), do: {:ok, :text}
  defp parse_shell_graph_format("json"), do: {:ok, :json}
  defp parse_shell_graph_format("mermaid"), do: {:ok, :mermaid}

  defp parse_shell_graph_format(_format) do
    {:error,
     Twelvgaige.Error.new(:input_error, :invalid_shell, "format must be text, json, or mermaid")}
  end

  defp parse_shell_lint_format("human"), do: {:ok, :human}
  defp parse_shell_lint_format("json"), do: {:ok, :json}

  defp parse_shell_lint_format(_format) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "format must be human or json")}
  end

  defp root_opts(opts) do
    case Keyword.get(opts, :root) do
      nil -> []
      root -> [root: root]
    end
  end

  defp shell_draft_opts(opts) do
    [
      provider: opts[:provider],
      model: opts[:model],
      allow_remote?: opts[:allow_remote?],
      max_input_bytes: opts[:max_input_bytes],
      format: opts[:format]
    ]
  end

  defp shell_author_review_opts(opts) do
    [
      provider: opts[:provider],
      model: opts[:model],
      allow_remote?: opts[:allow_remote?],
      max_input_bytes: opts[:max_input_bytes]
    ]
  end

  defp patch_opts(_opts, %{root: root}) do
    [root: root]
  end

  defp patch_verify_opts(opts, root) do
    patch_opts(opts, root) ++ [approval: opts[:approval]]
  end

  defp patch_apply_opts(opts, root) do
    patch_verify_opts(opts, root) ++ [write?: opts[:write?]]
  end

  defp read_draft_source("-"), do: {:ok, IO.read(:stdio, :eof)}

  defp read_draft_source(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "unable to read draft source",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp graph_error_format(:json), do: :json
  defp graph_error_format(_format), do: :human

  defp parse_watch_format("ndjson"), do: :ndjson
  defp parse_watch_format("human"), do: :human
  defp parse_watch_format(_other), do: :human

  defp parse_audit_format("json"), do: :json
  defp parse_audit_format("checkpoint"), do: :checkpoint
  defp parse_audit_format(format), do: parse_watch_format(format)

  defp round_run_opts(opts) do
    []
    |> maybe_put_profile(opts)
    |> maybe_put_admission_policy(opts)
    |> maybe_put_approve_all_safety(opts)
    |> maybe_put_agent_shells(opts)
    |> maybe_put_agent_discovery(opts)
  end

  defp maybe_put_profile(run_opts, %{profile: nil}), do: run_opts

  defp maybe_put_profile(run_opts, %{profile: profile}) do
    Keyword.put(run_opts, :profile, profile)
  end

  defp maybe_put_admission_policy(run_opts, %{admission_policy: nil}), do: run_opts

  defp maybe_put_admission_policy(run_opts, %{admission_policy: policy}) do
    Keyword.put(run_opts, :admission_policy, policy)
  end

  defp maybe_put_approve_all_safety(run_opts, %{approve_safety?: true}) do
    Keyword.put(run_opts, :approve_all_safety?, true)
  end

  defp maybe_put_approve_all_safety(run_opts, _opts), do: run_opts

  defp maybe_put_agent_shells(run_opts, %{agent_shells: []}), do: run_opts

  defp maybe_put_agent_shells(run_opts, %{agent_shells: agent_shells}) do
    Keyword.put(run_opts, :agent_shells, agent_shells)
  end

  defp maybe_put_agent_discovery(run_opts, opts) do
    run_opts
    |> Keyword.put(:discover_agents?, opts.discover_agents?)
    |> Keyword.put(:trusted_root?, opts.trusted_root?)
  end

  defp run_round_mode(path, input, %{detach?: true} = opts) do
    Twelvgaige.run_round(path, input, round_run_opts(opts))
  end

  defp run_round_mode(path, input, opts) do
    Twelvgaige.run_round_sync(path, input, round_run_opts(opts))
  end

  defp list_rounds(args) do
    with {:ok, opts} <- parse_list_opts(args) do
      case Twelvgaige.list_rounds(Keyword.take(opts, [:status])) do
        {:ok, rounds} ->
          {:ok, format_round_list(rounds, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_list_opts(args), do: parse_list_opts(args, format: :human)

  defp parse_list_opts([], opts), do: {:ok, opts}

  defp parse_list_opts(["--format", format | rest], opts) do
    parse_list_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_list_opts(["--status", status | rest], opts) do
    parse_list_opts(rest, Keyword.put(opts, :status, status))
  end

  defp parse_list_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp show_round(round_id, args) do
    with {:ok, opts} <- parse_show_opts(args) do
      case Twelvgaige.get_round(round_id) do
        {:ok, snapshot} ->
          {:ok, format_snapshot(snapshot, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_show_opts(args), do: parse_show_opts(args, format: :human)

  defp parse_show_opts([], opts), do: {:ok, opts}

  defp parse_show_opts(["--format", format | rest], opts) do
    parse_show_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_show_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp watch_round(round_id, args) do
    with {:ok, opts} <- parse_watch_opts(args) do
      case Watch.collect(round_id, opts) do
        {:ok, events} ->
          {:ok, format_events(events, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp stream_watch_round(round_id, args, write) do
    with {:ok, opts} <- parse_watch_opts(args) do
      result =
        Watch.stream(
          round_id,
          fn events ->
            write.(format_events(events, opts[:format]))
            :ok
          end,
          opts
        )

      case result do
        {:ok, %{delivered: 0}} ->
          write.(format_events([], opts[:format]))
          :ok

        {:ok, _summary} ->
          :ok

        {:error, error} ->
          output = format_command_error(error, :human)
          IO.write(:stderr, output)
          System.halt(ExitCode.for_error(error))

        {:halt, reason} ->
          output = format_command_error(reason, :human)
          IO.write(:stderr, output)
          System.halt(ExitCode.for_error(reason))
      end
    else
      {:error, error} ->
        output = format_command_error(error, :human)
        IO.write(:stderr, output)
        System.halt(ExitCode.for_error(error))
    end
  end

  defp parse_watch_opts(args),
    do:
      parse_watch_opts(args,
        format: :human,
        after_seq: 0,
        limit: 100,
        follow?: false,
        until_terminal?: false,
        timeout_ms: 30_000
      )

  defp parse_watch_opts([], opts), do: {:ok, opts}

  defp parse_watch_opts(["--format", format | rest], opts) do
    parse_watch_opts(rest, Keyword.put(opts, :format, parse_watch_format(format)))
  end

  defp parse_watch_opts(["--after-seq", seq | rest], opts) do
    case parse_non_negative_integer(seq) do
      {:ok, seq} ->
        parse_watch_opts(rest, Keyword.put(opts, :after_seq, seq))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--after-seq must be >= 0")}
    end
  end

  defp parse_watch_opts(["--limit", limit | rest], opts) do
    case parse_positive_integer(limit) do
      {:ok, limit} ->
        parse_watch_opts(rest, Keyword.put(opts, :limit, limit))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--limit must be > 0")}
    end
  end

  defp parse_watch_opts(["--follow" | rest], opts) do
    parse_watch_opts(rest, Keyword.put(opts, :follow?, true))
  end

  defp parse_watch_opts(["--until-terminal" | rest], opts) do
    opts =
      opts
      |> Keyword.put(:follow?, true)
      |> Keyword.put(:until_terminal?, true)

    parse_watch_opts(rest, opts)
  end

  defp parse_watch_opts(["--timeout-ms", timeout_ms | rest], opts) do
    case parse_non_negative_integer(timeout_ms) do
      {:ok, timeout_ms} ->
        parse_watch_opts(rest, Keyword.put(opts, :timeout_ms, timeout_ms))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--timeout-ms must be >= 0")}
    end
  end

  defp parse_watch_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp audit_round(round_id, args) do
    with {:ok, opts} <- parse_audit_opts(args) do
      case Twelvgaige.list_audit_events(round_id, Keyword.take(opts, [:after_seq, :limit])) do
        {:ok, events} ->
          case format_audit_events(events, opts) do
            {:ok, output} ->
              {:ok, output, 0}

            {:error, error} ->
              {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
          end

        {:error, error} ->
          {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_audit_opts(args),
    do: parse_audit_opts(args, format: :human, after_seq: 0, limit: 100, sign_hmac_env: nil)

  defp parse_audit_opts([], opts), do: {:ok, opts}

  defp parse_audit_opts(["--format", format | rest], opts) do
    parse_audit_opts(rest, Keyword.put(opts, :format, parse_audit_format(format)))
  end

  defp parse_audit_opts(["--after-seq", seq | rest], opts) do
    case parse_non_negative_integer(seq) do
      {:ok, seq} ->
        parse_audit_opts(rest, Keyword.put(opts, :after_seq, seq))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--after-seq must be >= 0")}
    end
  end

  defp parse_audit_opts(["--limit", limit | rest], opts) do
    case parse_positive_integer(limit) do
      {:ok, limit} ->
        parse_audit_opts(rest, Keyword.put(opts, :limit, limit))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--limit must be > 0")}
    end
  end

  defp parse_audit_opts(["--sign-hmac-env", env | rest], opts) do
    parse_audit_opts(rest, Keyword.put(opts, :sign_hmac_env, env))
  end

  defp parse_audit_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp verify_audit_checkpoint(path, args) do
    case parse_audit_verify_opts(args) do
      {:ok, opts} ->
        with {:ok, contents} <- read_audit_checkpoint(path),
             {:ok, checkpoint} <- decode_audit_checkpoint(contents, path) do
          case Twelvgaige.Audit.Checkpoint.verify(checkpoint) do
            :ok ->
              case maybe_verify_checkpoint_hmac(checkpoint, opts) do
                :ok ->
                  {:ok, format_audit_verify_ok(checkpoint, opts[:format]), 0}

                {:error, %Twelvgaige.Error{} = error} ->
                  {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}

                {:error, reason} ->
                  {:ok, format_audit_verify_error(reason, opts[:format]), 1}
              end

            {:error, reason} ->
              {:ok, format_audit_verify_error(reason, opts[:format]), 1}
          end
        else
          {:error, error} ->
            {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
        end

      {:error, error} ->
        {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_audit_verify_opts(args),
    do: parse_audit_verify_opts(args, format: :human, hmac_env: nil)

  defp parse_audit_verify_opts([], opts), do: {:ok, opts}

  defp parse_audit_verify_opts(["--format", format | rest], opts) do
    parse_audit_verify_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_audit_verify_opts(["--hmac-env", env | rest], opts) do
    parse_audit_verify_opts(rest, Keyword.put(opts, :hmac_env, env))
  end

  defp parse_audit_verify_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp read_audit_checkpoint("-"), do: {:ok, IO.read(:stdio, :eof)}

  defp read_audit_checkpoint(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "unable to read audit checkpoint",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp decode_audit_checkpoint(contents, source) do
    case Jason.decode(contents) do
      {:ok, checkpoint} when is_map(checkpoint) ->
        {:ok, checkpoint}

      {:ok, _other} ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "audit checkpoint must be a JSON object",
           details: %{source: source}
         )}

      {:error, error} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "invalid audit checkpoint JSON",
           details: %{source: source, reason: Exception.message(error)}
         )}
    end
  end

  defp maybe_verify_checkpoint_hmac(checkpoint, opts) do
    case opts[:hmac_env] do
      nil ->
        :ok

      env ->
        with {:ok, key} <- hmac_key_from_env(env) do
          Twelvgaige.Audit.Checkpoint.verify_hmac(checkpoint, key)
        end
    end
  end

  defp hmac_key_from_env(env) when is_binary(env) and env != "" do
    case System.get_env(env) do
      nil ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "HMAC key env is not set",
           details: %{env: env}
         )}

      "" ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "HMAC key env is empty",
           details: %{env: env}
         )}

      "base64:" <> encoded ->
        case Base.decode64(encoded) do
          {:ok, key} ->
            {:ok, key}

          :error ->
            {:error,
             Twelvgaige.Error.new(:input_error, :invalid_shell, "HMAC key env is invalid base64",
               details: %{env: env}
             )}
        end

      key ->
        {:ok, key}
    end
  end

  defp hmac_key_from_env(_env) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "HMAC key env is required")}
  end

  defp safety_decision(decision, round_id, args) do
    with {:ok, opts} <- parse_safety_opts(args),
         {:ok, shot_id} <- required_safety_shot(opts) do
      result =
        case decision do
          :approve ->
            Twelvgaige.approve_safety(round_id, shot_id,
              reason: opts[:reason],
              actor: "human:cli"
            )

          :reject ->
            Twelvgaige.reject_safety(round_id, shot_id,
              reason: opts[:reason],
              actor: "human:cli"
            )
        end

      case result do
        :ok ->
          {:ok, format_safety_decision(decision, round_id, shot_id, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_safety_opts(args), do: parse_safety_opts(args, format: :human)

  defp parse_safety_opts([], opts), do: {:ok, opts}

  defp parse_safety_opts(["--shot", shot_id | rest], opts) do
    parse_safety_opts(rest, Keyword.put(opts, :shot_id, shot_id))
  end

  defp parse_safety_opts(["--reason", reason | rest], opts) do
    parse_safety_opts(rest, Keyword.put(opts, :reason, reason))
  end

  defp parse_safety_opts(["--format", format | rest], opts) do
    parse_safety_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_safety_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp required_safety_shot(opts) do
    case Keyword.get(opts, :shot_id) do
      shot_id when is_binary(shot_id) and shot_id != "" ->
        {:ok, shot_id}

      _missing ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--shot is required")}
    end
  end

  defp cancel_round(round_id, args) do
    with {:ok, opts} <- parse_cancel_opts(args) do
      case Twelvgaige.cancel_round(round_id, reason: opts[:reason], actor: "human:cli") do
        :ok ->
          {:ok, format_cancel(round_id, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_cancel_opts(args), do: parse_cancel_opts(args, format: :human)

  defp parse_cancel_opts([], opts), do: {:ok, opts}

  defp parse_cancel_opts(["--reason", reason | rest], opts) do
    parse_cancel_opts(rest, Keyword.put(opts, :reason, reason))
  end

  defp parse_cancel_opts(["--format", format | rest], opts) do
    parse_cancel_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_cancel_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp read_input("-") do
    :stdio
    |> IO.read(:eof)
    |> decode_json("stdin")
  end

  defp read_input(input) when is_binary(input) do
    trimmed = String.trim_leading(input)

    if String.starts_with?(trimmed, ["{", "["]) do
      decode_json(input, "inline JSON")
    else
      case File.read(input) do
        {:ok, contents} ->
          decode_json(contents, input)

        {:error, reason} ->
          {:error,
           Twelvgaige.Error.new(:input_error, :invalid_shell, "unable to read input file",
             details: %{path: input, reason: inspect(reason)}
           )}
      end
    end
  end

  defp decode_json(contents, source) do
    case Jason.decode(contents) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "round input must be a JSON object",
           details: %{source: source}
         )}

      {:error, error} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "invalid JSON input",
           details: %{source: source, reason: Exception.message(error)}
         )}
    end
  end

  defp format_shell(%Shell.Workflow{} = shell, :human) do
    "valid workflow shell: #{shell.id} #{shell.version}\n"
  end

  defp format_shell(%Shell.Agent{} = shell, :human) do
    "valid agent shell: #{shell.id} #{shell.version || "unversioned"}\n"
  end

  defp format_shell(shell, :json) do
    shell
    |> shell_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_detail(%Shell.Workflow{} = shell, :human) do
    shots =
      shell.shots
      |> Enum.map(&"  - #{&1.id} [#{&1.kind}]")
      |> Enum.join("\n")

    """
    Workflow shell: #{shell.id} #{shell.version}
    Name: #{shell.name || ""}
    Shots:
    #{shots}
    """
  end

  defp format_shell_detail(%Shell.Agent{} = shell, :human) do
    """
    Agent shell: #{shell.id} #{shell.version || "unversioned"}
    Name: #{shell.name || ""}
    Provider: #{shell.provider}
    Model: #{shell.model}
    """
  end

  defp format_shell_detail(shell, :json), do: format_shell(shell, :json)

  defp format_shell_fmt(result, :json, mode) do
    result
    |> ShellFormatter.to_map()
    |> Map.merge(%{
      mode: Atom.to_string(mode),
      wrote: mode == :write and result.changed?,
      status: if(result.changed?, do: "changed", else: "ok"),
      exit_code: if(mode == :check and result.changed?, do: 1, else: 0)
    })
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shell_fmt(result, :human, :check) do
    if result.changed? do
      "shell fmt check failed: #{result.path} is not canonical\n"
    else
      "shell fmt check passed: #{result.path}\n"
    end
  end

  defp format_shell_fmt(result, :human, :write) do
    if result.changed? do
      """
      formatted shell: #{result.path}
      kind: #{result.kind}
      id: #{result.id}
      wrote: true
      """
    else
      "shell already formatted: #{result.path}\n"
    end
  end

  defp format_shell_fmt(result, :human, :dry_run) do
    if result.changed? do
      """
      dry run: shell fmt #{result.path}
      kind: #{result.kind}
      id: #{result.id}
      wrote: false

      #{result.diff}
      """
    else
      "shell already formatted: #{result.path}\n"
    end
  end

  defp format_shell_lifecycle(result, :json, wrote?) do
    %{
      path: result.path,
      action: Atom.to_string(result.action),
      lifecycle: Atom.to_string(result.lifecycle),
      actor: result.actor,
      scope: result.scope,
      reason: result.reason,
      digest: result.digest,
      format: Atom.to_string(result.format),
      wrote: wrote?,
      diff: result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shell_lifecycle(result, :human, true) do
    """
    marked workflow #{result.action}: #{result.path}
    lifecycle: #{result.lifecycle}
    actor: #{result.actor}
    scope: #{result.scope || "none"}
    reason: #{result.reason || "none"}
    digest: #{result.digest}
    wrote: true
    """
  end

  defp format_shell_lifecycle(result, :human, false) do
    """
    dry run: shell #{result.action} #{result.path}
    lifecycle: #{result.lifecycle}
    actor: #{result.actor}
    scope: #{result.scope || "none"}
    reason: #{result.reason || "none"}
    digest: #{result.digest}
    wrote: false

    #{result.diff}
    """
  end

  defp format_shell_metadata(result, :json, wrote?) do
    %{
      path: result.path,
      action: Atom.to_string(result.action),
      changed_fields: result.changed_fields,
      cleared_fields: result.cleared_fields,
      format: Atom.to_string(result.format),
      wrote: wrote?,
      diff: result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shell_metadata(%{action: :set} = result, :human, true) do
    """
    updated workflow metadata: #{result.path}
    changed fields: #{Enum.join(result.changed_fields, ", ")}
    wrote: true
    """
  end

  defp format_shell_metadata(%{action: :set} = result, :human, false) do
    """
    dry run: shell metadata set #{result.path}
    changed fields: #{Enum.join(result.changed_fields, ", ")}
    wrote: false

    #{result.diff}
    """
  end

  defp format_shell_metadata(%{action: :clear} = result, :human, true) do
    """
    cleared workflow metadata: #{result.path}
    cleared fields: #{Enum.join(result.cleared_fields, ", ")}
    wrote: true
    """
  end

  defp format_shell_metadata(%{action: :clear} = result, :human, false) do
    """
    dry run: shell metadata clear #{result.path}
    cleared fields: #{Enum.join(result.cleared_fields, ", ")}
    wrote: false

    #{result.diff}
    """
  end

  defp format_shell_graph(graph, :json) do
    graph
    |> ShellGraph.to_map()
    |> Map.merge(%{status: "ok", exit_code: 0, errors: []})
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_graph(graph, :mermaid), do: ShellGraph.to_mermaid(graph)

  defp format_shell_graph(graph, :text) do
    groups =
      graph.groups
      |> Enum.with_index(1)
      |> Enum.map(fn {group, index} -> "  #{index}. #{Enum.join(group, ", ")}" end)
      |> Enum.join("\n")

    edges =
      case graph.edges do
        [] ->
          "  none"

        edges ->
          edges
          |> Enum.map(&"  #{&1.from} -> #{&1.to}")
          |> Enum.join("\n")
      end

    nodes =
      graph.nodes
      |> Enum.map(fn node ->
        flags =
          []
          |> maybe_flag(node.safety, "safety")
          |> maybe_flag(node.write_capable, "write")
          |> case do
            [] -> ""
            flags -> " [" <> Enum.join(Enum.reverse(flags), ", ") <> "]"
          end

        deps =
          case node.dependencies do
            [] -> "root"
            deps -> "depends on " <> Enum.join(deps, ", ")
          end

        "  - #{node.id} [#{node.kind}] #{deps}#{flags}"
      end)
      |> Enum.join("\n")

    """
    Workflow graph: #{graph.workflow_id} #{graph.version}
    Groups:
    #{groups}
    Edges:
    #{edges}
    Shots:
    #{nodes}
    """
  end

  defp maybe_flag(flags, true, flag), do: [flag | flags]
  defp maybe_flag(flags, false, _flag), do: flags

  defp format_shell_lint(report, :json) do
    report
    |> ShellLint.to_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_lint(%{reports: reports} = report, :human) do
    findings = Enum.flat_map(reports, & &1.findings)
    errors = Map.get(report, :errors, [])

    body =
      cond do
        errors != [] ->
          errors
          |> Enum.map(&"  [error] #{&1.path} - #{get_in(&1, [:error, :message])}")
          |> Enum.join("\n")

        findings == [] ->
          "  No findings."

        true ->
          reports
          |> Enum.flat_map(&format_lint_report_lines/1)
          |> Enum.join("\n")
      end

    """
    Shell lint: #{report.path}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Workflows: #{length(reports)}
    Findings: #{length(findings)}
    #{body}
    """
  end

  defp format_shell_lint(report, :human) do
    lines = format_lint_report_lines(report)

    body =
      case lines do
        [] -> "  No findings."
        lines -> Enum.join(lines, "\n")
      end

    """
    Shell lint: #{report.path}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Findings: #{length(report.findings)}
    #{body}
    """
  end

  defp format_shell_admission(path, report, :json) do
    report
    |> ShellAdmission.to_map()
    |> Map.put(:path, path)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_admission(path, report, :human) do
    body =
      case report.findings do
        [] ->
          "  Admitted."

        findings ->
          findings
          |> Enum.map(fn finding ->
            "  [#{finding.severity}] #{finding.id} - #{finding.message}"
          end)
          |> Enum.join("\n")
      end

    """
    Shell admission: #{path}
    Policy: #{report.policy}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Findings: #{length(report.findings)}
    #{body}
    """
  end

  defp format_lint_report_lines(report) do
    Enum.map(report.findings, fn finding ->
      location = lint_location(finding.location)
      "  [#{finding.severity}] #{finding.id}#{location} - #{finding.message}"
    end)
  end

  defp lint_location(%{shot_id: nil}), do: ""
  defp lint_location(%{shot_id: shot_id}), do: " shot=#{shot_id}"
  defp lint_location(_location), do: ""

  defp format_shell_doctor(report, :json) do
    report
    |> ShellDoctor.to_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_doctor(report, :human) do
    body =
      case report.recommendations do
        [] ->
          "  No recommendations."

        recommendations ->
          recommendations
          |> Enum.map(fn recommendation ->
            shot =
              case recommendation.shot_id do
                nil -> ""
                shot_id -> " shot=#{shot_id}"
              end

            "  [#{recommendation.severity}] #{recommendation.id}#{shot} - #{recommendation.action}"
          end)
          |> Enum.join("\n")
      end

    """
    Shell doctor: #{report.path}
    Workflow: #{report.workflow_id} #{report.version}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Recommendations: #{length(report.recommendations)}
    #{body}
    """
  end

  defp format_shell_inventory(report, :json) do
    report
    |> ShellInventory.to_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_inventory(report, :human) do
    summary = report.summary

    workflows =
      case report.workflows do
        [] ->
          "  none"

        workflows ->
          workflows
          |> Enum.map(fn workflow ->
            lifecycle = Map.get(workflow, "lifecycle", "none")
            owner = Map.get(workflow, "owner", "none")
            write = if Map.get(workflow, "write_capable", false), do: " write", else: ""

            "  - #{workflow["id"]} #{workflow["version"]} owner=#{owner} lifecycle=#{lifecycle}#{write}"
          end)
          |> Enum.join("\n")
      end

    errors =
      case report.errors do
        [] ->
          "  none"

        errors ->
          errors
          |> Enum.map(&"  - #{&1["path"]}: #{get_in(&1, ["error", "message"])}")
          |> Enum.join("\n")
      end

    """
    Shell inventory: #{report.path}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Workflows: #{summary["workflow_count"]}
    Agents: #{summary["agent_count"]}
    Tools: #{summary["tool_count"]}
    Errors: #{summary["error_count"]}
    Workflow shells:
    #{workflows}
    Invalid shells:
    #{errors}
    """
  end

  defp format_shell_impact(report, :json) do
    report
    |> ShellImpact.to_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_impact(report, :human) do
    matches =
      case report.matches do
        [] ->
          "  none"

        matches ->
          matches
          |> Enum.map(fn match ->
            shots =
              match
              |> Map.get("matching_shots", [])
              |> Enum.map(& &1["id"])
              |> case do
                [] -> ""
                shot_ids -> " shots=" <> Enum.join(shot_ids, ",")
              end

            "  - #{match["id"]} #{match["version"]}#{shots} path=#{match["path"]}"
          end)
          |> Enum.join("\n")
      end

    """
    Shell impact: #{report.path}
    Selector: #{report.selector["kind"]}=#{report.selector["value"]}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Workflows: #{report.summary["workflow_count"]}
    Shots: #{report.summary["shot_count"]}
    Errors: #{report.summary["error_count"]}
    Matches:
    #{matches}
    """
  end

  defp format_shell_bulk_refactor(report, :json) do
    report
    |> ShellBulkRefactor.to_map()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shell_bulk_refactor(report, :human) do
    changes =
      case report.changes do
        [] ->
          "  none"

        changes ->
          changes
          |> Enum.map(fn change ->
            shots = change["changed_shot_ids"] |> Enum.join(",")
            "  - #{change["path"]} shots=#{shots} wrote=#{change["wrote"]}"
          end)
          |> Enum.join("\n")
      end

    errors =
      case report.errors do
        [] ->
          "  none"

        errors ->
          errors
          |> Enum.map(&"  - #{&1["path"]}: #{get_in(&1, ["error", "message"])}")
          |> Enum.join("\n")
      end

    """
    Shell #{bulk_refactor_label(report)}: #{report.path}
    Mode: #{String.upcase(Atom.to_string(report.mode))}
    Status: #{String.upcase(Atom.to_string(report.status))}
    Changed workflows: #{report.summary["changed_workflows"]}
    Changed shots: #{report.summary["changed_shots"]}
    Errors: #{report.summary["error_count"]}
    Changes:
    #{changes}
    Errors:
    #{errors}
    """
  end

  defp format_shot_rename(result, :json, wrote?) do
    %{
      "path" => result.path,
      "old_id" => result.old_id,
      "new_id" => result.new_id,
      "format" => Atom.to_string(result.format),
      "updated_dependencies" => result.updated_dependencies,
      "updated_conditions" => result.updated_conditions,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_rename(result, :human, true) do
    """
    renamed shot: #{result.old_id} -> #{result.new_id}
    workflow: #{result.path}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    wrote: true
    """
  end

  defp format_shot_rename(result, :human, false) do
    """
    dry run: shot rename #{result.old_id} -> #{result.new_id}
    workflow: #{result.path}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    wrote: false

    #{result.diff}
    """
  end

  defp format_shot_remove(result, :json, wrote?) do
    %{
      "path" => result.path,
      "shot_id" => result.shot_id,
      "format" => Atom.to_string(result.format),
      "removed_ids" => result.removed_ids,
      "dependent_ids" => result.dependent_ids,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_remove(result, :human, true) do
    """
    removed shot: #{result.shot_id}
    workflow: #{result.path}
    removed ids: #{Enum.join(result.removed_ids, ", ")}
    dependent ids: #{empty_or_join(result.dependent_ids)}
    wrote: true
    """
  end

  defp format_shot_remove(result, :human, false) do
    """
    dry run: shot remove #{result.shot_id}
    workflow: #{result.path}
    removed ids: #{Enum.join(result.removed_ids, ", ")}
    dependent ids: #{empty_or_join(result.dependent_ids)}
    wrote: false

    #{result.diff}
    """
  end

  defp empty_or_join([]), do: "none"
  defp empty_or_join(values), do: Enum.join(values, ", ")

  defp format_shot_move(result, :json, wrote?) do
    %{
      "path" => result.path,
      "shot_id" => result.shot_id,
      "target_id" => result.target_id,
      "position" => Atom.to_string(result.position),
      "format" => Atom.to_string(result.format),
      "original_index" => result.original_index,
      "new_index" => result.new_index,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_move(result, :human, true) do
    """
    moved shot: #{result.shot_id} #{result.position} #{result.target_id}
    workflow: #{result.path}
    original index: #{result.original_index}
    new index: #{result.new_index}
    wrote: true
    """
  end

  defp format_shot_move(result, :human, false) do
    """
    dry run: shot move #{result.shot_id} #{result.position} #{result.target_id}
    workflow: #{result.path}
    original index: #{result.original_index}
    new index: #{result.new_index}
    wrote: false

    #{result.diff}
    """
  end

  defp format_shot_add(result, :json, wrote?) do
    %{
      "path" => result.path,
      "shot_id" => result.shot_id,
      "target_id" => result.target_id,
      "position" => Atom.to_string(result.position),
      "format" => Atom.to_string(result.format),
      "new_index" => result.new_index,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_add(result, :human, true) do
    """
    added shot: #{result.shot_id}
    workflow: #{result.path}
    position: #{add_position_text(result)}
    new index: #{result.new_index}
    wrote: true
    """
  end

  defp format_shot_add(result, :human, false) do
    """
    dry run: shot add #{result.shot_id}
    workflow: #{result.path}
    position: #{add_position_text(result)}
    new index: #{result.new_index}
    wrote: false

    #{result.diff}
    """
  end

  defp add_position_text(%{position: :end}), do: "end"
  defp add_position_text(result), do: "#{result.position} #{result.target_id}"

  defp format_shot_split(result, :json, wrote?) do
    %{
      "path" => result.path,
      "shot_id" => result.shot_id,
      "child_ids" => result.child_ids,
      "final_child_id" => result.final_child_id,
      "format" => Atom.to_string(result.format),
      "dependent_ids" => result.dependent_ids,
      "updated_dependencies" => result.updated_dependencies,
      "updated_conditions" => result.updated_conditions,
      "lint_report" => Map.get(result, :lint_report),
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_split(result, :human, true) do
    """
    split shot: #{result.shot_id}
    workflow: #{result.path}
    child shots: #{Enum.join(result.child_ids, ", ")}
    final child: #{result.final_child_id}
    rewired dependents: #{empty_or_join(result.dependent_ids)}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    contextual lint: passed
    wrote: true
    """
  end

  defp format_shot_split(result, :human, false) do
    """
    dry run: shot split #{result.shot_id} into #{Enum.join(result.child_ids, ", ")}
    workflow: #{result.path}
    final child: #{result.final_child_id}
    rewired dependents: #{empty_or_join(result.dependent_ids)}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    contextual lint: passed
    wrote: false

    #{result.diff}
    """
  end

  defp format_shot_merge(result, :json, wrote?) do
    %{
      "path" => result.path,
      "source_ids" => result.source_ids,
      "new_id" => result.new_id,
      "format" => Atom.to_string(result.format),
      "dependent_ids" => result.dependent_ids,
      "updated_dependencies" => result.updated_dependencies,
      "updated_conditions" => result.updated_conditions,
      "lint_report" => Map.get(result, :lint_report),
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_merge(result, :human, true) do
    """
    merged shots: #{Enum.join(result.source_ids, ", ")} -> #{result.new_id}
    workflow: #{result.path}
    rewired dependents: #{empty_or_join(result.dependent_ids)}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    contextual lint: passed
    wrote: true
    """
  end

  defp format_shot_merge(result, :human, false) do
    """
    dry run: shot merge #{Enum.join(result.source_ids, ", ")} -> #{result.new_id}
    workflow: #{result.path}
    rewired dependents: #{empty_or_join(result.dependent_ids)}
    updated dependencies: #{result.updated_dependencies}
    updated conditions: #{result.updated_conditions}
    contextual lint: passed
    wrote: false

    #{result.diff}
    """
  end

  defp format_shot_gate(result, :json, wrote?) do
    %{
      "path" => result.path,
      "gate_id" => result.gate_id,
      "target_id" => result.target_id,
      "format" => Atom.to_string(result.format),
      "original_dependencies" => result.original_dependencies,
      "gate_dependencies" => result.gate_dependencies,
      "target_dependencies" => result.target_dependencies,
      "gate_index" => result.gate_index,
      "target_index" => result.target_index,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_gate(result, :human, true) do
    """
    inserted safety gate: #{result.gate_id}
    workflow: #{result.path}
    target shot: #{result.target_id}
    gate dependencies: #{empty_or_join(result.gate_dependencies)}
    target dependencies: #{Enum.join(result.target_dependencies, ", ")}
    wrote: true
    """
  end

  defp format_shot_gate(result, :human, false) do
    """
    dry run: shot gate #{result.target_id} with #{result.gate_id}
    workflow: #{result.path}
    gate dependencies: #{empty_or_join(result.gate_dependencies)}
    target dependencies: #{Enum.join(result.target_dependencies, ", ")}
    wrote: false

    #{result.diff}
    """
  end

  defp format_shot_schema_set(result, :json, wrote?) do
    %{
      "path" => result.path,
      "shot_id" => result.shot_id,
      "format" => Atom.to_string(result.format),
      "previous_schema" => result.previous_schema,
      "output_schema" => result.output_schema,
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_schema_set(result, :human, true) do
    """
    set output schema: #{result.shot_id}
    workflow: #{result.path}
    schema type: #{Map.get(result.output_schema, "type", "unknown")}
    replaced existing schema: #{not is_nil(result.previous_schema)}
    wrote: true
    """
  end

  defp format_shot_schema_set(result, :human, false) do
    """
    dry run: shot schema set #{result.shot_id}
    workflow: #{result.path}
    schema type: #{Map.get(result.output_schema, "type", "unknown")}
    replaced existing schema: #{not is_nil(result.previous_schema)}
    wrote: false

    #{result.diff}
    """
  end

  defp format_shot_replace_agent(result, :json, wrote?) do
    %{
      "path" => result.path,
      "old_agent" => result.old_agent,
      "new_agent" => result.new_agent,
      "format" => Atom.to_string(result.format),
      "changed_shot_ids" => result.changed_shot_ids,
      "lint_report" => Map.get(result, :lint_report),
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_replace_agent(result, :human, true) do
    """
    replaced agent: #{result.old_agent} -> #{result.new_agent}
    workflow: #{result.path}
    changed shots: #{Enum.join(result.changed_shot_ids, ", ")}
    contextual lint: passed
    wrote: true
    """
  end

  defp format_shot_replace_agent(result, :human, false) do
    """
    dry run: shot replace-agent #{result.old_agent} -> #{result.new_agent}
    workflow: #{result.path}
    changed shots: #{Enum.join(result.changed_shot_ids, ", ")}
    contextual lint: passed
    wrote: false

    #{result.diff}
    """
  end

  defp format_shot_replace_tool(result, :json, wrote?) do
    %{
      "path" => result.path,
      "old_tool" => result.old_tool,
      "new_tool" => result.new_tool,
      "format" => Atom.to_string(result.format),
      "changed_shot_ids" => result.changed_shot_ids,
      "lint_report" => Map.get(result, :lint_report),
      "wrote" => wrote?,
      "diff" => result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_replace_tool(result, :human, true) do
    """
    replaced tool: #{result.old_tool} -> #{result.new_tool}
    workflow: #{result.path}
    changed shots: #{Enum.join(result.changed_shot_ids, ", ")}
    contextual lint: passed
    wrote: true
    """
  end

  defp format_shot_replace_tool(result, :human, false) do
    """
    dry run: shot replace-tool #{result.old_tool} -> #{result.new_tool}
    workflow: #{result.path}
    changed shots: #{Enum.join(result.changed_shot_ids, ", ")}
    contextual lint: passed
    wrote: false

    #{result.diff}
    """
  end

  defp format_shot_library_list(templates, :json) do
    templates
    |> Enum.map(&ShotLibrary.to_map/1)
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_library_list(templates, :human) do
    rows =
      case templates do
        [] ->
          "  none"

        templates ->
          templates
          |> Enum.map(fn template ->
            source = Atom.to_string(template.source)
            description = template.description || ""

            "  - #{template.namespace}/#{template.id} #{template.version} #{source} #{description}"
          end)
          |> Enum.join("\n")
      end

    "Shot templates:\n#{rows}\n"
  end

  defp format_shot_library_template(template, :json) do
    template
    |> ShotLibrary.to_map()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_library_template(template, :human) do
    {:ok, shot} = ShellDocument.encode(template.shot, :yaml)

    """
    Shot template: #{template.namespace}/#{template.id}
    Version: #{template.version}
    Source: #{template.source}
    Digest: #{template.digest}
    Description: #{template.description || ""}

    #{shot}
    """
  end

  defp format_shot_library_verify(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_library_verify(report, :human) do
    findings =
      case report["findings"] do
        [] ->
          "  none"

        findings ->
          findings
          |> Enum.map(fn finding ->
            template = Map.get(finding, "template", "lockfile")
            status = Map.get(finding, "status")
            message = Map.get(finding, "message")
            "  - #{status} #{template}: #{message}"
          end)
          |> Enum.join("\n")
      end

    """
    Shot library verify: #{report["lockfile"]}
    Status: #{String.upcase(report["status"])}
    Mode: #{report["mode"]}
    Checked: #{report["checked"]}
    Findings:
    #{findings}
    """
  end

  defp format_shot_library_update(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_library_update(report, :human) do
    findings =
      case report["findings"] do
        [] ->
          "  none"

        findings ->
          findings
          |> Enum.map(fn finding ->
            template = Map.get(finding, "template", "lockfile")
            status = Map.get(finding, "status")
            message = Map.get(finding, "message")
            "  - #{status} #{template}: #{message}"
          end)
          |> Enum.join("\n")
      end

    diff =
      case Map.get(report, "diff") do
        nil -> ""
        "" -> ""
        diff -> "\n#{diff}"
      end

    """
    Shot library update: #{report["lockfile"]}
    Status: #{String.upcase(report["status"])}
    Mode: #{report["mode"]}
    Checked: #{report["checked"]}
    Changed: #{report["changed"]}
    Findings:
    #{findings}
    #{diff}
    """
  end

  defp format_shot_library_outdated(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shot_library_outdated(report, :human) do
    findings =
      case report["findings"] do
        [] ->
          "  none"

        findings ->
          findings
          |> Enum.map(fn finding ->
            status = Map.get(finding, "status")
            workflow = Map.get(finding, "workflow")
            shot = Map.get(finding, "shot")
            template = Map.get(finding, "template", "unknown")
            message = Map.get(finding, "message")
            "  - #{status} #{workflow}.#{shot} #{template}: #{message}"
          end)
          |> Enum.join("\n")
      end

    errors =
      case report["errors"] do
        [] ->
          "  none"

        errors ->
          errors
          |> Enum.map(&"  - #{&1["path"]}: #{get_in(&1, ["error", "message"])}")
          |> Enum.join("\n")
      end

    """
    Shot library outdated: #{report["path"]}
    Status: #{String.upcase(report["status"])}
    Workflows: #{report["checked_workflows"]}
    Template shots: #{report["checked_shots"]}
    Findings:
    #{findings}
    Errors:
    #{errors}
    """
  end

  defp format_scaffold_library_list(scaffolds, :json) do
    scaffolds
    |> Enum.map(&Scaffold.to_map/1)
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_scaffold_library_list(scaffolds, :human) do
    rows =
      case scaffolds do
        [] ->
          "  none"

        scaffolds ->
          scaffolds
          |> Enum.map(fn scaffold ->
            source = Atom.to_string(scaffold.source)
            description = scaffold.description || ""

            "  - #{scaffold.namespace}/#{scaffold.id} #{scaffold.version} #{source} #{description}"
          end)
          |> Enum.join("\n")
      end

    "Scaffolds:\n#{rows}\n"
  end

  defp format_scaffold_library_entry(scaffold, :json) do
    scaffold
    |> Scaffold.to_map()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_scaffold_library_entry(scaffold, :human) do
    {:ok, workflow} = ShellDocument.encode(scaffold.workflow, :yaml)

    """
    Scaffold: #{scaffold.namespace}/#{scaffold.id}
    Version: #{scaffold.version}
    Source: #{scaffold.source}
    Digest: #{scaffold.digest}
    Description: #{scaffold.description || ""}

    #{workflow}
    """
  end

  defp format_scaffold_library_verify(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_scaffold_library_verify(report, :human) do
    findings = format_scaffold_library_findings(report["findings"])

    """
    Scaffold library verify: #{report["lockfile"]}
    Status: #{String.upcase(report["status"])}
    Mode: #{report["mode"]}
    Checked: #{report["checked"]}
    Findings:
    #{findings}
    """
  end

  defp format_scaffold_library_update(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_scaffold_library_update(report, :human) do
    findings = format_scaffold_library_findings(report["findings"])

    diff =
      case Map.get(report, "diff") do
        nil -> ""
        "" -> ""
        diff -> "\n#{diff}"
      end

    """
    Scaffold library update: #{report["lockfile"]}
    Status: #{String.upcase(report["status"])}
    Mode: #{report["mode"]}
    Checked: #{report["checked"]}
    Changed: #{report["changed"]}
    Findings:
    #{findings}
    #{diff}
    """
  end

  defp format_scaffold_library_outdated(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_scaffold_library_outdated(report, :human) do
    findings =
      case report["findings"] do
        [] ->
          "  none"

        findings ->
          findings
          |> Enum.map(fn finding ->
            status = Map.get(finding, "status")
            workflow = Map.get(finding, "workflow")
            scaffold = Map.get(finding, "scaffold", "unknown")
            message = Map.get(finding, "message")
            "  - #{status} #{workflow} #{scaffold}: #{message}"
          end)
          |> Enum.join("\n")
      end

    errors =
      case report["errors"] do
        [] ->
          "  none"

        errors ->
          errors
          |> Enum.map(&"  - #{&1["path"]}: #{get_in(&1, ["error", "message"])}")
          |> Enum.join("\n")
      end

    """
    Scaffold library outdated: #{report["path"]}
    Status: #{String.upcase(report["status"])}
    Workflows: #{report["checked_workflows"]}
    Findings:
    #{findings}
    Errors:
    #{errors}
    """
  end

  defp format_scaffold_library_findings([]), do: "  none"

  defp format_scaffold_library_findings(findings) do
    findings
    |> Enum.map(fn finding ->
      scaffold = Map.get(finding, "scaffold", "lockfile")
      status = Map.get(finding, "status")
      message = Map.get(finding, "message")
      "  - #{status} #{scaffold}: #{message}"
    end)
    |> Enum.join("\n")
  end

  defp format_shell_author_review(report, :json) do
    report
    |> Map.delete(:exit_code)
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shell_author_review(report, :human) do
    disclosure = report.disclosure
    plan = report.patch_plan

    changes =
      plan["changes"]
      |> Enum.map(fn change ->
        target = Map.get(change, "target", "collection")
        "  - #{change["action"]} #{target}: #{change["description"]}"
      end)
      |> Enum.join("\n")

    paths =
      disclosure["source_paths"]
      |> Enum.map(&"  - #{&1}")
      |> Enum.join("\n")

    tools = Enum.join(disclosure["tools_exposed"], ", ")

    """
    Shell author review: #{plan["path"]}
    Status: OK
    Provider: #{report.provider}
    Model: #{report.model}
    Remote: #{disclosure["remote"]}
    Writes files: false
    Source bytes: #{disclosure["source_bytes"]}
    Redacted bytes: #{disclosure["redacted_bytes"]}
    Tools exposed: #{tools}
    Plan digest: #{plan["plan_digest"]}
    Base digest: #{plan["base_digest"]}
    Source paths:
    #{paths}
    Changes:
    #{changes}
    """
  end

  defp format_shell_patch_report(report, :json) do
    report
    |> Map.delete("exit_code")
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_shell_patch_report(report, :human) do
    files =
      report["files"]
      |> Enum.map(fn file ->
        findings =
          case file["findings"] do
            nil -> ""
            [] -> ""
            findings -> " findings=#{Enum.map_join(findings, ",", & &1["status"])}"
          end

        "  - #{file["path"]} #{file["kind"]} #{file["operation"]} #{file["before_digest"]} -> #{file["after_digest"]}#{findings}"
      end)
      |> Enum.join("\n")

    findings =
      case report["findings"] do
        [] ->
          "  none"

        findings ->
          findings
          |> Enum.map(&"  - #{&1["status"]}: #{&1["message"]}")
          |> Enum.join("\n")
      end

    approval =
      case Map.get(report, "approval") do
        nil -> "not_checked"
        approval -> approval["status"]
      end

    """
    Shell patch #{String.replace_prefix(report["kind"], "twelvgaige.patch.", "")}: #{report["patch_id"] || "unknown"}
    Status: #{String.upcase(report["status"])}
    Mode: #{report["mode"] || "check"}
    Changed: #{report["changed"]}
    Patch digest: #{report["patch_digest"]}
    Declared digest: #{report["declared_patch_digest"] || "missing"}
    Approval: #{approval}
    Files:
    #{files}
    Findings:
    #{findings}
    """
  end

  defp format_shell_list([], :human), do: "No shells.\n"

  defp format_shell_list(shells, :human) do
    shells
    |> Enum.map(fn shell ->
      "#{shell_kind(shell)}  #{shell.id}  #{shell.version || "unversioned"}"
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_shell_list(shells, :json) do
    shells
    |> Enum.map(&shell_map/1)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_reload(summary, :json) do
    summary
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_reload(summary, :human) do
    paths = value(summary, :paths, [])
    workflows = value(summary, :workflows, [])
    agents = value(summary, :agents, [])

    """
    Shell cache reloaded
    Paths: #{length(paths)}
    Workflows: #{format_id_list(workflows)}
    Agents: #{format_id_list(agents)}
    """
  end

  defp shell_map(%Shell.Workflow{} = shell) do
    %{
      kind: "workflow",
      id: shell.id,
      name: shell.name,
      version: shell.version,
      shots: Enum.map(shell.shots, & &1.id)
    }
  end

  defp shell_map(%Shell.Agent{} = shell) do
    %{
      kind: "agent",
      id: shell.id,
      name: shell.name,
      version: shell.version,
      provider: shell.provider,
      model: shell.model
    }
  end

  defp shell_kind(%Shell.Workflow{}), do: "workflow"
  defp shell_kind(%Shell.Agent{}), do: "agent"

  defp format_id_list([]), do: "none"
  defp format_id_list(ids), do: Enum.join(ids, ", ")

  defp format_snapshot(%Snapshot{} = snapshot, :json) do
    snapshot
    |> Snapshot.to_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_snapshot(%Snapshot{} = snapshot, :human) do
    shot_lines =
      snapshot.shots
      |> Enum.map(fn %Shot.State{} = shot -> "  - #{shot.id} [#{shot.status}]" end)
      |> Enum.join("\n")

    """
    Round:  #{snapshot.id}
    Shell:  #{snapshot.shell_id} #{snapshot.shell_version}
    Status: #{snapshot.status}
    Shots:
    #{shot_lines}
    """
  end

  defp format_detached_round(round_id, :json) do
    %{id: round_id, status: "queued"}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_detached_round(round_id, :human), do: "Round queued: #{round_id}\n"

  defp format_round_list(rounds, :json) do
    rounds
    |> Enum.map(&Snapshot.to_map/1)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_round_list([], :human), do: "No rounds.\n"

  defp format_round_list(rounds, :human) do
    rows =
      rounds
      |> Enum.map(fn %Snapshot{} = snapshot ->
        "#{snapshot.id}  #{snapshot.shell_id}  #{snapshot.status}"
      end)
      |> Enum.join("\n")

    rows <> "\n"
  end

  defp format_events([], :human), do: "No events.\n"
  defp format_events([], :ndjson), do: ""

  defp format_events(events, :ndjson) do
    events
    |> Enum.map(fn %Event{} = event -> event |> Event.to_map() |> Jason.encode!() end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_events(events, :human) do
    events
    |> Enum.map(fn %Event{} = event ->
      status = value(event.payload, :status)
      detail = if status, do: " status=#{status}", else: ""
      "##{event.seq} #{event.event_type}#{detail}"
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_audit_events(events, opts) when is_list(opts) do
    format = opts[:format]
    sign_hmac_env = opts[:sign_hmac_env]

    cond do
      is_binary(sign_hmac_env) and sign_hmac_env != "" and format != :checkpoint ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "--sign-hmac-env requires --format checkpoint"
         )}

      is_binary(sign_hmac_env) and sign_hmac_env != "" ->
        with {:ok, key} <- hmac_key_from_env(sign_hmac_env),
             {:ok, signed} <-
               events
               |> Twelvgaige.Audit.Checkpoint.export(scope: :audit)
               |> Twelvgaige.Audit.Checkpoint.sign_hmac(key, key_ref: sign_hmac_env) do
          {:ok, signed |> Jason.encode!() |> Kernel.<>("\n")}
        end

      true ->
        {:ok, format_audit_events(events, format)}
    end
  end

  defp format_audit_events([], :human), do: "No audit events.\n"
  defp format_audit_events([], :ndjson), do: ""

  defp format_audit_events(events, :json) do
    events
    |> Enum.map(&AuditEvent.to_map/1)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_audit_events(events, :checkpoint) do
    events
    |> Twelvgaige.Audit.Checkpoint.export(scope: :audit)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_audit_events(events, :ndjson) do
    events
    |> Enum.map(fn event -> event |> AuditEvent.to_map() |> Jason.encode!() end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_audit_events(events, :human) do
    events
    |> Enum.map(fn event ->
      event = AuditEvent.to_map(event)
      seq = value(event, :seq, "?")
      event_type = value(event, :event_type, "unknown")
      actor = value(event, :actor)
      shot_id = value(event, :shot_id)

      detail =
        [
          if(actor, do: "actor=#{actor}"),
          if(shot_id, do: "shot=#{shot_id}")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")

      ["##{seq}", event_type, detail]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_audit_verify_ok(checkpoint, :json) do
    %{
      status: "ok",
      valid: true,
      kind: checkpoint["kind"],
      algorithm: checkpoint["algorithm"],
      scope: checkpoint["scope"],
      round_id: checkpoint["round_id"],
      event_count: checkpoint["event_count"],
      first_seq: checkpoint["first_seq"],
      last_seq: checkpoint["last_seq"],
      root_hash: checkpoint["root_hash"],
      generated_at: checkpoint["generated_at"],
      signature: checkpoint["signature"]
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_audit_verify_ok(checkpoint, :human) do
    round_id = checkpoint["round_id"] || "unknown"
    event_count = checkpoint["event_count"] || 0
    root_hash = checkpoint["root_hash"] || "unknown"
    signature = value(checkpoint["signature"], :algorithm, "unsigned")

    "valid audit checkpoint: round=#{round_id} events=#{event_count} root_hash=#{root_hash} signature=#{signature}\n"
  end

  defp format_audit_verify_error(reason, :json) do
    %{
      status: "failed",
      valid: false,
      reason: audit_verify_reason(reason),
      details: audit_verify_details(reason)
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_audit_verify_error(reason, :human) do
    "invalid audit checkpoint: #{audit_verify_reason(reason)}#{audit_verify_detail_text(reason)}\n"
  end

  defp audit_verify_reason({reason, _seq}) when is_atom(reason), do: Atom.to_string(reason)
  defp audit_verify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp audit_verify_reason(reason), do: inspect(reason)

  defp audit_verify_details({_reason, seq}), do: %{seq: seq}
  defp audit_verify_details(_reason), do: %{}

  defp audit_verify_detail_text({_reason, seq}), do: " seq=#{seq}"
  defp audit_verify_detail_text(_reason), do: ""

  defp format_safety_decision(decision, round_id, shot_id, :json) do
    %{
      status: "accepted",
      decision: Atom.to_string(decision),
      round_id: round_id,
      shot_id: shot_id
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_safety_decision(decision, round_id, shot_id, :human) do
    "Safety #{decision} accepted for #{round_id} #{shot_id}\n"
  end

  defp format_cancel(round_id, :json) do
    %{status: "accepted", decision: "cancel", round_id: round_id}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_cancel(round_id, :human), do: "Cancel accepted for #{round_id}\n"

  defp format_status(status, :json) do
    status
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_status(status, :human) do
    resources = value(status, :resources, %{})
    used = value(resources, :used, %{})
    limits = value(resources, :limits, %{})
    store = value(status, :store, %{})

    """
    Breech: running
    Version: #{value(status, :version)}
    Daemon ID: #{value(status, :daemon_id)}
    Profile: #{value(status, :profile)}
    IPC: #{value(status, :ipc)}
    Uptime: #{value(status, :uptime_ms)}ms
    Store: #{value(store, :status)}
    Incomplete rounds: #{value(store, :incomplete_rounds, 0) || 0}
    LLM calls: #{used["llm_call"] || 0}/#{limits["llm_call"] || 0}
    Tool exec: #{used["tool_exec"] || 0}/#{limits["tool_exec"] || 0}
    """
  end

  defp format_crypto_status(status, :json) do
    status
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_crypto_status(status, :human) do
    store = value(status, :store, %{})
    key_manager = value(status, :key_manager, %{})
    http = value(status, :http_listener, %{})
    providers = value(status, :providers, %{})
    audit = value(status, :audit, %{})
    release = value(status, :release, %{})

    warnings =
      [store, key_manager, http, providers, audit, release]
      |> Enum.flat_map(&List.wrap(value(&1, :warnings, [])))
      |> case do
        [] -> "  none"
        warnings -> Enum.map_join(warnings, "\n", &"  - #{&1}")
      end

    """
    Crypto posture: #{value(status, :status)}
    Store: #{value(store, :backend)} encryption=#{value(store, :encryption)} encrypted=#{value(store, :encrypted)}
    Key manager: #{if(value(key_manager, :enabled), do: value(key_manager, :backend), else: "disabled")}
    HTTP listener: #{if(value(http, :enabled), do: value(http, :tls_mode), else: "disabled")}
    Native TLS: #{value(http, :native_tls_supported)}
    mTLS: #{value(http, :mtls_supported)}
    Provider TLS: #{value(providers, :hosted_tls_verification)} tests=#{value(providers, :tls_regression_tests)}
    Audit checkpoint hash chain: #{value(audit, :checkpoint_hash_chain)}
    Audit signing: #{value(audit, :checkpoint_signing)}
    Release checksums: #{value(release, :checksums)}
    Release signatures: #{value(release, :signed_checksums)}
    Release attestations: #{value(release, :attestations)}
    Warnings:
    #{warnings}
    """
  end

  defp format_sqlcipher_spike(report, :json) do
    report
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_sqlcipher_spike(report, :human) do
    warnings =
      report
      |> value(:warnings, [])
      |> List.wrap()
      |> case do
        [] -> "  none"
        warnings -> Enum.map_join(warnings, "\n", &"  - #{&1}")
      end

    """
    SQLCipher spike: #{value(report, :status)}
    Driver: #{value(report, :driver)}
    Path: #{value(report, :path)}
    Available: #{value(report, :available)}
    Cipher version: #{value(report, :cipher_version) || "none"}
    Migrations: #{value(report, :migrations)}
    Reopen with key: #{value(report, :reopen_with_key)}
    Open without key rejected: #{value(report, :open_without_key_rejected)}
    Warnings:
    #{warnings}
    """
  end

  defp format_sqlcipher_spike_error(error, :json) do
    %{
      error: %{
        reason: sqlcipher_spike_error_reason(error),
        message: sqlcipher_spike_error_message(error)
      }
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_sqlcipher_spike_error(error, :human) do
    "error: #{sqlcipher_spike_error_message(error)}\n"
  end

  defp sqlcipher_spike_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp sqlcipher_spike_error_reason(_reason), do: "sqlcipher_spike_failed"

  defp sqlcipher_spike_error_message(:sqlcipher_key_required) do
    "SQLCipher is available, but a key is required; set TWELVGAIGE_SQLCIPHER_SPIKE_KEY or pass --key-env"
  end

  defp sqlcipher_spike_error_message(reason), do: inspect(reason)

  defp format_store_backup(report, :json) do
    report
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_store_backup(report, :human) do
    warnings =
      report
      |> value(:warnings, [])
      |> List.wrap()
      |> case do
        [] -> "  none"
        warnings -> Enum.map_join(warnings, "\n", &"  - #{&1}")
      end

    """
    Store backup complete
    Source: #{value(report, :source)}
    Destination: #{value(report, :destination)}
    Mode: #{value(report, :mode)}
    Encrypted: #{value(report, :encrypted)}
    Plaintext export: #{value(report, :plaintext)}
    Warnings:
    #{warnings}
    """
  end

  defp format_store_restore(report, :json) do
    report
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_store_restore(report, :human) do
    """
    Store restore complete
    Source: #{value(report, :source)}
    Destination: #{value(report, :destination)}
    Bytes: #{value(report, :bytes)}
    Replaced: #{value(report, :replaced)}
    """
  end

  defp format_store_migration(report, :json) do
    report
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_store_migration(report, :human) do
    warnings =
      report
      |> value(:warnings, [])
      |> List.wrap()
      |> case do
        [] -> "  none"
        warnings -> Enum.map_join(warnings, "\n", &"  - #{&1}")
      end

    """
    Store SQLCipher migration complete
    Source: #{value(report, :source)}
    Destination: #{value(report, :destination)}
    Driver: #{value(report, :driver)}
    Cipher version: #{value(report, :cipher_version)}
    Migration versions: #{inspect(value(report, :migration_versions, []))}
    Open without key rejected: #{value(report, :open_without_key_rejected)}
    Replaced: #{value(report, :replaced)}
    Warnings:
    #{warnings}
    """
  end

  defp format_store_rewrap(report, :json) do
    report
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_store_rewrap(report, :human) do
    warnings =
      report
      |> value(:warnings, [])
      |> List.wrap()
      |> case do
        [] -> "  none"
        warnings -> Enum.map_join(warnings, "\n", &"  - #{&1}")
      end

    """
    Store envelope rewrap complete
    Envelope: #{value(report, :path)}
    Backup: #{value(report, :backup)}
    Key: #{value(report, :key_id)} backend=#{value(report, :key_backend)}
    Previous key: #{value(report, :previous_key_id)} backend=#{value(report, :previous_key_backend)}
    Database rekeyed: #{value(report, :database_rekeyed)}
    Warnings:
    #{warnings}
    """
  end

  defp format_store_error(error, :json) do
    %{error: %{reason: store_error_reason(error), message: store_error_message(error)}}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_store_error(error, :human), do: "error: #{store_error_message(error)}\n"

  defp store_error_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp store_error_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp store_error_reason(_reason), do: "store_error"

  defp store_error_message(:plaintext_export_not_allowed) do
    "plaintext SQLite backups require --allow-plaintext-export"
  end

  defp store_error_message(:backup_destination_exists), do: "backup destination already exists"
  defp store_error_message(:backup_source_not_found), do: "backup source does not exist"
  defp store_error_message(:restore_destination_exists), do: "restore destination already exists"
  defp store_error_message(:migration_source_not_found), do: "migration source does not exist"

  defp store_error_message(:migration_destination_exists),
    do: "migration destination already exists"

  defp store_error_message(:migration_same_path),
    do: "migration source and destination must differ"

  defp store_error_message(:migration_source_invalid), do: "migration source is not a valid store"
  defp store_error_message(:sqlcipher_key_required), do: "SQLCipher migration requires --key-env"

  defp store_error_message(:sqlcipher_unavailable),
    do: "SQLite driver is not built with SQLCipher"

  defp store_error_message(:envelope_backup_required), do: "envelope rewrap requires --backup"
  defp store_error_message(:old_key_env_required), do: "envelope rewrap requires --old-key-env"
  defp store_error_message(:new_key_env_required), do: "envelope rewrap requires --new-key-env"
  defp store_error_message(:envelope_not_found), do: "envelope file does not exist"
  defp store_error_message(:envelope_backup_exists), do: "envelope backup already exists"
  defp store_error_message(:invalid_envelope_file), do: "invalid envelope file"
  defp store_error_message(:dek_unwrap_failed), do: "failed to unwrap envelope with old key"

  defp store_error_message({:store_backup_unsupported, module}) do
    "store backend #{inspect(module)} does not support backup"
  end

  defp store_error_message({:store_restore_unsupported, module}) do
    "store backend #{inspect(module)} does not support restore"
  end

  defp store_error_message(reason), do: inspect(reason)

  defp store_error_exit_code(:backup_source_not_found), do: 6
  defp store_error_exit_code(:migration_source_not_found), do: 6
  defp store_error_exit_code(:plaintext_export_not_allowed), do: 7
  defp store_error_exit_code(:backup_destination_exists), do: 4
  defp store_error_exit_code(:restore_destination_exists), do: 4
  defp store_error_exit_code(:migration_destination_exists), do: 4
  defp store_error_exit_code(:migration_same_path), do: 4
  defp store_error_exit_code(:migration_source_invalid), do: 4
  defp store_error_exit_code(:sqlcipher_key_required), do: 4
  defp store_error_exit_code(:sqlcipher_unavailable), do: 4
  defp store_error_exit_code(:envelope_backup_required), do: 4
  defp store_error_exit_code(:old_key_env_required), do: 4
  defp store_error_exit_code(:new_key_env_required), do: 4
  defp store_error_exit_code(:envelope_not_found), do: 6
  defp store_error_exit_code(:envelope_backup_exists), do: 4
  defp store_error_exit_code(:invalid_envelope_file), do: 4
  defp store_error_exit_code(:dek_unwrap_failed), do: 4
  defp store_error_exit_code({:store_backup_unsupported, _module}), do: 4
  defp store_error_exit_code({:store_restore_unsupported, _module}), do: 4
  defp store_error_exit_code(error), do: ExitCode.for_error(error)

  defp format_daemon_started(address, :json) do
    %{status: "running", address: Endpoint.address_to_string(address)}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_daemon_started(address, :human) do
    "Breech daemon listening on #{Endpoint.address_to_string(address)}\n"
  end

  defp format_daemon_paths(paths, :json) do
    paths
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_daemon_paths(paths, :human) do
    """
    Runtime dir: #{paths.runtime_dir}
    Endpoint: #{paths.endpoint_path}
    Lock: #{paths.lock_path}
    Transport: #{paths.transport}
    Socket: #{paths.socket_path}
    Named pipe: #{paths.pipe_path}
    """
  end

  defp format_daemon_stop(:json) do
    %{status: "stopping"}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_daemon_stop(:human), do: "Breech daemon stopping\n"

  defp format_error(error, :json) do
    %{error: Twelvgaige.Error.to_map(error)}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_error(error, :human), do: "error: #{error.message}\n"

  defp format_command_error(%Twelvgaige.Error{} = error, format), do: format_error(error, format)

  defp format_command_error(:daemon_unavailable, :json) do
    %{error: %{reason: "daemon_unavailable", message: "daemon unavailable"}}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_command_error(:daemon_unavailable, :human), do: "daemon unavailable\n"

  defp format_command_error(:not_found, :json) do
    %{error: %{reason: "round_not_found", message: "round not found"}}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_command_error(:not_found, :human), do: "error: round not found\n"

  defp format_command_error(error, :json) do
    %{error: %{reason: "unknown", message: inspect(error)}}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_command_error(error, :human), do: "error: #{inspect(error)}\n"

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> :error
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> :error
    end
  end

  defp parse_positive_integer(value, label) do
    case parse_positive_integer(value) do
      {:ok, integer} ->
        {:ok, integer}

      :error ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "#{label} must be a positive integer")}
    end
  end

  defp value(map, key, default \\ nil)

  defp value(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_map, _key, default), do: default
end
