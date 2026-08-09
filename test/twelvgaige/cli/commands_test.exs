defmodule Twelvgaige.CLI.CommandsTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.CLI.Main

  @workflow_path "test/fixtures/shells/simple_workflow.yaml"

  test "shell validate succeeds for workflow shells" do
    assert {:ok, output, 0} = Main.run(["shell", "validate", @workflow_path])

    assert output == "valid workflow shell: simple 1.0.0\n"
  end

  test "crypto status reports current security posture" do
    assert {:ok, output, 0} = Main.run(["crypto", "status"])

    assert output =~ "Crypto posture: ok"
    assert output =~ "Store:"
    assert output =~ "Native TLS: false"
    assert output =~ "local store is not encrypted by Twelvgaige"

    assert {:ok, output, 0} = Main.run(["crypto", "status", "--format", "json"])

    assert %{
             "status" => "ok",
             "store" => %{"encrypted" => false, "encryption" => "none"},
             "http_listener" => %{
               "native_tls_supported" => false,
               "mtls_supported" => false
             },
             "providers" => %{"hosted_tls_verification" => "configured"}
           } = Jason.decode!(output)
  end

  test "crypto sqlcipher-spike reports current driver feasibility" do
    root = tmp_dir!("twelvgaige_cli_sqlcipher_spike")
    path = Path.join(root, "encrypted.db")

    assert {:ok, output, 0} =
             Main.run(["crypto", "sqlcipher-spike", "--path", path])

    assert output =~ "SQLCipher spike: unavailable"
    assert output =~ "Available: false"
    refute File.exists?(path)

    assert {:ok, output, 0} =
             Main.run(["crypto", "sqlcipher-spike", "--path", path, "--format", "json"])

    assert %{
             "status" => "unavailable",
             "available" => false,
             "driver" => "ecto_sqlite3/exqlite",
             "path" => ^path,
             "migrations" => "skipped"
           } = Jason.decode!(output)

    refute File.exists?(path)
  end

  test "shell validate succeeds for JSON workflow shells" do
    assert {:ok, output, 0} =
             Main.run(["shell", "validate", "test/fixtures/shells/simple_workflow.json"])

    assert output == "valid workflow shell: simple 1.0.0\n"
  end

  test "shell validate succeeds for TOML workflow shells" do
    assert {:ok, output, 0} =
             Main.run(["shell", "validate", "test/fixtures/shells/simple_workflow.toml"])

    assert output == "valid workflow shell: simple 1.0.0\n"
  end

  test "shell validate can emit JSON" do
    assert {:ok, output, 0} = Main.run(["shell", "validate", @workflow_path, "--format", "json"])

    assert %{"kind" => "workflow", "id" => "simple", "shots" => ["first", "second"]} =
             Jason.decode!(output)
  end

  test "shell new prints a scaffolded workflow without writing" do
    assert {:ok, output, 0} = Main.run(["shell", "new", "demo", "--scaffold", "single-shot"])

    assert {:ok, workflow} = Twelvgaige.Shell.Loader.load(write_tmp_shell(output, ".yaml"))
    assert workflow.id == "demo"
    assert Enum.map(workflow.shots, & &1.id) == ["analyze"]
  end

  test "shell new can emit JSON scaffold output" do
    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "new",
               "demo_json",
               "--scaffold",
               "single-shot",
               "--format",
               "json"
             ])

    assert %{
             "kind" => "workflow",
             "id" => "demo_json",
             "shots" => [%{"id" => "analyze", "agent" => "demo_json_agent"}]
           } = Jason.decode!(output)
  end

  test "shell new rejects the removed mock-agent option" do
    assert {:ok, output, 4} =
             Main.run(["shell", "new", "incident", "--with-mock-agents"])

    assert output =~ "unknown option --with-mock-agents"
  end

  test "shell scaffold commands manage local scaffold libraries" do
    root = tmp_dir!("twelvgaige_cli_scaffold_library")
    scaffolds_dir = Path.join(root, "scaffolds")
    workflow_path = Path.join(root, "workflows/review.yaml")
    scaffold_path = Path.join(scaffolds_dir, "team.review.yaml")
    File.mkdir_p!(scaffolds_dir)
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(scaffold_path, local_scaffold_yaml())

    assert {:ok, output, 0} =
             Main.run(["shell", "scaffold", "list", "--root", root, "--format", "json"])

    scaffolds = Jason.decode!(output)
    assert Enum.any?(scaffolds, &(&1["namespace"] == "team" and &1["id"] == "team.review"))

    assert {:ok, output, 0} =
             Main.run(["shell", "scaffold", "show", "team/team.review", "--root", root])

    assert output =~ "Scaffold: team/team.review"
    assert output =~ "Review input."

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "new",
               "review_flow",
               "--scaffold",
               "team/team.review",
               "--root",
               root,
               "--output",
               workflow_path,
               "--write"
             ])

    assert output =~ "created workflow shell: #{workflow_path}"

    assert {:ok, output, 0} =
             Main.run(["shell", "scaffold", "verify", "--root", root, "--write-lock"])

    assert output =~ "Status: OK"

    File.write!(
      scaffold_path,
      String.replace(local_scaffold_yaml(), "Review input.", "Review drift.")
    )

    assert {:ok, output, 4} = Main.run(["shell", "scaffold", "verify", "--root", root])
    assert output =~ "digest_mismatch"
    assert output =~ "team/team.review"

    assert {:ok, output, 4} =
             Main.run(["shell", "scaffold", "outdated", root, "--root", root])

    assert output =~ "Scaffold library outdated:"
    assert output =~ "digest_mismatch"

    assert {:ok, output, 0} = Main.run(["shell", "scaffold", "update", "--root", root])
    assert output =~ "Mode: dry_run"
    assert output =~ "Changed: true"
  end

  test "shell author review prints read-only disclosure and patch plan" do
    path = write_tmp_shell(workflow_yaml(), ".yaml")

    assert {:ok, output, 0} = Main.run(["shell", "author", "review", path])

    assert output =~ "Shell author review:"
    assert output =~ "Writes files: false"
    assert output =~ "Tools exposed:"
    assert output =~ "Plan digest: sha256:"

    assert {:ok, output, 0} =
             Main.run(["shell", "author", "review", path, "--format", "json"])

    assert %{
             "kind" => "twelvgaige.author_review",
             "disclosure" => %{"writes_files" => false},
             "patch_plan" => %{"plan_digest" => "sha256:" <> _}
           } = Jason.decode!(output)
  end

  test "shell author review requires consent for hosted providers" do
    path = write_tmp_shell(workflow_yaml(), ".yaml")

    assert {:ok, output, 7} =
             Main.run(["shell", "author", "review", path, "--provider", "openai"])

    assert output =~ "--allow-remote"
  end

  test "shell patch inspect and verify report digest-bound artifacts" do
    root = tmp_dir!("twelvgaige_cli_patch")
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch =
      cli_patch_artifact("workflows/review.yaml", workflow_yaml(), updated_patch_workflow_yaml())

    patch = Map.put(patch, "patch_digest", Twelvgaige.Authoring.Patch.canonical_digest(patch))
    File.write!(patch_path, Jason.encode!(patch, pretty: true))

    assert {:ok, output, 0} = Main.run(["shell", "patch", "inspect", patch_path])
    assert output =~ "Shell patch inspect:"
    assert output =~ "Changed: false"
    assert output =~ "Patch digest: sha256:"

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "patch",
               "verify",
               patch_path,
               "--root",
               root,
               "--format",
               "json"
             ])

    assert %{"status" => "ok", "changed" => false, "findings" => []} = Jason.decode!(output)
  end

  test "shell patch verify catches stale files" do
    root = tmp_dir!("twelvgaige_cli_patch_stale")
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, updated_patch_workflow_yaml())

    patch =
      cli_patch_artifact("workflows/review.yaml", workflow_yaml(), updated_patch_workflow_yaml())

    patch = Map.put(patch, "patch_digest", Twelvgaige.Authoring.Patch.canonical_digest(patch))
    File.write!(patch_path, Jason.encode!(patch, pretty: true))

    assert {:ok, output, 4} = Main.run(["shell", "patch", "verify", patch_path, "--root", root])

    assert output =~ "Status: FAILED"
    assert output =~ "before_digest_mismatch"
  end

  test "shell patch apply without write is a dry run" do
    root = tmp_dir!("twelvgaige_cli_patch_apply")
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch =
      cli_patch_artifact("workflows/review.yaml", workflow_yaml(), updated_patch_workflow_yaml())

    patch = Map.put(patch, "patch_digest", Twelvgaige.Authoring.Patch.canonical_digest(patch))
    File.write!(patch_path, Jason.encode!(patch, pretty: true))

    assert {:ok, output, 0} = Main.run(["shell", "patch", "apply", patch_path, "--root", root])

    assert output =~ "Shell patch apply:"
    assert output =~ "Mode: dry_run"
    assert output =~ "Changed: false"
    assert File.read!(workflow_path) == workflow_yaml()

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "patch",
               "apply",
               patch_path,
               "--root",
               root,
               "--format",
               "json"
             ])

    assert %{
             "kind" => "twelvgaige.patch.apply",
             "mode" => "dry_run",
             "changed" => false
           } = Jason.decode!(output)
  end

  test "shell patch apply --write requires approval" do
    root = tmp_dir!("twelvgaige_cli_patch_apply_write")
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch =
      cli_patch_artifact("workflows/review.yaml", workflow_yaml(), updated_patch_workflow_yaml())

    patch = Map.put(patch, "patch_digest", Twelvgaige.Authoring.Patch.canonical_digest(patch))
    File.write!(patch_path, Jason.encode!(patch, pretty: true))

    assert {:ok, output, 4} =
             Main.run(["shell", "patch", "apply", patch_path, "--root", root, "--write"])

    assert output =~ "Status: FAILED"
    assert output =~ "approval_required"
    assert File.read!(workflow_path) == workflow_yaml()
  end

  test "shell patch apply --write writes approved patch" do
    root = tmp_dir!("twelvgaige_cli_patch_apply_write_approved")
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    approval_path = Path.join(root, "approval.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch =
      cli_patch_artifact("workflows/review.yaml", workflow_yaml(), updated_patch_workflow_yaml())

    patch = Map.put(patch, "patch_digest", Twelvgaige.Authoring.Patch.canonical_digest(patch))
    File.write!(patch_path, Jason.encode!(patch, pretty: true))

    File.write!(
      approval_path,
      Jason.encode!(cli_patch_approval(patch["patch_digest"]), pretty: true)
    )

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "patch",
               "apply",
               patch_path,
               "--root",
               root,
               "--approval",
               approval_path,
               "--write"
             ])

    assert output =~ "Status: OK"
    assert output =~ "Mode: write"
    assert output =~ "Changed: true"
    assert File.read!(workflow_path) == updated_patch_workflow_yaml()
  end

  test "shell patch apply --write reports post-write validation failures as JSON" do
    root = tmp_dir!("twelvgaige_cli_patch_apply_write_validation_json")
    workflow_path = Path.join(root, "workflows/review.yaml")
    patch_path = Path.join(root, "patch.json")
    approval_path = Path.join(root, "approval.json")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, workflow_yaml())

    patch =
      cli_patch_artifact("workflows/review.yaml", workflow_yaml(), updated_patch_workflow_yaml())
      |> Map.put("validations", [
        %{"command" => "shell validate", "path" => "workflows/review.yaml"},
        %{"command" => "shell validate", "path" => "workflows/missing.yaml"}
      ])

    patch = Map.put(patch, "patch_digest", Twelvgaige.Authoring.Patch.canonical_digest(patch))
    File.write!(patch_path, Jason.encode!(patch, pretty: true))

    File.write!(
      approval_path,
      Jason.encode!(cli_patch_approval(patch["patch_digest"]), pretty: true)
    )

    assert {:ok, output, 1} =
             Main.run([
               "shell",
               "patch",
               "apply",
               patch_path,
               "--root",
               root,
               "--approval",
               approval_path,
               "--write",
               "--format",
               "json"
             ])

    assert %{
             "kind" => "twelvgaige.patch.apply",
             "status" => "failed",
             "changed" => true,
             "mode" => "write",
             "post_write_validations" => [_ok_validation, failed_validation],
             "findings" => findings
           } = Jason.decode!(output)

    assert failed_validation["status"] == "failed"
    assert Enum.any?(findings, &(&1["status"] == "post_write_validation_target_unknown"))
    assert File.read!(workflow_path) == updated_patch_workflow_yaml()
  end

  test "shell new refuses to overwrite without force" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_cli_new_force_#{System.unique_integer([:positive])}"
      )

    output_path = Path.join(root, "workflow.yaml")
    File.mkdir_p!(root)
    File.write!(output_path, "already here")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, output, 4} =
             Main.run([
               "shell",
               "new",
               "demo",
               "--output",
               output_path,
               "--write"
             ])

    assert output =~ "output file already exists"

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "new",
               "demo",
               "--output",
               output_path,
               "--write",
               "--force"
             ])

    assert output =~ "created workflow shell"
    assert {:ok, workflow} = Twelvgaige.Shell.Loader.load(output_path)
    assert workflow.id == "demo"
  end

  test "shell draft prints a validated candidate without writing" do
    source = write_tmp_shell("review failed CI and summarize likely root cause", ".txt")

    assert {:ok, output, 0} = Main.run(["shell", "draft", "--from", source])

    assert {:ok, workflow} = Twelvgaige.Shell.Loader.load(write_tmp_shell(output, ".yaml"))
    assert workflow.id == "drafted_workflow"
  end

  test "shell draft writes an output file only with explicit write flag" do
    root = tmp_dir!("twelvgaige_cli_draft")
    source = Path.join(root, "request.txt")
    output_path = Path.join(root, "workflows/drafted.yaml")
    File.write!(source, "build a guarded review workflow")

    assert {:ok, output, 4} =
             Main.run([
               "shell",
               "draft",
               "--from",
               source,
               "--output",
               output_path,
               "--root",
               root
             ])

    assert output =~ "--write"
    refute File.exists?(output_path)

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "draft",
               "--from",
               source,
               "--output",
               output_path,
               "--write",
               "--root",
               root
             ])

    assert output == "created draft workflow shell: #{output_path}\n"
    assert {:ok, workflow} = Twelvgaige.Shell.Loader.load(output_path)
    assert workflow.id == "drafted_workflow"
  end

  test "shell draft refuses hosted providers without allow remote" do
    source = write_tmp_shell("draft using OpenAI", ".txt")

    assert {:ok, output, 7} =
             Main.run(["shell", "draft", "--from", source, "--provider", "openai"])

    assert output =~ "hosted provider drafting requires --allow-remote"
  end

  test "shot rename defaults to dry-run diff output" do
    path = write_tmp_shell(rename_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} = Main.run(["shot", "rename", path, "gather", "inspect"])

    assert output =~ "dry run: shot rename gather -> inspect"
    assert output =~ "updated dependencies: 1"
    assert output =~ "--- #{path}"
    assert output =~ ~s|+    id: "inspect"|

    assert File.read!(path) =~ "id: gather"
  end

  test "shot rename writes a canonical validated workflow with dependency updates" do
    path = write_tmp_shell(rename_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} = Main.run(["shot", "rename", path, "gather", "inspect", "--write"])

    assert output =~ "renamed shot: gather -> inspect"
    assert output =~ "wrote: true"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert Enum.map(workflow.shots, & &1.id) == ["inspect", "analyze"]
    assert [%{depends_on: ["inspect"]}] = Enum.filter(workflow.shots, &(&1.id == "analyze"))
  end

  test "shot rename rewrites condition references" do
    path = write_tmp_shell(rename_condition_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run(["shot", "rename", path, "gather", "inspect", "--format", "json"])

    assert %{
             "old_id" => "gather",
             "new_id" => "inspect",
             "updated_conditions" => 1,
             "diff" => diff
           } = Jason.decode!(output)

    assert diff =~ "shots.inspect.status"
  end

  test "shot remove defaults to dry-run diff output" do
    path = write_tmp_shell(rename_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} = Main.run(["shot", "remove", path, "analyze"])

    assert output =~ "dry run: shot remove analyze"
    assert output =~ "removed ids: analyze"
    assert output =~ "dependent ids: none"
    assert output =~ ~s|-    id: "analyze"|

    assert File.read!(path) =~ "id: analyze"
  end

  test "shot remove refuses dependents unless cascade is confirmed" do
    path = write_tmp_shell(remove_cascade_workflow_yaml(), ".yaml")

    assert {:ok, output, 4} =
             Main.run(["shot", "remove", path, "gather", "--format", "json"])

    assert %{
             "error" => %{
               "message" => message,
               "details" => %{"dependent_ids" => ["analyze", "verify"]}
             }
           } = Jason.decode!(output)

    assert message =~ "--cascade --yes"
  end

  test "shot remove writes cascade removals when confirmed" do
    path = write_tmp_shell(remove_cascade_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run(["shot", "remove", path, "gather", "--cascade", "--yes", "--write"])

    assert output =~ "removed shot: gather"
    assert output =~ "removed ids: gather, analyze, verify"
    assert output =~ "wrote: true"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert Enum.map(workflow.shots, & &1.id) == ["notify"]
  end

  test "shot move defaults to dry-run diff output" do
    path = write_tmp_shell(remove_cascade_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} = Main.run(["shot", "move", path, "notify", "--before", "analyze"])

    assert output =~ "dry run: shot move notify before analyze"
    assert output =~ "original index: 3"
    assert output =~ "new index: 1"
    assert output =~ "--- #{path}"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert Enum.map(workflow.shots, & &1.id) == ["gather", "analyze", "verify", "notify"]
  end

  test "shot move writes a canonical reordered workflow" do
    path = write_tmp_shell(remove_cascade_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run(["shot", "move", path, "notify", "--before", "analyze", "--write"])

    assert output =~ "moved shot: notify before analyze"
    assert output =~ "wrote: true"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert Enum.map(workflow.shots, & &1.id) == ["gather", "notify", "analyze", "verify"]
  end

  test "shot move requires exactly one position target" do
    path = write_tmp_shell(remove_cascade_workflow_yaml(), ".yaml")

    assert {:ok, output, 4} = Main.run(["shot", "move", path, "notify", "--format", "json"])
    assert output =~ "requires --before or --after"

    assert {:ok, output, 4} =
             Main.run(["shot", "move", path, "notify", "--before", "gather", "--after", "verify"])

    assert output =~ "exactly one"
  end

  test "shot gate inserts a safety dependency before a target" do
    path = write_tmp_shell(remove_cascade_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run(["shot", "gate", path, "verify", "--id", "approve_verify"])

    assert output =~ "dry run: shot gate verify with approve_verify"
    assert output =~ "gate dependencies: analyze"
    assert output =~ "target dependencies: approve_verify"

    assert File.read!(path) =~ "id: verify"
    refute File.read!(path) =~ "approve_verify"

    assert {:ok, output, 0} =
             Main.run(["shot", "gate", path, "verify", "--id", "approve_verify", "--write"])

    assert output =~ "inserted safety gate: approve_verify"
    assert output =~ "wrote: true"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)

    assert Enum.map(workflow.shots, & &1.id) == [
             "gather",
             "analyze",
             "approve_verify",
             "verify",
             "notify"
           ]

    assert [%{kind: :safety, depends_on: ["analyze"]}] =
             Enum.filter(workflow.shots, &(&1.id == "approve_verify"))

    assert [%{depends_on: ["approve_verify"]}] = Enum.filter(workflow.shots, &(&1.id == "verify"))
  end

  test "shot gate requires a gate id" do
    path = write_tmp_shell(remove_cascade_workflow_yaml(), ".yaml")

    assert {:ok, output, 4} = Main.run(["shot", "gate", path, "verify", "--format", "json"])
    assert output =~ "shot gate requires --id"
  end

  test "shot schema set updates a shot output schema" do
    path = write_tmp_shell(rename_workflow_yaml(), ".yaml")

    schema_path =
      write_tmp_shell(
        Jason.encode!(%{
          "type" => "object",
          "required" => ["status"],
          "properties" => %{"status" => %{"type" => "string"}},
          "additionalProperties" => false
        }),
        ".json"
      )

    assert {:ok, output, 0} =
             Main.run(["shot", "schema", "set", path, "analyze", schema_path])

    assert output =~ "dry run: shot schema set analyze"
    assert output =~ "schema type: object"
    refute File.read!(path) =~ "output_schema"

    assert {:ok, output, 0} =
             Main.run(["shot", "schema", "set", path, "analyze", schema_path, "--write"])

    assert output =~ "set output schema: analyze"
    assert output =~ "wrote: true"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)

    assert [%{output_schema: %{root: %{"required" => ["status"]}}}] =
             Enum.filter(workflow.shots, &(&1.id == "analyze"))
  end

  test "shot schema set rejects invalid schema JSON" do
    path = write_tmp_shell(rename_workflow_yaml(), ".yaml")
    schema_path = write_tmp_shell(~s({"unsupported": true}), ".json")

    assert {:ok, output, 4} =
             Main.run(["shot", "schema", "set", path, "analyze", schema_path, "--format", "json"])

    assert output =~ "unsupported schema keyword"
  end

  test "shot replace-agent updates matching shots after contextual lint" do
    path =
      write_workflow_with_agents!(replace_agent_workflow_yaml(), [
        agent_yaml("old_agent", ["kubectl_get"]),
        agent_yaml("new_agent", ["kubectl_get"])
      ])

    assert {:ok, output, 0} =
             Main.run(["shot", "replace-agent", path, "old_agent", "new_agent"])

    assert output =~ "dry run: shot replace-agent old_agent -> new_agent"
    assert output =~ "changed shots: gather, analyze"
    assert output =~ "contextual lint: passed"
    assert File.read!(path) =~ "old_agent"

    assert {:ok, output, 0} =
             Main.run(["shot", "replace-agent", path, "old_agent", "new_agent", "--write"])

    assert output =~ "replaced agent: old_agent -> new_agent"
    assert output =~ "wrote: true"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert Enum.map(workflow.shots, & &1.agent) == ["new_agent", "new_agent"]
  end

  test "shot replace-agent rejects undiscovered or incompatible agents" do
    path =
      write_workflow_with_agents!(replace_agent_workflow_yaml(), [
        agent_yaml("old_agent", ["kubectl_get"])
      ])

    assert {:ok, output, 4} =
             Main.run(["shot", "replace-agent", path, "old_agent", "missing_agent"])

    assert output =~ "replacement agent shell was not discovered"

    incompatible_path =
      write_workflow_with_agents!(replace_agent_workflow_yaml(), [
        agent_yaml("old_agent", ["kubectl_get"]),
        agent_yaml("new_agent", ["http_get"])
      ])

    assert {:ok, output, 4} =
             Main.run([
               "shot",
               "replace-agent",
               incompatible_path,
               "old_agent",
               "new_agent",
               "--format",
               "json"
             ])

    assert output =~ "replacement agent failed contextual lint"
    assert output =~ "shot.tool.not_allowed_by_agent"
  end

  test "shot replace-tool updates matching tools after contextual lint" do
    path =
      write_workflow_with_agents!(replace_tool_workflow_yaml(), [
        agent_yaml("mock_agent", ["kubectl_get", "http_get"])
      ])

    assert {:ok, output, 0} =
             Main.run(["shot", "replace-tool", path, "kubectl_get", "http_get"])

    assert output =~ "dry run: shot replace-tool kubectl_get -> http_get"
    assert output =~ "changed shots: gather, analyze"
    assert output =~ "contextual lint: passed"
    assert File.read!(path) =~ "kubectl_get"

    assert {:ok, output, 0} =
             Main.run(["shot", "replace-tool", path, "kubectl_get", "http_get", "--write"])

    assert output =~ "replaced tool: kubectl_get -> http_get"
    assert output =~ "wrote: true"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert Enum.map(workflow.shots, & &1.tools) == [["http_get"], ["http_get"]]
  end

  test "shot replace-tool rejects unknown or incompatible replacement tools" do
    unknown_path =
      write_workflow_with_agents!(replace_tool_workflow_yaml(), [
        agent_yaml("mock_agent", ["kubectl_get"])
      ])

    assert {:ok, output, 4} =
             Main.run([
               "shot",
               "replace-tool",
               unknown_path,
               "kubectl_get",
               "missing_tool",
               "--format",
               "json"
             ])

    assert output =~ "replacement tool failed contextual lint"
    assert output =~ "shot.tool.unknown"

    incompatible_path =
      write_workflow_with_agents!(replace_tool_workflow_yaml(), [
        agent_yaml("mock_agent", ["kubectl_get"])
      ])

    assert {:ok, output, 4} =
             Main.run([
               "shot",
               "replace-tool",
               incompatible_path,
               "kubectl_get",
               "http_get",
               "--format",
               "json"
             ])

    assert output =~ "replacement tool failed contextual lint"
    assert output =~ "shot.tool.not_allowed_by_agent"
  end

  test "shot split replaces a shot with draft children after contextual lint" do
    path =
      write_workflow_with_agents!(split_workflow_yaml(), [
        agent_yaml("mock_agent", ["kubectl_get"])
      ])

    assert {:ok, output, 0} =
             Main.run([
               "shot",
               "split",
               path,
               "analyze",
               "--into",
               "identify_cause,summarize_cause"
             ])

    assert output =~ "dry run: shot split analyze into identify_cause, summarize_cause"
    assert output =~ "rewired dependents: verify"
    assert output =~ "updated conditions: 1"
    assert output =~ "contextual lint: passed"
    assert File.read!(path) =~ "id: analyze"

    assert {:ok, output, 0} =
             Main.run([
               "shot",
               "split",
               path,
               "analyze",
               "--into",
               "identify_cause,summarize_cause",
               "--write"
             ])

    assert output =~ "split shot: analyze"
    assert output =~ "wrote: true"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)

    assert Enum.map(workflow.shots, & &1.id) == [
             "gather",
             "identify_cause",
             "summarize_cause",
             "verify"
           ]

    assert [verify] = Enum.filter(workflow.shots, &(&1.id == "verify"))
    assert verify.depends_on == ["summarize_cause"]
  end

  test "shot split requires children and reports contextual lint failures" do
    path =
      write_workflow_with_agents!(split_workflow_yaml(), [
        agent_yaml("mock_agent", ["http_get"])
      ])

    assert {:ok, output, 4} = Main.run(["shot", "split", path, "analyze"])
    assert output =~ "shot split requires --into"

    assert {:ok, output, 4} =
             Main.run([
               "shot",
               "split",
               path,
               "analyze",
               "--into",
               "identify_cause,summarize_cause",
               "--format",
               "json"
             ])

    assert output =~ "split workflow failed contextual lint"
    assert output =~ "shot.tool.not_allowed_by_agent"
  end

  test "shot merge replaces a source chain after contextual lint" do
    path =
      write_workflow_with_agents!(merge_workflow_yaml(), [
        agent_yaml("mock_agent", ["kubectl_get", "http_get"])
      ])

    assert {:ok, output, 0} =
             Main.run([
               "shot",
               "merge",
               path,
               "analyze",
               "verify",
               "--id",
               "analyze_and_verify"
             ])

    assert output =~ "dry run: shot merge analyze, verify -> analyze_and_verify"
    assert output =~ "rewired dependents: notify"
    assert output =~ "updated conditions: 1"
    assert output =~ "contextual lint: passed"
    assert File.read!(path) =~ "id: analyze"

    assert {:ok, output, 0} =
             Main.run([
               "shot",
               "merge",
               path,
               "analyze",
               "verify",
               "--id",
               "analyze_and_verify",
               "--write"
             ])

    assert output =~ "merged shots: analyze, verify -> analyze_and_verify"
    assert output =~ "wrote: true"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert Enum.map(workflow.shots, & &1.id) == ["gather", "analyze_and_verify", "notify"]

    assert [merged] = Enum.filter(workflow.shots, &(&1.id == "analyze_and_verify"))
    assert merged.depends_on == ["gather"]
    assert merged.tools == ["kubectl_get", "http_get"]

    assert [notify] = Enum.filter(workflow.shots, &(&1.id == "notify"))
    assert notify.depends_on == ["analyze_and_verify"]
    assert notify.condition == "shots.analyze_and_verify.output.summary == \"ok\""
  end

  test "shot merge requires id and reports contextual lint failures" do
    path =
      write_workflow_with_agents!(merge_workflow_yaml(), [
        agent_yaml("mock_agent", ["kubectl_get"])
      ])

    assert {:ok, output, 4} = Main.run(["shot", "merge", path, "analyze", "verify"])
    assert output =~ "shot merge requires --id"

    assert {:ok, output, 4} =
             Main.run([
               "shot",
               "merge",
               path,
               "analyze",
               "verify",
               "--id",
               "analyze_and_verify",
               "--format",
               "json"
             ])

    assert output =~ "split workflow failed contextual lint"
    assert output =~ "shot.tool.not_allowed_by_agent"
  end

  test "shot add defaults to dry-run diff output" do
    path = write_tmp_shell(rename_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run([
               "shot",
               "add",
               path,
               "verify",
               "--kind",
               "slug",
               "--agent",
               "mock_agent",
               "--depends-on",
               "analyze",
               "--prompt",
               "verify",
               "--after",
               "analyze"
             ])

    assert output =~ "dry run: shot add verify"
    assert output =~ "position: after analyze"
    assert output =~ "new index: 2"
    assert output =~ ~s|+    id: "verify"|

    assert File.read!(path) =~ "id: analyze"
    refute File.read!(path) =~ "id: verify"
  end

  test "shot add writes a canonical slug shot" do
    path = write_tmp_shell(rename_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run([
               "shot",
               "add",
               path,
               "verify",
               "--kind",
               "slug",
               "--agent",
               "mock_agent",
               "--depends-on",
               "analyze",
               "--tool",
               "shell_read",
               "--prompt",
               "verify",
               "--write"
             ])

    assert output =~ "added shot: verify"
    assert output =~ "wrote: true"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert Enum.map(workflow.shots, & &1.id) == ["gather", "analyze", "verify"]

    assert [%{depends_on: ["analyze"], tools: ["shell_read"]}] =
             Enum.filter(workflow.shots, &(&1.id == "verify"))
  end

  test "shot add writes a safety shot without agent or tools" do
    path = write_tmp_shell(rename_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run([
               "shot",
               "add",
               path,
               "approve",
               "--kind",
               "safety",
               "--before",
               "analyze",
               "--write"
             ])

    assert output =~ "added shot: approve"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert Enum.map(workflow.shots, & &1.id) == ["gather", "approve", "analyze"]

    assert [%{kind: :safety, agent: nil, tools: []}] =
             Enum.filter(workflow.shots, &(&1.id == "approve"))
  end

  test "shot add refuses duplicate ids and missing required options" do
    path = write_tmp_shell(rename_workflow_yaml(), ".yaml")

    assert {:ok, output, 4} =
             Main.run(["shot", "add", path, "verify", "--agent", "mock_agent"])

    assert output =~ "shot add requires --kind"

    assert {:ok, output, 4} =
             Main.run(["shot", "add", path, "gather", "--kind", "slug", "--agent", "mock_agent"])

    assert output =~ "already exists"
  end

  test "shot library list and show expose built-in templates" do
    assert {:ok, output, 0} = Main.run(["shot", "library", "list"])

    assert output =~ "builtin/analysis.slug"
    assert output =~ "builtin/safety.approval_gate"

    assert {:ok, output, 0} = Main.run(["shot", "library", "show", "builtin/analysis.slug"])

    assert output =~ "Shot template: builtin/analysis.slug"
    assert output =~ "kind: \"slug\""
  end

  test "shot library list loads local templates from root shots directory" do
    root = tmp_dir!("twelvgaige_cli_library")
    shots_dir = Path.join(root, "shots")
    File.mkdir_p!(shots_dir)
    File.write!(Path.join(shots_dir, "team.review.yaml"), local_shot_template_yaml())

    assert {:ok, output, 0} =
             Main.run(["shot", "library", "list", "--root", root, "--format", "json"])

    templates = Jason.decode!(output)
    assert Enum.any?(templates, &(&1["id"] == "team.review" and &1["namespace"] == "team"))
  end

  test "shot library verify writes and checks a local lockfile" do
    root = tmp_dir!("twelvgaige_cli_library_verify")
    shots_dir = Path.join(root, "shots")
    lockfile = Path.join(root, "twelvgaige-library.lock")
    template_path = Path.join(shots_dir, "team.review.yaml")
    File.mkdir_p!(shots_dir)
    File.write!(template_path, local_shot_template_yaml())

    assert {:ok, output, 0} =
             Main.run(["shot", "library", "verify", "--root", root, "--write-lock"])

    assert output =~ "Status: OK"
    assert File.exists?(lockfile)

    assert {:ok, output, 0} =
             Main.run(["shot", "library", "verify", "--root", root, "--format", "json"])

    assert %{"status" => "ok", "findings" => []} = Jason.decode!(output)

    File.write!(
      template_path,
      String.replace(local_shot_template_yaml(), "Review the change.", "Review drift.")
    )

    assert {:ok, output, 4} = Main.run(["shot", "library", "verify", "--root", root])

    assert output =~ "digest_mismatch"
    assert output =~ "team/team.review"

    assert {:ok, output, 0} = Main.run(["shot", "library", "update", "--root", root])

    assert output =~ "Shot library update:"
    assert output =~ "Mode: dry_run"
    assert output =~ "Changed: true"
    assert output =~ "digest_mismatch"

    assert {:ok, output, 0} =
             Main.run(["shot", "library", "update", "--root", root, "--write-lock"])

    assert output =~ "Mode: write_lock"

    assert {:ok, output, 0} =
             Main.run(["shot", "library", "verify", "--root", root, "--format", "json"])

    assert %{"status" => "ok", "findings" => []} = Jason.decode!(output)
  end

  test "shot library outdated reports stale copied template shots" do
    root = tmp_dir!("twelvgaige_cli_library_outdated")
    shots_dir = Path.join(root, "shots")
    workflow_path = Path.join(root, "workflows/review.yaml")
    template_path = Path.join(shots_dir, "team.review.yaml")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.mkdir_p!(shots_dir)
    File.write!(template_path, local_shot_template_yaml())

    {:ok, template} = Twelvgaige.Authoring.ShotLibrary.fetch("team/team.review", root: root)
    File.write!(workflow_path, workflow_with_template_source_yaml(template))

    assert {:ok, output, 0} =
             Main.run(["shot", "library", "outdated", root, "--root", root, "--format", "json"])

    assert %{"status" => "ok", "findings" => [], "checked_shots" => 1} = Jason.decode!(output)

    File.write!(
      template_path,
      String.replace(local_shot_template_yaml(), "Review the change.", "Review drift.")
    )

    assert {:ok, output, 4} =
             Main.run(["shot", "library", "outdated", root, "--root", root])

    assert output =~ "Shot library outdated:"
    assert output =~ "digest_mismatch"
    assert output =~ "library_cli_drift.review"
  end

  test "shot add inserts a template with provenance metadata" do
    path = write_tmp_shell(rename_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run([
               "shot",
               "add",
               path,
               "verify",
               "--template",
               "builtin/analysis.slug",
               "--depends-on",
               "analyze",
               "--write"
             ])

    assert output =~ "added shot: verify"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert [%{metadata: metadata} = shot] = Enum.filter(workflow.shots, &(&1.id == "verify"))
    assert shot.depends_on == ["analyze"]
    assert get_in(metadata.generated_by, ["source", "kind"]) == "template"
    assert get_in(metadata.generated_by, ["source", "id"]) == "analysis.slug"
    assert get_in(metadata.generated_by, ["source", "digest"]) =~ "sha256:"
  end

  test "shell normalize emits full canonical shell documents" do
    assert {:ok, output, 0} = Main.run(["shell", "normalize", @workflow_path])

    assert %{
             "kind" => "workflow",
             "id" => "simple",
             "shots" => [
               %{"id" => "first", "agent" => "mock_agent"},
               %{"id" => "second", "depends_on" => ["first"]}
             ]
           } = Jason.decode!(output)

    assert {:ok, toml_output, 0} =
             Main.run(["shell", "normalize", @workflow_path, "--format", "toml"])

    assert {:ok, _decoded} = TomlElixir.decode(toml_output, spec: :"1.0.0")
  end

  test "shell convert writes round-trippable documents" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige_cli_convert_#{System.unique_integer([:positive])}")

    output_path = Path.join(root, "workflow.yaml")

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "convert",
               "test/fixtures/shells/simple_workflow.toml",
               "--to",
               "yaml",
               "--output",
               output_path
             ])

    assert output == "converted shell: #{output_path}\n"

    assert {:ok, validate_output, 0} = Main.run(["shell", "validate", output_path])
    assert validate_output == "valid workflow shell: simple 1.0.0\n"
  end

  test "shell convert can print converted documents to stdout" do
    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "convert",
               "test/fixtures/shells/simple_workflow.yaml",
               "--to",
               "json"
             ])

    assert %{"kind" => "workflow", "id" => "simple"} = Jason.decode!(output)
  end

  test "shell convert requires a target format" do
    assert {:ok, output, 4} =
             Main.run(["shell", "convert", "test/fixtures/shells/simple_workflow.yaml"])

    assert output =~ "--to is required"
  end

  test "shell fmt defaults to dry-run diff output" do
    path = write_tmp_shell(messy_fmt_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} = Main.run(["shell", "fmt", path])

    assert output =~ "dry run: shell fmt #{path}"
    assert output =~ "wrote: false"
    assert output =~ "--- #{path}"
    assert File.read!(path) =~ "version: 1.0.0"
  end

  test "shell fmt check exits non-zero when formatting is needed" do
    path = write_tmp_shell(messy_fmt_workflow_yaml(), ".yaml")

    assert {:ok, output, 1} = Main.run(["shell", "fmt", path, "--check"])
    assert output == "shell fmt check failed: #{path} is not canonical\n"

    assert {:ok, output, 1} = Main.run(["shell", "fmt", path, "--check", "--format", "json"])

    assert %{"changed" => true, "mode" => "check", "exit_code" => 1} = Jason.decode!(output)
  end

  test "shell fmt writes atomically and validates the formatted shell" do
    path = write_tmp_shell(messy_fmt_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} = Main.run(["shell", "fmt", path, "--write"])

    assert output =~ "formatted shell: #{path}"
    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.id == "fmt_demo"

    assert {:ok, output, 0} = Main.run(["shell", "fmt", path, "--check"])
    assert output == "shell fmt check passed: #{path}\n"
  end

  test "shell fmt enforces root boundaries and option conflicts" do
    root = tmp_dir!("twelvgaige_cli_fmt_root")
    outside_path = write_tmp_shell(messy_fmt_workflow_yaml(), ".yaml")

    assert {:ok, output, 4} =
             Main.run(["shell", "fmt", outside_path, "--root", root, "--format", "json"])

    assert output =~ "outside the resolved traphouse root"

    path = Path.join(root, "workflow.yaml")
    File.write!(path, messy_fmt_workflow_yaml())

    assert {:ok, output, 4} = Main.run(["shell", "fmt", path, "--check", "--write"])
    assert output =~ "either --check or --write"
  end

  test "shell review defaults to dry-run diff output" do
    path = write_tmp_shell(lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} = Main.run(["shell", "review", path, "--by", "human:reviewer"])

    assert output =~ "dry run: shell review #{path}"
    assert output =~ "lifecycle: reviewed"
    assert output =~ "wrote: false"
    assert output =~ "reviewed_at"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.lifecycle == :draft
  end

  test "shell review writes current review metadata" do
    path = write_tmp_shell(lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run(["shell", "review", path, "--by", "human:reviewer", "--write"])

    assert output =~ "marked workflow review: #{path}"
    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.lifecycle == :reviewed
    assert Twelvgaige.Shell.Digest.current_binding?(workflow, :review)
  end

  test "shell approve requires scope and owner then writes current approval metadata" do
    no_owner = write_tmp_shell(no_owner_lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, output, 4} =
             Main.run(["shell", "approve", no_owner, "--by", "human:approver", "--scope", "prod"])

    assert output =~ "metadata.owner"

    path = write_tmp_shell(lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, output, 4} = Main.run(["shell", "approve", path, "--by", "human:approver"])
    assert output =~ "--scope"

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "approve",
               path,
               "--by",
               "human:approver",
               "--scope",
               "prod",
               "--write",
               "--format",
               "json"
             ])

    assert %{"action" => "approve", "lifecycle" => "approved", "wrote" => true} =
             Jason.decode!(output)

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.lifecycle == :approved
    assert Twelvgaige.Shell.Digest.current_binding?(workflow, :approval)
  end

  test "shell deprecate and retire update lifecycle metadata" do
    path = write_tmp_shell(lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "deprecate",
               path,
               "--by",
               "human:owner",
               "--reason",
               "replaced by lifecycle_v2"
             ])

    assert output =~ "dry run: shell deprecate #{path}"
    assert output =~ "lifecycle: deprecated"
    assert output =~ "reason: replaced by lifecycle_v2"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.lifecycle == :draft

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "retire",
               path,
               "--by",
               "human:owner",
               "--reason",
               "audit only",
               "--write",
               "--format",
               "json"
             ])

    assert %{
             "action" => "retire",
             "lifecycle" => "retired",
             "reason" => "audit only",
             "wrote" => true
           } = Jason.decode!(output)

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.lifecycle == :retired
    assert workflow.metadata.lifecycle_reason == "audit only"
  end

  test "shell deprecate and retire require reason" do
    path = write_tmp_shell(lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, output, 4} =
             Main.run(["shell", "deprecate", path, "--by", "human:owner"])

    assert output =~ "--reason"
  end

  test "shell metadata set updates owner and lifecycle labels" do
    path = write_tmp_shell(no_owner_lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "metadata",
               "set",
               path,
               "--owner",
               "platform",
               "--lifecycle",
               "reviewed"
             ])

    assert output =~ "dry run: shell metadata set #{path}"
    assert output =~ "changed fields:"
    assert output =~ "owner"
    assert output =~ "lifecycle"
    assert output =~ "wrote: false"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.owner == nil

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "metadata",
               "set",
               path,
               "--owner",
               "platform",
               "--lifecycle",
               "reviewed",
               "--write",
               "--format",
               "json"
             ])

    assert %{
             "action" => "set",
             "changed_fields" => changed_fields,
             "wrote" => true
           } = Jason.decode!(output)

    assert changed_fields == ["lifecycle", "owner"]

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.owner == "platform"
    assert workflow.metadata.lifecycle == :reviewed
    refute Twelvgaige.Shell.Digest.current_binding?(workflow, :review)
  end

  test "shell metadata clear removes review and approval bindings" do
    path = write_tmp_shell(lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, _output, 0} =
             Main.run([
               "shell",
               "approve",
               path,
               "--by",
               "human:approver",
               "--scope",
               "prod",
               "--write"
             ])

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.approval

    assert {:ok, output, 0} =
             Main.run(["shell", "metadata", "clear", path, "--approval"])

    assert output =~ "dry run: shell metadata clear #{path}"
    assert output =~ "cleared fields: approval"

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.approval

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "metadata",
               "clear",
               path,
               "--review",
               "--approval",
               "--write",
               "--format",
               "json"
             ])

    assert %{
             "action" => "clear",
             "cleared_fields" => ["review", "approval"],
             "wrote" => true
           } = Jason.decode!(output)

    assert {:ok, workflow} = Twelvgaige.validate_shell(path)
    assert workflow.metadata.review == nil
    assert workflow.metadata.approval == nil
  end

  test "shell metadata commands require explicit fields" do
    path = write_tmp_shell(lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, output, 4} = Main.run(["shell", "metadata", "set", path])
    assert output =~ "requires --owner or --lifecycle"

    assert {:ok, output, 4} = Main.run(["shell", "metadata", "clear", path])
    assert output =~ "requires --review or --approval"
  end

  test "shell admit checks approval-bound lifecycle policy" do
    path = write_tmp_shell(lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, _output, 0} =
             Main.run([
               "shell",
               "approve",
               path,
               "--by",
               "human:approver",
               "--scope",
               "prod",
               "--write"
             ])

    assert {:ok, output, 0} =
             Main.run(["shell", "admit", path, "--policy", "approved", "--format", "json"])

    assert %{"status" => "ok", "policy" => "approved", "findings" => []} = Jason.decode!(output)

    assert {:ok, output, 1} =
             Main.run(["shell", "admit", path, "--policy", "scheduled", "--format", "json"])

    assert %{"status" => "failed", "policy" => "scheduled", "findings" => findings} =
             Jason.decode!(output)

    assert Enum.any?(findings, &(&1["id"] == "lifecycle.scheduled_required"))
  end

  test "shell graph emits text output" do
    assert {:ok, output, 0} = Main.run(["shell", "graph", @workflow_path])

    assert output =~ "Workflow graph: simple 1.0.0"
    assert output =~ "Groups:"
    assert output =~ "1. first"
    assert output =~ "2. second"
    assert output =~ "first -> second"
  end

  test "shell graph emits stable JSON output" do
    assert {:ok, output, 0} = Main.run(["shell", "graph", @workflow_path, "--format", "json"])

    assert %{
             "status" => "ok",
             "exit_code" => 0,
             "errors" => [],
             "workflow_id" => "simple",
             "version" => "1.0.0",
             "groups" => [["first"], ["second"]],
             "edges" => [%{"from" => "first", "to" => "second"}],
             "nodes" => [
               %{
                 "id" => "first",
                 "kind" => "slug",
                 "dependencies" => [],
                 "dependents" => ["second"],
                 "safety" => false,
                 "write_capable" => false
               },
               %{
                 "id" => "second",
                 "kind" => "slug",
                 "dependencies" => ["first"],
                 "dependents" => [],
                 "safety" => false,
                 "write_capable" => false
               }
             ]
           } = Jason.decode!(output)
  end

  test "shell graph emits mermaid output" do
    assert {:ok, output, 0} =
             Main.run(["shell", "graph", @workflow_path, "--format", "mermaid"])

    assert output =~ "flowchart TD"
    assert output =~ ~s(n0["first<br/>slug<br/>mock_agent"])
    assert output =~ "n0 --> n1"
  end

  test "shell graph enforces explicit root boundaries" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige_cli_graph_#{System.unique_integer([:positive])}")

    workflow_path = Path.join(root, "workflows/simple.yaml")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.cp!(@workflow_path, workflow_path)

    outside_path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_cli_graph_outside_#{System.unique_integer([:positive])}.yaml"
      )

    File.cp!(@workflow_path, outside_path)

    on_exit(fn ->
      File.rm_rf(root)
      File.rm(outside_path)
    end)

    assert {:ok, _output, 0} =
             Main.run(["shell", "graph", workflow_path, "--root", root, "--format", "json"])

    assert {:ok, output, 4} =
             Main.run(["shell", "graph", outside_path, "--root", root, "--format", "json"])

    assert %{"error" => %{"reason" => "invalid_shell", "message" => message}} =
             Jason.decode!(output)

    assert message =~ "outside the resolved traphouse root"
  end

  test "shell graph rejects invalid formats" do
    assert {:ok, output, 4} =
             Main.run(["shell", "graph", @workflow_path, "--format", "dot"])

    assert output =~ "format must be text, json, or mermaid"
  end

  test "shell lint emits human output without failing warning-only reports" do
    assert {:ok, output, 0} = Main.run(["shell", "lint", @workflow_path])

    assert output =~ "Shell lint: #{@workflow_path}"
    assert output =~ "Status: OK"
    assert output =~ "shot.output_schema.missing"
    assert output =~ "shot.timeout.missing"
  end

  test "shell lint emits stable JSON output" do
    assert {:ok, output, 0} =
             Main.run(["shell", "lint", @workflow_path, "--format", "json", "--strict"])

    assert %{
             "path" => @workflow_path,
             "status" => "ok",
             "exit_code" => 0,
             "errors" => [],
             "skipped" => [],
             "findings" => findings
           } = Jason.decode!(output)

    assert Enum.any?(findings, &(&1["id"] == "shot.output_schema.missing"))
  end

  test "shell lint returns non-zero in strict mode for error-level findings" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige_cli_lint_#{System.unique_integer([:positive])}")

    workflow_path = Path.join(root, "unsafe.yaml")
    File.mkdir_p!(root)

    File.write!(workflow_path, """
    kind: workflow
    id: unsafe_lint
    version: 1.0.0
    shots:
      - id: apply
        kind: slug
        agent: mock_agent
        tools: [kubectl_apply]
    """)

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, output, 1} =
             Main.run(["shell", "lint", workflow_path, "--strict", "--format", "json"])

    assert %{"status" => "failed", "exit_code" => 1, "findings" => findings} =
             Jason.decode!(output)

    assert Enum.any?(findings, &(&1["id"] == "shot.safety.write_without_gate"))
  end

  test "shell lint scans directories and skips agent shells" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_cli_lint_dir_#{System.unique_integer([:positive])}"
      )

    workflow_path = Path.join(root, "workflows/simple.yaml")
    agent_path = Path.join(root, "workflows/agents/mock_agent.yaml")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.mkdir_p!(Path.dirname(agent_path))
    File.cp!(@workflow_path, workflow_path)
    File.cp!("test/fixtures/shells/mock_agent.yaml", agent_path)

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, output, 0} =
             Main.run(["shell", "lint", root, "--root", root, "--format", "json"])

    assert %{
             "path" => path,
             "status" => "ok",
             "reports" => [%{"path" => ^workflow_path}],
             "skipped" => [%{"path" => ^agent_path, "reason" => "agent_shell"}]
           } = Jason.decode!(output)

    assert path == Path.expand(root)
  end

  test "shell lint rejects invalid formats" do
    assert {:ok, output, 4} =
             Main.run(["shell", "lint", @workflow_path, "--format", "ndjson"])

    assert output =~ "format must be human or json"
  end

  test "shell doctor emits repair-oriented human output" do
    assert {:ok, output, 0} = Main.run(["shell", "doctor", @workflow_path])

    assert output =~ "Shell doctor: #{@workflow_path}"
    assert output =~ "Status: ATTENTION"
    assert output =~ "shot.output_schema.missing"
    assert output =~ "Add output_schema"
  end

  test "shell doctor emits stable JSON and can fail strict error findings" do
    root = tmp_dir!("twelvgaige_cli_doctor")
    workflow_path = Path.join(root, "unsafe.yaml")

    File.write!(workflow_path, """
    kind: workflow
    id: unsafe_doctor
    version: 1.0.0
    shots:
      - id: apply
        kind: slug
        agent: mock_agent
        tools: [kubectl_apply]
    """)

    assert {:ok, output, 1} =
             Main.run(["shell", "doctor", workflow_path, "--strict", "--format", "json"])

    assert %{
             "workflow_id" => "unsafe_doctor",
             "status" => "failed",
             "exit_code" => 1,
             "recommendations" => recommendations
           } = Jason.decode!(output)

    assert Enum.any?(recommendations, &(&1["id"] == "shot.safety.write_without_gate"))
  end

  test "shell doctor enforces root and workflow shell inputs" do
    root = tmp_dir!("twelvgaige_cli_doctor_root")
    outside_path = write_tmp_shell(agent_yaml(), ".yaml")

    assert {:ok, output, 4} =
             Main.run(["shell", "doctor", outside_path, "--root", root, "--format", "json"])

    assert output =~ "outside the resolved traphouse root"

    agent_path = Path.join(root, "agent.yaml")
    File.write!(agent_path, agent_yaml())

    assert {:ok, output, 4} =
             Main.run(["shell", "doctor", agent_path, "--root", root, "--format", "json"])

    assert %{"error" => %{"message" => message}} = Jason.decode!(output)
    assert message =~ "requires a workflow shell"
  end

  test "shell inventory scans a traphouse directory" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_cli_inventory_#{System.unique_integer([:positive])}"
      )

    workflow_path = Path.join(root, "workflows/deploy.yaml")
    agent_path = Path.join(root, "workflows/agents/operator.yaml")
    File.mkdir_p!(Path.dirname(agent_path))
    File.write!(workflow_path, inventory_workflow_yaml())
    File.write!(agent_path, inventory_agent_yaml())

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, output, 0} =
             Main.run(["shell", "inventory", root, "--root", root, "--format", "json"])

    assert %{
             "status" => "ok",
             "summary" => %{
               "workflow_count" => 1,
               "agent_count" => 1,
               "tools" => ["kubectl_apply", "kubectl_get"]
             },
             "workflows" => [
               %{
                 "id" => "deploy_check",
                 "owner" => "platform",
                 "write_capable" => true,
                 "agents" => ["operator"],
                 "providers" => ["mock"]
               }
             ],
             "agents" => [%{"id" => "operator"}]
           } = Jason.decode!(output)

    assert {:ok, output, 0} = Main.run(["shell", "inventory", root, "--root", root])
    assert output =~ "Shell inventory:"
    assert output =~ "deploy_check 1.0.0 owner=platform lifecycle=approved write"

    report_path = Path.join(root, "inventory/inventory.json")

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "inventory",
               root,
               "--root",
               root,
               "--output",
               report_path
             ])

    assert output == "wrote inventory report: #{report_path}\n"

    assert %{"summary" => %{"workflow_count" => 1}} =
             report_path |> File.read!() |> Jason.decode!()
  end

  test "shell impact reports affected workflows by selector" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige_cli_impact_#{System.unique_integer([:positive])}")

    workflow_path = Path.join(root, "workflows/deploy.yaml")
    agent_path = Path.join(root, "workflows/agents/operator.yaml")
    File.mkdir_p!(Path.dirname(agent_path))
    File.write!(workflow_path, inventory_workflow_yaml())
    File.write!(agent_path, inventory_agent_yaml())

    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "impact",
               root,
               "--root",
               root,
               "--tool",
               "kubectl_apply",
               "--format",
               "json"
             ])

    assert %{
             "selector" => %{"kind" => "tool", "value" => "kubectl_apply"},
             "summary" => %{"workflow_count" => 1, "shot_count" => 1},
             "matches" => [
               %{
                 "id" => "deploy_check",
                 "matching_shots" => [%{"id" => "apply", "tools" => ["kubectl_apply"]}]
               }
             ]
           } = Jason.decode!(output)

    assert {:ok, output, 0} =
             Main.run(["shell", "impact", root, "--root", root, "--agent", "operator"])

    assert output =~ "Selector: agent=operator"
    assert output =~ "deploy_check 1.0.0 shots=inspect,apply"

    report_path = Path.join(root, "inventory/impact-kubectl-apply.json")

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "impact",
               root,
               "--root",
               root,
               "--tool",
               "kubectl_apply",
               "--output",
               report_path
             ])

    assert output == "wrote impact report: #{report_path}\n"

    assert %{"selector" => %{"kind" => "tool"}, "summary" => %{"workflow_count" => 1}} =
             report_path |> File.read!() |> Jason.decode!()
  end

  test "shell report output refuses overwrite unless forced and stays under root" do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_cli_inventory_output_#{System.unique_integer([:positive])}"
      )

    workflow_path = Path.join(root, "workflows/deploy.yaml")
    File.mkdir_p!(Path.dirname(workflow_path))
    File.write!(workflow_path, inventory_workflow_yaml())

    report_path = Path.join(root, "inventory/report.json")
    File.mkdir_p!(Path.dirname(report_path))
    File.write!(report_path, "{}")

    outside_path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_cli_inventory_outside_#{System.unique_integer([:positive])}.json"
      )

    on_exit(fn ->
      File.rm_rf(root)
      File.rm(outside_path)
    end)

    assert {:ok, output, 4} =
             Main.run(["shell", "inventory", root, "--root", root, "--output", report_path])

    assert output =~ "output file already exists"

    assert {:ok, output, 4} =
             Main.run(["shell", "inventory", root, "--root", root, "--output", outside_path])

    assert output =~ "outside the resolved traphouse root"

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "inventory",
               root,
               "--root",
               root,
               "--output",
               report_path,
               "--force"
             ])

    assert output == "wrote inventory report: #{report_path}\n"
  end

  test "shell bulk replace-agent plans and writes matching workflow files" do
    root = tmp_dir!("twelvgaige_cli_bulk_replace_agent")
    workflows_dir = Path.join(root, "workflows")
    agents_dir = Path.join(workflows_dir, "agents")
    first_path = Path.join(workflows_dir, "first.yaml")
    second_path = Path.join(workflows_dir, "second.yaml")
    other_path = Path.join(workflows_dir, "other.yaml")

    File.mkdir_p!(agents_dir)
    File.write!(Path.join(agents_dir, "old_agent.yaml"), agent_yaml("old_agent", ["kubectl_get"]))
    File.write!(Path.join(agents_dir, "new_agent.yaml"), agent_yaml("new_agent", ["kubectl_get"]))
    File.write!(first_path, bulk_replace_agent_workflow_yaml("first_bulk", "old_agent"))
    File.write!(second_path, bulk_replace_agent_workflow_yaml("second_bulk", "old_agent"))
    File.write!(other_path, bulk_replace_agent_workflow_yaml("other_bulk", "other_agent"))

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "bulk",
               "replace-agent",
               root,
               "old_agent",
               "new_agent",
               "--root",
               root
             ])

    assert output =~ "Shell bulk replace-agent:"
    assert output =~ "Mode: DRY_RUN"
    assert output =~ "Changed workflows: 2"
    assert output =~ "wrote=false"
    assert File.read!(first_path) =~ "old_agent"

    assert {:ok, output, 4} =
             Main.run([
               "shell",
               "bulk",
               "replace-agent",
               root,
               "old_agent",
               "new_agent",
               "--root",
               root,
               "--write"
             ])

    assert output =~ "requires --yes with --write"

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "bulk",
               "replace-agent",
               root,
               "old_agent",
               "new_agent",
               "--root",
               root,
               "--write",
               "--yes",
               "--format",
               "json"
             ])

    assert %{
             "mode" => "write",
             "status" => "ok",
             "summary" => %{"changed_workflows" => 2, "changed_shots" => 2},
             "changes" => changes
           } = Jason.decode!(output)

    assert Enum.map(changes, & &1["path"]) == [first_path, second_path]
    assert File.read!(first_path) =~ "new_agent"
    assert File.read!(second_path) =~ "new_agent"
    assert File.read!(other_path) =~ "other_agent"
  end

  test "shell bulk replace-agent reports per-file lint failures" do
    root = tmp_dir!("twelvgaige_cli_bulk_replace_agent_failure")
    workflows_dir = Path.join(root, "workflows")
    agents_dir = Path.join(workflows_dir, "agents")
    workflow_path = Path.join(workflows_dir, "workflow.yaml")

    File.mkdir_p!(agents_dir)
    File.write!(Path.join(agents_dir, "old_agent.yaml"), agent_yaml("old_agent", ["kubectl_get"]))
    File.write!(Path.join(agents_dir, "new_agent.yaml"), agent_yaml("new_agent", ["http_get"]))
    File.write!(workflow_path, bulk_replace_agent_workflow_yaml("bulk_failure", "old_agent"))

    assert {:ok, output, 1} =
             Main.run([
               "shell",
               "bulk",
               "replace-agent",
               root,
               "old_agent",
               "new_agent",
               "--root",
               root,
               "--format",
               "json"
             ])

    assert %{
             "status" => "failed",
             "summary" => %{"changed_workflows" => 0, "error_count" => 1},
             "errors" => [%{"path" => ^workflow_path, "error" => %{"message" => message}}]
           } = Jason.decode!(output)

    assert message =~ "contextual lint"
    assert File.read!(workflow_path) =~ "old_agent"
  end

  test "shell bulk replace-tool plans and writes matching workflow files" do
    root = tmp_dir!("twelvgaige_cli_bulk_replace_tool")
    workflows_dir = Path.join(root, "workflows")
    agents_dir = Path.join(workflows_dir, "agents")
    first_path = Path.join(workflows_dir, "first.yaml")
    second_path = Path.join(workflows_dir, "second.yaml")
    other_path = Path.join(workflows_dir, "other.yaml")

    File.mkdir_p!(agents_dir)

    File.write!(
      Path.join(agents_dir, "mock_agent.yaml"),
      agent_yaml("mock_agent", ["kubectl_get", "http_get"])
    )

    File.write!(first_path, bulk_replace_tool_workflow_yaml("first_tool", "kubectl_get"))
    File.write!(second_path, bulk_replace_tool_workflow_yaml("second_tool", "kubectl_get"))
    File.write!(other_path, bulk_replace_tool_workflow_yaml("other_tool", "git_status"))

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "bulk",
               "replace-tool",
               root,
               "kubectl_get",
               "http_get",
               "--root",
               root
             ])

    assert output =~ "Shell bulk replace-tool:"
    assert output =~ "Mode: DRY_RUN"
    assert output =~ "Changed workflows: 2"
    assert output =~ "wrote=false"
    assert File.read!(first_path) =~ "kubectl_get"

    assert {:ok, output, 4} =
             Main.run([
               "shell",
               "bulk",
               "replace-tool",
               root,
               "kubectl_get",
               "http_get",
               "--root",
               root,
               "--write"
             ])

    assert output =~ "requires --yes with --write"

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "bulk",
               "replace-tool",
               root,
               "kubectl_get",
               "http_get",
               "--root",
               root,
               "--write",
               "--yes",
               "--format",
               "json"
             ])

    assert %{
             "operation" => "replace_tool",
             "mode" => "write",
             "status" => "ok",
             "summary" => %{"changed_workflows" => 2, "changed_shots" => 2},
             "changes" => changes
           } = Jason.decode!(output)

    assert Enum.map(changes, & &1["path"]) == [first_path, second_path]
    assert File.read!(first_path) =~ "http_get"
    refute File.read!(first_path) =~ "kubectl_get"
    assert File.read!(second_path) =~ "http_get"
    assert File.read!(other_path) =~ "git_status"
  end

  test "shell bulk replace-tool reports per-file lint failures" do
    root = tmp_dir!("twelvgaige_cli_bulk_replace_tool_failure")
    workflows_dir = Path.join(root, "workflows")
    agents_dir = Path.join(workflows_dir, "agents")
    workflow_path = Path.join(workflows_dir, "workflow.yaml")

    File.mkdir_p!(agents_dir)

    File.write!(
      Path.join(agents_dir, "mock_agent.yaml"),
      agent_yaml("mock_agent", ["kubectl_get"])
    )

    File.write!(workflow_path, bulk_replace_tool_workflow_yaml("tool_failure", "kubectl_get"))

    assert {:ok, output, 1} =
             Main.run([
               "shell",
               "bulk",
               "replace-tool",
               root,
               "kubectl_get",
               "http_get",
               "--root",
               root,
               "--format",
               "json"
             ])

    assert %{
             "operation" => "replace_tool",
             "status" => "failed",
             "summary" => %{"changed_workflows" => 0, "error_count" => 1},
             "errors" => [%{"path" => ^workflow_path, "error" => %{"message" => message}}]
           } = Jason.decode!(output)

    assert message =~ "contextual lint"
    assert File.read!(workflow_path) =~ "kubectl_get"
  end

  test "shell reload, list, and show use the supervised shell cache" do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige_cli_shells_#{System.unique_integer([:positive])}")

    workflow_path = Path.join(root, "workflows/inspect.yaml")
    agent_path = Path.join(root, "agents/inspector.yaml")

    File.mkdir_p!(Path.dirname(workflow_path))
    File.mkdir_p!(Path.dirname(agent_path))
    File.write!(workflow_path, workflow_yaml())
    File.write!(agent_path, agent_yaml())

    on_exit(fn ->
      Twelvgaige.reload_shells(paths: [])
      File.rm_rf(root)
    end)

    assert {:ok, output, 0} = Main.run(["shell", "reload", root, "--format", "json"])

    assert %{"workflows" => ["cli_cached_workflow"], "agents" => ["cli_cached_agent"]} =
             Jason.decode!(output)

    assert {:ok, output, 0} = Main.run(["shell", "list", "--format", "json"])

    assert [
             %{"kind" => "agent", "id" => "cli_cached_agent"},
             %{"kind" => "workflow", "id" => "cli_cached_workflow"}
           ] = Jason.decode!(output)

    assert {:ok, output, 0} = Main.run(["shell", "show", "cli_cached_workflow"])
    assert output =~ "Workflow shell: cli_cached_workflow 1.0.0"
    assert output =~ "inspect [slug]"

    assert {:ok, output, 0} =
             Main.run([
               "shell",
               "show",
               "cli_cached_agent",
               "--kind",
               "agent",
               "--format",
               "json"
             ])

    assert %{"kind" => "agent", "id" => "cli_cached_agent", "model" => "mock-model"} =
             Jason.decode!(output)
  end

  test "round run accepts inline JSON input" do
    assert {:ok, output, 0} =
             Main.run(["round", "run", @workflow_path, "--input", ~s({"cluster":"dev"})])

    assert output =~ "Status: complete"
    assert output =~ "first [complete]"
    assert output =~ "second [complete]"
  end

  test "round run accepts JSON workflow and agent shells" do
    assert {:ok, output, 0} =
             Main.run([
               "round",
               "run",
               "test/fixtures/shells/simple_workflow.json",
               "--agent-shell",
               "test/fixtures/shells/mock_agent.json",
               "--input",
               ~s({"cluster":"dev"})
             ])

    assert output =~ "Status: complete"
    assert output =~ "first [complete]"
    assert output =~ "second [complete]"
  end

  test "round run accepts TOML workflow and agent shells" do
    assert {:ok, output, 0} =
             Main.run([
               "round",
               "run",
               "test/fixtures/shells/simple_workflow.toml",
               "--agent-shell",
               "test/fixtures/shells/mock_agent.toml",
               "--input",
               ~s({"cluster":"dev"})
             ])

    assert output =~ "Status: complete"
    assert output =~ "first [complete]"
    assert output =~ "second [complete]"
  end

  test "round run can emit JSON" do
    assert {:ok, output, 0} =
             Main.run([
               "round",
               "run",
               @workflow_path,
               "--input",
               ~s({"cluster":"dev"}),
               "--format",
               "json"
             ])

    decoded = Jason.decode!(output)
    assert decoded["shell_id"] == "simple"
    assert decoded["status"] == "complete"
    assert [%{"status" => "complete"}, %{"status" => "complete"}] = decoded["shots"]
  end

  test "round run can require admission policy before execution" do
    path = write_tmp_shell(lifecycle_workflow_yaml(), ".yaml")

    assert {:ok, output, 7} =
             Main.run(["round", "run", path, "--admission", "approved", "--format", "json"])

    assert %{
             "error" => %{
               "reason" => "policy_denied",
               "details" => %{"policy" => "approved", "findings" => findings}
             }
           } = Jason.decode!(output)

    assert Enum.any?(findings, &(&1["id"] == "lifecycle.approval_required"))
  end

  test "round run accepts an explicit resource profile" do
    assert {:ok, output, 0} =
             Main.run([
               "round",
               "run",
               @workflow_path,
               "--input",
               ~s({"cluster":"dev"}),
               "--profile",
               "minimal",
               "--format",
               "json"
             ])

    decoded = Jason.decode!(output)
    assert decoded["status"] == "complete"
    assert decoded["resource_profile"] == "minimal"
    assert decoded["policy"]["resource_profile"] == "minimal"
  end

  test "round run rejects unsupported resource profiles" do
    assert {:ok, output, 4} =
             Main.run([
               "round",
               "run",
               @workflow_path,
               "--input",
               ~s({"cluster":"dev"}),
               "--profile",
               "desktop"
             ])

    assert output =~ "unsupported resource profile"
  end

  test "round run can submit a daemon-owned detached round" do
    assert {:ok, output, 0} =
             Main.run([
               "round",
               "run",
               @workflow_path,
               "--input",
               ~s({"cluster":"dev"}),
               "--detach",
               "--format",
               "json"
             ])

    decoded = Jason.decode!(output)
    assert "round_" <> _ = round_id = decoded["id"]
    assert decoded["status"] == "queued"

    assert eventually(fn ->
             case Twelvgaige.get_round(round_id) do
               {:ok, snapshot} -> snapshot.status == :complete
               _other -> false
             end
           end)
  end

  test "daemon paths prints default lifecycle paths" do
    dir =
      Path.join(System.tmp_dir!(), "twelvgaige_cli_paths_#{System.unique_integer([:positive])}")

    assert {:ok, output, 0} =
             Main.run([
               "daemon",
               "paths",
               "--runtime-dir",
               dir,
               "--transport",
               "tcp",
               "--format",
               "json"
             ])

    decoded = Jason.decode!(output)
    assert decoded["runtime_dir"] == dir
    assert decoded["endpoint_path"] == Path.join(dir, "breech.endpoint.json")
    assert decoded["lock_path"] == Path.join(dir, "breech.lock")
    assert decoded["transport"] == "tcp"
  end

  test "daemon paths accepts named pipe transport" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_cli_paths_npipe_#{System.unique_integer([:positive])}"
      )

    assert {:ok, output, 0} =
             Main.run([
               "daemon",
               "paths",
               "--runtime-dir",
               dir,
               "--transport",
               "npipe",
               "--format",
               "json"
             ])

    decoded = Jason.decode!(output)
    assert decoded["transport"] == "npipe"
    assert decoded["socket_path"] == nil
    assert decoded["pipe_path"] =~ ~S(\\.\pipe\twelvgaige-)
  end

  test "daemon stop requests endpoint-published daemon shutdown" do
    dir =
      Path.join(System.tmp_dir!(), "twelvgaige_cli_stop_#{System.unique_integer([:positive])}")

    endpoint_path = Path.join(dir, "breech.endpoint.json")
    lock_path = Path.join(dir, "breech.lock")
    on_exit(fn -> File.rm_rf(dir) end)

    server =
      start_supervised!(%{
        id: {:cli_stop_server, endpoint_path},
        start:
          {Twelvgaige.Breech.IPC.Server, :start_link,
           [[port: 0, endpoint_path: endpoint_path, lock_path: lock_path]]},
        restart: :temporary
      })

    ref = Process.monitor(server)

    assert {:ok, output, 0} =
             Main.run(["daemon", "stop", "--endpoint", endpoint_path, "--format", "json"])

    assert %{"status" => "stopping"} = Jason.decode!(output)
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}, 1_000
  end

  test "round show displays a daemon-owned round" do
    assert {:ok, round_id} = Twelvgaige.run_round(@workflow_path, %{"cluster" => "dev"})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, output, 0} = Main.run(["round", "show", round_id, "--format", "json"])

    decoded = Jason.decode!(output)
    assert decoded["id"] == round_id
    assert decoded["status"] == "complete"
  end

  test "round show returns not-found exit code for missing rounds" do
    assert {:ok, output, 6} = Main.run(["round", "show", "round_missing", "--format", "json"])

    assert %{"error" => %{"reason" => "round_not_found"}} = Jason.decode!(output)
  end

  test "round watch replays daemon-owned round events as ndjson" do
    assert {:ok, round_id} = Twelvgaige.run_round(@workflow_path, %{"cluster" => "dev"})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, output, 0} =
             Main.run(["round", "watch", round_id, "--format", "ndjson"])

    events = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    event = List.last(events)

    assert event["round_id"] == round_id
    assert Enum.map(events, & &1["seq"]) == Enum.to_list(1..length(events))
    assert event["event_type"] == "round_completed"
    assert event["payload"]["status"] == "complete"
  end

  test "round audit displays daemon-owned audit events" do
    assert {:ok, round_id} = Twelvgaige.run_round(@workflow_path, %{"cluster" => "dev"})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, output, 0} =
             Main.run(["round", "audit", round_id, "--format", "json"])

    decoded = Jason.decode!(output)
    event_types = Enum.map(decoded, & &1["event_type"])

    assert Enum.all?(decoded, &(&1["round_id"] == round_id))
    assert "shot_attempt_started" in event_types
    assert "shot_attempt_finished" in event_types
    assert "round_state_transition" in event_types
    assert Enum.map(decoded, & &1["seq"]) == Enum.to_list(1..length(decoded))
  end

  test "round audit can emit a verifiable checkpoint" do
    assert {:ok, round_id} = Twelvgaige.run_round(@workflow_path, %{"cluster" => "dev"})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, output, 0} =
             Main.run(["round", "audit", round_id, "--format", "checkpoint"])

    checkpoint = Jason.decode!(output)

    assert checkpoint["kind"] == "twelvgaige.audit.checkpoint"
    assert checkpoint["round_id"] == round_id
    assert checkpoint["event_count"] > 0
    assert :ok = Twelvgaige.Audit.Checkpoint.verify(checkpoint)
  end

  test "audit verify accepts a saved checkpoint file" do
    assert {:ok, round_id} = Twelvgaige.run_round(@workflow_path, %{"cluster" => "dev"})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, checkpoint_output, 0} =
             Main.run(["round", "audit", round_id, "--format", "checkpoint"])

    path = Path.join(tmp_dir!("twelvgaige_cli_audit_verify"), "checkpoint.json")
    File.write!(path, checkpoint_output)

    assert {:ok, output, 0} = Main.run(["audit", "verify", path])

    assert output =~ "valid audit checkpoint"
    assert output =~ "round=#{round_id}"

    assert {:ok, output, 0} = Main.run(["audit", "verify", path, "--format", "json"])

    assert %{
             "status" => "ok",
             "valid" => true,
             "round_id" => ^round_id,
             "algorithm" => "sha256-chain-v1"
           } = Jason.decode!(output)
  end

  test "round audit can emit and verify a signed checkpoint" do
    env = "TWELVGAIGE_CLI_AUDIT_HMAC_#{System.unique_integer([:positive])}"
    System.put_env(env, "base64:" <> Base.encode64("audit-hmac-secret"))
    on_exit(fn -> System.delete_env(env) end)

    assert {:ok, round_id} = Twelvgaige.run_round(@workflow_path, %{"cluster" => "dev"})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, checkpoint_output, 0} =
             Main.run([
               "round",
               "audit",
               round_id,
               "--format",
               "checkpoint",
               "--sign-hmac-env",
               env
             ])

    path = Path.join(tmp_dir!("twelvgaige_cli_audit_verify_signed"), "checkpoint.json")
    File.write!(path, checkpoint_output)

    checkpoint = Jason.decode!(checkpoint_output)
    assert checkpoint["signature"]["algorithm"] == "hmac-sha256-v1"
    assert checkpoint["signature"]["key_ref"] == env

    assert {:ok, output, 0} = Main.run(["audit", "verify", path, "--hmac-env", env])
    assert output =~ "signature=hmac-sha256-v1"

    assert {:ok, output, 0} =
             Main.run(["audit", "verify", path, "--hmac-env", env, "--format", "json"])

    assert %{
             "status" => "ok",
             "valid" => true,
             "signature" => %{"algorithm" => "hmac-sha256-v1", "key_ref" => ^env}
           } = Jason.decode!(output)

    System.put_env(env, "wrong")

    assert {:ok, output, 1} = Main.run(["audit", "verify", path, "--hmac-env", env])
    assert output == "invalid audit checkpoint: hmac_signature_mismatch\n"
  end

  test "audit verify reports invalid checkpoints" do
    checkpoint =
      Twelvgaige.Audit.Checkpoint.export([
        %{seq: 1, event_type: :round_created, round_id: "round_1", payload: %{status: :queued}}
      ])

    mutated = put_in(checkpoint, ["events", Access.at(0), "payload", "status"], "complete")
    path = Path.join(tmp_dir!("twelvgaige_cli_audit_verify_invalid"), "checkpoint.json")
    File.write!(path, Jason.encode!(mutated))

    assert {:ok, output, 1} = Main.run(["audit", "verify", path])

    assert output == "invalid audit checkpoint: event_hash_mismatch seq=1\n"

    assert {:ok, output, 1} = Main.run(["audit", "verify", path, "--format", "json"])

    assert %{
             "status" => "failed",
             "valid" => false,
             "reason" => "event_hash_mismatch",
             "details" => %{"seq" => 1}
           } = Jason.decode!(output)
  end

  test "round watch can follow for the next daemon-owned round event" do
    assert {:ok, round_id} =
             Twelvgaige.run_round("test/fixtures/shells/safety_workflow.yaml", %{
               "cluster" => "dev"
             })

    assert eventually(fn ->
             match?({:ok, %{status: :awaiting_safety}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, awaiting_events} = Twelvgaige.list_round_events(round_id)
    awaiting_event = List.last(awaiting_events)

    watcher =
      Task.async(fn ->
        Main.run([
          "round",
          "watch",
          round_id,
          "--format",
          "ndjson",
          "--after-seq",
          Integer.to_string(awaiting_event.seq),
          "--follow",
          "--timeout-ms",
          "1000"
        ])
      end)

    Process.sleep(10)

    assert :ok =
             Twelvgaige.approve_safety(round_id, "approval",
               reason: "reviewed",
               actor: "human:test"
             )

    assert {:ok, output, 0} = Task.await(watcher)
    assert [event] = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    assert event["round_id"] == round_id
    assert event["event_type"] == "safety_approved"
  end

  test "round watch can follow until a daemon-owned round reaches terminal state" do
    assert {:ok, round_id} =
             Twelvgaige.run_round("test/fixtures/shells/safety_workflow.yaml", %{
               "cluster" => "dev"
             })

    assert eventually(fn ->
             match?({:ok, %{status: :awaiting_safety}}, Twelvgaige.get_round(round_id))
           end)

    watcher =
      Task.async(fn ->
        Main.run([
          "round",
          "watch",
          round_id,
          "--format",
          "ndjson",
          "--follow",
          "--until-terminal",
          "--timeout-ms",
          "1000"
        ])
      end)

    Process.sleep(10)

    assert :ok =
             Twelvgaige.approve_safety(round_id, "approval",
               reason: "reviewed",
               actor: "human:test"
             )

    assert {:ok, output, 0} = Task.await(watcher)

    events = output |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert Enum.all?(events, &(&1["round_id"] == round_id))

    assert Enum.map(events, & &1["event_type"]) == [
             "round_started",
             "safety_awaiting",
             "safety_approved",
             "shot_started",
             "shot_completed",
             "round_completed"
           ]
  end

  test "round list includes daemon-owned rounds" do
    assert {:ok, round_id} = Twelvgaige.run_round(@workflow_path, %{"cluster" => "dev"})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, output, 0} = Main.run(["round", "list", "--format", "json"])

    decoded = Jason.decode!(output)
    assert Enum.any?(decoded, &(&1["id"] == round_id))
  end

  test "round approve resumes a daemon-owned safety round" do
    assert {:ok, round_id} =
             Twelvgaige.run_round("test/fixtures/shells/safety_workflow.yaml", %{
               "cluster" => "dev"
             })

    assert eventually(fn ->
             match?({:ok, %{status: :awaiting_safety}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, output, 0} =
             Main.run([
               "round",
               "approve",
               round_id,
               "--shot",
               "approval",
               "--reason",
               "reviewed",
               "--format",
               "json"
             ])

    assert %{"status" => "accepted", "decision" => "approve"} = Jason.decode!(output)

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)
  end

  test "round approve returns policy-denied exit code for invalid decisions" do
    assert {:ok, round_id} = Twelvgaige.run_round(@workflow_path, %{"cluster" => "dev"})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, output, 7} =
             Main.run([
               "round",
               "approve",
               round_id,
               "--shot",
               "approval",
               "--format",
               "json"
             ])

    assert %{"error" => %{"reason" => "policy_denied"}} = Jason.decode!(output)
  end

  test "round reject halts a daemon-owned safety round" do
    assert {:ok, round_id} =
             Twelvgaige.run_round("test/fixtures/shells/safety_workflow.yaml", %{
               "cluster" => "dev"
             })

    assert eventually(fn ->
             match?({:ok, %{status: :awaiting_safety}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, output, 0} =
             Main.run([
               "round",
               "reject",
               round_id,
               "--shot",
               "approval",
               "--reason",
               "too risky"
             ])

    assert output =~ "Safety reject accepted"
    assert eventually(fn -> match?({:ok, %{status: :halted}}, Twelvgaige.get_round(round_id)) end)
  end

  test "round cancel cancels a daemon-owned safety round" do
    assert {:ok, round_id} =
             Twelvgaige.run_round("test/fixtures/shells/safety_workflow.yaml", %{
               "cluster" => "dev"
             })

    assert eventually(fn ->
             match?({:ok, %{status: :awaiting_safety}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, output, 0} =
             Main.run([
               "round",
               "cancel",
               round_id,
               "--reason",
               "operator stop",
               "--format",
               "json"
             ])

    assert %{"status" => "accepted", "decision" => "cancel"} = Jason.decode!(output)
    assert {:ok, snapshot} = Twelvgaige.get_round(round_id)
    assert snapshot.status == :cancelled
  end

  test "round run can approve foreground safety shots" do
    assert {:ok, output, 0} =
             Main.run([
               "round",
               "run",
               "test/fixtures/shells/safety_workflow.yaml",
               "--input",
               ~s({"cluster":"dev"}),
               "--approve-safety"
             ])

    assert output =~ "Status: complete"
    assert output =~ "approval [complete]"
    assert output =~ "after [complete]"
  end

  test "round run pauses at safety without an approval option" do
    assert {:ok, output, 1} =
             Main.run([
               "round",
               "run",
               "test/fixtures/shells/safety_workflow.yaml",
               "--input",
               ~s({"cluster":"dev"})
             ])

    assert output =~ "Status: awaiting_safety"
    assert output =~ "approval [awaiting_safety]"
    assert output =~ "after [pending]"
  end

  test "round run defaults input to an empty object" do
    assert {:ok, output, 0} = Main.run(["round", "run", @workflow_path])

    assert output =~ "Status: complete"
    assert output =~ "first [complete]"
    assert output =~ "second [complete]"
  end

  test "round run returns not-found exit code for missing shell files" do
    path = "test/fixtures/shells/missing_workflow.yaml"

    assert {:ok, output, 6} =
             Main.run([
               "round",
               "run",
               path,
               "--input",
               ~s({"cluster":"dev"}),
               "--format",
               "json"
             ])

    assert %{"error" => %{"reason" => "invalid_shell"}} = Jason.decode!(output)
  end

  defp eventually(fun), do: eventually(fun, 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts_left) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts_left - 1)
    end
  end

  defp write_tmp_shell(contents, extension) do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-cli-shell-#{System.unique_integer([:positive])}#{extension}"
      )

    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write_workflow_with_agents!(workflow_contents, agent_contents) do
    root = tmp_dir!("twelvgaige-cli-replace-agent")
    workflow_path = Path.join(root, "workflow.yaml")
    agents_dir = Path.join(root, "agents")

    File.mkdir_p!(agents_dir)
    File.write!(workflow_path, workflow_contents)

    Enum.each(agent_contents, fn contents ->
      id = agent_id_from_yaml!(contents)
      File.write!(Path.join(agents_dir, "#{id}.yaml"), contents)
    end)

    workflow_path
  end

  defp agent_id_from_yaml!(contents) do
    case Regex.run(~r/^id:\s*([A-Za-z0-9_-]+)\s*$/m, contents) do
      [_line, id] -> id
      nil -> raise "agent fixture is missing id"
    end
  end

  defp tmp_dir!(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp workflow_yaml do
    """
    kind: workflow
    id: cli_cached_workflow
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: cli_cached_agent
        prompt: inspect
    """
  end

  defp rename_workflow_yaml do
    """
    kind: workflow
    id: rename_demo
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: mock_agent
        prompt: gather
      - id: analyze
        kind: slug
        agent: mock_agent
        depends_on: [gather]
        prompt: analyze
    """
  end

  defp rename_condition_workflow_yaml do
    """
    kind: workflow
    id: rename_conditions
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: mock_agent
        prompt: gather
      - id: analyze
        kind: slug
        agent: mock_agent
        condition: steps.gather.status == "complete"
        prompt: analyze
    """
  end

  defp remove_cascade_workflow_yaml do
    """
    kind: workflow
    id: remove_cascade
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: mock_agent
        prompt: gather
      - id: analyze
        kind: slug
        agent: mock_agent
        depends_on: [gather]
        prompt: analyze
      - id: verify
        kind: slug
        agent: mock_agent
        depends_on: [analyze]
        prompt: verify
      - id: notify
        kind: slug
        agent: mock_agent
        prompt: notify
    """
  end

  defp replace_agent_workflow_yaml do
    """
    kind: workflow
    id: replace_agent_cli
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: old_agent
        tools: [kubectl_get]
        prompt: gather
      - id: analyze
        kind: slug
        agent: old_agent
        depends_on: [gather]
        tools: [kubectl_get]
        prompt: analyze
    """
  end

  defp replace_tool_workflow_yaml do
    """
    kind: workflow
    id: replace_tool_cli
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: mock_agent
        tools: [kubectl_get]
        prompt: gather
      - id: analyze
        kind: slug
        agent: mock_agent
        depends_on: [gather]
        tools: [kubectl_get]
        prompt: analyze
    """
  end

  defp split_workflow_yaml do
    """
    kind: workflow
    id: split_cli
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: mock_agent
        prompt: gather
      - id: analyze
        kind: slug
        agent: mock_agent
        depends_on: [gather]
        tools: [kubectl_get]
        prompt: analyze
      - id: verify
        kind: slug
        agent: mock_agent
        depends_on: [analyze]
        condition: shots.analyze.output.summary == "ok"
        prompt: verify
    """
  end

  defp merge_workflow_yaml do
    """
    kind: workflow
    id: merge_cli
    version: 1.0.0
    shots:
      - id: gather
        kind: slug
        agent: mock_agent
        prompt: gather
      - id: analyze
        kind: slug
        agent: mock_agent
        depends_on: [gather]
        tools: [kubectl_get]
        prompt: analyze
      - id: verify
        kind: slug
        agent: mock_agent
        depends_on: [analyze]
        tools: [http_get]
        prompt: verify
      - id: notify
        kind: slug
        agent: mock_agent
        depends_on: [verify]
        condition: shots.verify.output.summary == "ok"
        prompt: notify
    """
  end

  defp agent_yaml(agent_id, allowed_tools) do
    allowed =
      allowed_tools
      |> Enum.map(&"    - #{&1}")
      |> Enum.join("\n")

    """
    kind: agent
    id: #{agent_id}
    name: #{agent_id}
    version: 1.0.0
    provider: mock
    model: mock-model
    system_prompt: Run #{agent_id}.
    tools:
      allowed:
    #{allowed}
    """
  end

  defp messy_fmt_workflow_yaml do
    """
    version: 1.0.0
    shots:
      - timeout: 1m
        agent: agent
        kind: slug
        id: inspect
    kind: workflow
    id: fmt_demo
    """
  end

  defp lifecycle_workflow_yaml do
    """
    kind: workflow
    id: lifecycle_cli
    version: 1.0.0
    metadata:
      owner: platform
      lifecycle: draft
    shots:
      - id: inspect
        kind: slug
        agent: agent
        timeout: 1m
        output_schema:
          type: object
          required: [summary]
          properties:
            summary:
              type: string
    """
  end

  defp no_owner_lifecycle_workflow_yaml do
    """
    kind: workflow
    id: lifecycle_no_owner_cli
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: agent
    """
  end

  defp workflow_with_template_source_yaml(template) do
    """
    kind: workflow
    id: library_cli_drift
    version: 1.0.0
    shots:
      - id: review
        kind: slug
        agent: reviewer
        timeout: 1m
        output_schema:
          type: object
          required: [summary]
          properties:
            summary:
              type: string
        metadata:
          generated_by:
            tool: twelvgaige
            command: shot add --template team/team.review
            version: 0.0.1
            source:
              kind: template
              namespace: #{template.namespace}
              id: #{template.id}
              version: #{template.version}
              digest: #{template.digest}
    """
  end

  defp local_shot_template_yaml do
    """
    kind: shot_template
    namespace: team
    id: team.review
    version: 1.0.0
    description: Team review shot
    shot:
      kind: slug
      agent: reviewer
      prompt: Review the change.
    """
  end

  defp local_scaffold_yaml do
    """
    kind: scaffold
    namespace: team
    id: team.review
    version: 1.0.0
    description: Team review workflow
    workflow:
      shots:
        - id: review
          kind: slug
          agent: reviewer
          prompt: Review input.
          output_schema:
            type: object
            required: [summary]
            properties:
              summary:
                type: string
    agents:
      - kind: agent
        id: reviewer
        version: 1.0.0
        provider: mock
        model: mock-model
        system_prompt: Review agent
    """
  end

  defp cli_patch_artifact(path, before, after_contents) do
    %{
      "kind" => "twelvgaige.patch.v1",
      "id" => "cli_patch_test",
      "created_at" => "2026-05-04T00:00:00Z",
      "files" => [
        %{
          "path" => path,
          "kind" => "workflow",
          "operation" => "replace",
          "before_digest" => sha256(before),
          "after_digest" => sha256(after_contents),
          "before_size_bytes" => byte_size(before),
          "after_size_bytes" => byte_size(after_contents),
          "content" => after_contents
        }
      ],
      "validations" => [
        %{"command" => "shell validate", "path" => path},
        %{"command" => "shell lint", "path" => path, "strict" => true}
      ]
    }
  end

  defp cli_patch_approval(patch_digest) do
    %{
      "kind" => "twelvgaige.patch_approval.v1",
      "id" => "cli_patch_approval",
      "patch_digest" => patch_digest,
      "approved_by" => "human:cli",
      "approved_at" => "2026-05-04T00:00:00Z",
      "scope" => "repo",
      "expires_at" => "2099-01-01T00:00:00Z"
    }
  end

  defp updated_patch_workflow_yaml do
    String.replace(workflow_yaml(), "prompt: inspect", "prompt: inspect updated")
  end

  defp sha256(contents) do
    "sha256:" <> (:crypto.hash(:sha256, contents) |> Base.encode16(case: :lower))
  end

  defp agent_yaml do
    """
    kind: agent
    id: cli_cached_agent
    version: 1.0.0
    provider: mock
    model: mock-model
    system_prompt: CLI cached agent
    """
  end

  defp inventory_workflow_yaml do
    """
    kind: workflow
    id: deploy_check
    version: 1.0.0
    metadata:
      owner: platform
      lifecycle: approved
    shots:
      - id: inspect
        kind: slug
        agent: operator
        tools: [kubectl_get]
      - id: approval
        kind: safety
        depends_on: [inspect]
      - id: apply
        kind: slug
        agent: operator
        depends_on: [approval]
        tools: [kubectl_apply]
        metadata:
          generated_by:
            tool: twelvgaige
            command: shot add
            version: 0.0.1
            source:
              kind: template
              id: deploy.apply
              version: 1.0.0
    """
  end

  defp bulk_replace_agent_workflow_yaml(id, agent_id) do
    """
    kind: workflow
    id: #{id}
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: #{agent_id}
        tools: [kubectl_get]
        prompt: inspect
    """
  end

  defp bulk_replace_tool_workflow_yaml(id, tool) do
    """
    kind: workflow
    id: #{id}
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: mock_agent
        tools: [#{tool}]
        prompt: inspect
    """
  end

  defp inventory_agent_yaml do
    """
    kind: agent
    id: operator
    version: 1.0.0
    provider: mock
    model: mock-model
    system_prompt: Operate carefully.
    """
  end
end
