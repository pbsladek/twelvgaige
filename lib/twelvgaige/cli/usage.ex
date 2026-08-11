defmodule Twelvgaige.CLI.Usage do
  @moduledoc false

  @usage """
  twelvgaige - deterministic agent orchestration

  Usage:
    twelvgaige --help
    twelvgaige version

  Global options (accepted before or after the command):
    --quiet                     Suppress successful human output
    --verbose                   Write redacted command and timing diagnostics to stderr
    --color auto|always|never   Select terminal color policy (default: auto)
    --no-color                  Alias for --color never

  Control-plane options (accepted by workspace, session, sandbox control, and operations commands):
    --runtime-dir <path>        Select the local daemon runtime directory
    --endpoint <path>           Select an exact authenticated endpoint file

    twelvgaige completion <bash|zsh|fish>
    twelvgaige init [--profile <name>] [--auth-profile <id>] [--sandbox podman|apple-container] [--root <path>] [--force] [--format human|json]
    twelvgaige doctor [--profile <name>] [--root <path>] [--fix] [--format human|json]
    twelvgaige support bundle --output <directory> [--write --yes] [--request-id <id>] [--root <path>] [--format human|json]
    twelvgaige status [--format human|json]
    twelvgaige crypto status [--format human|json]
    twelvgaige crypto sqlcipher-spike [--path <path>] [--key-env <env>] [--format human|json]
    twelvgaige store backup <destination-path> [--allow-plaintext-export] [--format human|json]
    twelvgaige store restore <source-path> <destination-path> [--replace] [--format human|json]
    twelvgaige store migrate-sqlcipher --source <plaintext.db> --destination <encrypted.db> --key-env <env> [--replace] [--format human|json]
    twelvgaige store rewrap-envelope <envelope.json> --backup <backup.json> --old-key-env <env> --new-key-env <env> [--format human|json]
    twelvgaige audit verify <checkpoint-path|-> [--hmac-env <env>] [--format human|json]
    twelvgaige daemon serve [--transport unix|tcp] [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige daemon stop [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige daemon paths [--transport unix|tcp] [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige daemon token rotate [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige repo inspect [--repo <path>] [--base-ref <ref>] [--format human|json]
    twelvgaige workspace list [--repo <path>] [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige workspace set list [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige workspace set show <set-id-prefix|--last> [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige workspace show <workspace-id-prefix|--last> [--repo <path>] [--format human|json]
    twelvgaige workspace path <workspace-id-prefix|--last> [--repo <path>] [--format human|json]
    twelvgaige workspace status <workspace-id-prefix|--last> [--repo <path>] [--format human|json]
    twelvgaige workspace diff <workspace-id-prefix|--last> [--repo <path>] [--format human|json]
    twelvgaige workspace export <workspace-id-prefix|--last> --output <directory> [--repo <path>] [--request-id <id>] [--format human|json]
    twelvgaige workspace apply <workspace-id-prefix|--last> [--target review-worktree|current-worktree] [--check|--write --yes --expected-epoch <epoch>] [--request-id <id>] [--format human|json]
    twelvgaige workspace reconcile <workspace-id-prefix|--last> [--write --yes --expected-epoch <epoch> --action quarantine|restore-backup|resume-export|resume-cleanup|discard-review] [--request-id <id>] [--format human|json]
    twelvgaige workspace review cleanup <workspace-id-prefix|--last> [--write --yes --expected-epoch <epoch>] [--request-id <id>] [--format human|json]
    twelvgaige workspace retention status [--format human|json]
    twelvgaige workspace retention run [--format human|json]
    twelvgaige workspace cleanup <workspace-id-prefix|--last> [--repo <path>] [--write --yes --expected-epoch <epoch>] [--request-id <id>] [--format human|json]
    twelvgaige session start (--plan <plan-path>|<task.md|task.yaml>|--task <text>|--task-file <task.md|task.yaml>) [--request-id <id>] [--profile <name>] [--auth-profile <id>] [--runtime codex] [--repo <path>] [--base-ref <ref>] [--source committed|staged|working-tree] [--include-untracked] [--include-ignored] [--sandbox podman|apple-container] [--network none|broker-only|unrestricted] [--unrestricted-network] [--allow-path <relative-path>] [--read-only] [--timeout <duration>] [--budget-tokens <count>] [--budget-cost-micros <count>] [--budget-tool-calls <count>] [--follow] [--follow-timeout-ms <ms>] [--poll-ms <ms>] [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige session plan (<task.md|task.yaml>|--task <text>|--task-file <task.md|task.yaml>) [--request-id <id>] [--profile <name>] [session authority options] [--output <plan-path>] [--format human|json]
    twelvgaige task validate <task.md|task.yaml> [--profile <name>] [session authority options] [--format human|json]
    twelvgaige session watch <session-id> [--poll-ms <ms>] [--timeout-ms <ms>] [--cancel-request-id <id>] [--format human|json]
    twelvgaige session review <session-id> [--format human|json]
    twelvgaige session retry <session-id> [--repair] [--format human|json]
    twelvgaige session export <session-id-prefix|--last> --output <directory> [--repo <path>] [--request-id <id>] [--format human|json]
    twelvgaige session apply <session-id-prefix|--last> [--target review-worktree|current-worktree] [--check|--write --yes --expected-epoch <epoch>] [--repo <path>] [--request-id <id>] [--format human|json]
    twelvgaige session list [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige session show <session-id> [--format human|json]
    twelvgaige session attach <session-id> [--format human|json]
    twelvgaige session takeover <session-id> --expected-epoch <epoch> [--format human|json]
    twelvgaige session cancel <session-id> [--request-id <id>] [--format human|json]
    twelvgaige session revoke <session-id> [--format human|json]
    twelvgaige sandbox setup [--backend podman|apple-container|auto] [--check] [--qualify-image] [--data-root <path>] [--source-root <path>] [--machine <name>] [--cpus <count>] [--memory-mib <mib>] [--disk-gib <gib>] [--worker-image <reference>] [--timeout-ms <milliseconds>] [--format human|json]
    twelvgaige sandbox health [--format human|json]
    twelvgaige sandbox reconcile [--apply] [--destroy-orphans] [--format human|json]
    twelvgaige operation show <request-id> [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige operations dashboard [--format human|json]
    twelvgaige operations audit status [--format human|json]
    twelvgaige operations audit checkpoint [--format human|json]
    twelvgaige operations audit export <path> [--format human|json]
    twelvgaige operations store stats [--format human|json]
    twelvgaige operations store backup <path> [--format human|json]
    twelvgaige operations store restore <backup-path> <destination-path> [--format human|json]
    twelvgaige operations retention status [--format human|json]
    twelvgaige operations retention run [--format human|json]
    twelvgaige operations artifact inventory [--format human|json]
    twelvgaige operations artifact rotate [--format human|json]
    twelvgaige operations release check [--format human|json]
    twelvgaige shell validate <path> [--format human|json]
    twelvgaige shell new <id> [--scaffold single-shot|inspect-analyze-gate-fix-verify] [--scaffold-path <path>] [--format yaml|json|toml] [--output <path>] [--write] [--force] [--root <path>]
    twelvgaige shell scaffold list [--format human|json] [--root <path>] [--scaffold-path <path>]
    twelvgaige shell scaffold show <scaffold-id> [--format human|json] [--root <path>] [--scaffold-path <path>]
    twelvgaige shell scaffold verify [--write-lock] [--lockfile <path>] [--format human|json] [--root <path>] [--scaffold-path <path>]
    twelvgaige shell scaffold update [--write-lock] [--lockfile <path>] [--format human|json] [--root <path>] [--scaffold-path <path>]
    twelvgaige shell scaffold outdated <path> [--format human|json] [--root <path>] [--scaffold-path <path>]
    twelvgaige shell author review <path> [--provider ollama|openai] [--model <model>] [--allow-remote] [--max-input-bytes <bytes>] [--format human|json] [--root <path>]
    twelvgaige shell patch inspect <patch-file> [--root <path>] [--format human|json]
    twelvgaige shell patch verify <patch-file> [--approval <approval-file>] --root <path> [--format human|json]
    twelvgaige shell patch apply <patch-file> [--approval <approval-file>] --root <path> [--write] [--format human|json]
    twelvgaige shell draft --from <file|-> [--provider ollama|openai] [--model <model>] [--allow-remote] [--max-input-bytes <bytes>] [--format yaml|json|toml] [--output <path> --write] [--force] [--root <path>]
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

  @spec text() :: String.t()
  def text, do: @usage

  @doc "Returns the public invocation lines used to build the typed command model."
  @spec command_usages() :: [String.t()]
  def command_usages do
    @usage
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&String.starts_with?(&1, "twelvgaige "))
  end
end
