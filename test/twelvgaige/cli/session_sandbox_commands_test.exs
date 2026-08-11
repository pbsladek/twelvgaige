defmodule Twelvgaige.CLI.SessionSandboxCommandsTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.CLI.Commands.{SandboxSetup, SessionPlan, SessionStart}

  test "session plan writes an exact owner-only handoff that session start consumes" do
    root = Path.dirname(endpoint_file())
    output_path = Path.join(root, "reviewed-plan.json")
    endpoint = endpoint_file()
    parent = self()

    profile_resolver = fn _name, _opts ->
      {:ok, %{name: nil, values: %{}, provenance: %{}}}
    end

    planner = fn request, _opts ->
      send(parent, {:planned_request, request})
      {:ok, planned_result(request)}
    end

    task = "private task body must not appear in routine output"

    assert {:ok, plan_output, 0} =
             SessionPlan.run(
               [
                 "--task",
                 task,
                 "--auth-profile",
                 "codex-service",
                 "--request-id",
                 "req-reviewed-plan",
                 "--output",
                 output_path
               ],
               profile_resolver: profile_resolver,
               plan_fun: planner
             )

    refute plan_output =~ task
    assert plan_output =~ "Plan digest: sha256:"
    assert plan_output =~ "twelvgaige session start --plan"
    assert_receive {:planned_request, planned_request}

    assert {:ok, stat} = File.lstat(output_path)
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    original_artifact = File.read!(output_path)

    assert {:ok, exists_output, 4} =
             SessionPlan.run(
               [
                 "--task",
                 task,
                 "--auth-profile",
                 "codex-service",
                 "--request-id",
                 "req-reviewed-plan",
                 "--output",
                 output_path
               ],
               profile_resolver: profile_resolver,
               plan_fun: planner
             )

    assert exists_output =~ "destination already exists"
    refute exists_output =~ task
    assert File.read!(output_path) == original_artifact

    client = fn _address, request, _opts ->
      send(parent, {:started_saved_plan, request})

      {:ok,
       %{
         "plan_id" => "mgr_saved_cli",
         "child_id" => "child_saved_cli",
         "session_id" => "sess_saved_cli",
         "request_id" => request["request_id"],
         "status" => "submitted",
         "sandbox" => request["sandbox"],
         "repository" => request["repository"]
       }}
    end

    assert {:ok, _start_output, 0} =
             SessionStart.run(["--plan", output_path, "--endpoint", endpoint], client: client)

    assert_receive {:started_saved_plan, started_request}
    assert started_request["saved_plan"]["plan_digest"] =~ "sha256:"
    assert Map.delete(started_request, "saved_plan") == planned_request
  end

  test "JSON session plan exposes the digest and context without the task body" do
    profile_resolver = fn _name, _opts ->
      {:ok, %{name: "reviewed", values: %{}, provenance: %{}}}
    end

    planner = fn request, _opts ->
      {:ok, planned_result(request) |> Map.put(:profile, request["profile"])}
    end

    task = "private JSON plan task"

    assert {:ok, output, 0} =
             SessionPlan.run(
               [
                 "--task",
                 task,
                 "--auth-profile",
                 "codex-service",
                 "--request-id",
                 "req-json-plan",
                 "--profile",
                 "reviewed",
                 "--format",
                 "json"
               ],
               profile_resolver: profile_resolver,
               plan_fun: planner
             )

    decoded = Jason.decode!(output)
    refute Map.has_key?(decoded, "objective")
    refute output =~ task
    assert decoded["request_id"] == "req-json-plan"
    assert decoded["profile"] == "reviewed"
    assert decoded["plan_digest"] =~ "sha256:"
    assert is_nil(decoded["saved_plan_path"])
    assert is_nil(decoded["start_command"])
  end

  test "saved-plan start rejects request overrides before daemon discovery" do
    plan =
      planned_saved_plan(%{
        "request_id" => "req-no-overrides",
        "runtime" => "codex",
        "repository" => Path.expand("."),
        "base_ref" => "HEAD",
        "task" => "private original task",
        "auth_profile" => "codex-service",
        "sandbox" => "podman",
        "network" => "broker-only",
        "allow_unrestricted_network" => false,
        "allowed_paths" => [],
        "source_mode" => "committed",
        "include_untracked" => false,
        "include_ignored" => false,
        "write" => true,
        "timeout_ms" => 2_700_000,
        "profile" => nil,
        "budget" => %{
          "tokens" => 80_000,
          "cost_micros" => 25_000_000,
          "time_ms" => 2_700_000,
          "tool_calls" => 1_000
        },
        "provenance" => %{}
      })

    assert {:ok, output, 4} =
             SessionStart.run(
               ["--plan", "ignored.json", "--sandbox", "apple-container"],
               saved_plan_loader: fn "ignored.json" -> {:ok, plan} end
             )

    assert output =~ "cannot be combined with request overrides"
    refute output =~ "private original task"
  end

  test "session start normalizes the governed request and formats stable identities" do
    endpoint = endpoint_file()
    parent = self()

    client = fn address, request, opts ->
      send(parent, {:start_request, address, request, opts})

      {:ok,
       %{
         "plan_id" => "mgr_cli",
         "child_id" => "child_cli",
         "session_id" => "sess_cli",
         "status" => "submitted",
         "sandbox" => "apple-container",
         "repository" => request["repository"]
       }}
    end

    assert {:ok, output, 0} =
             SessionStart.run(
               [
                 "--task",
                 "Fix the tests",
                 "--auth-profile",
                 "codex-service",
                 "--repo",
                 ".",
                 "--base-ref",
                 "main",
                 "--sandbox",
                 "apple-container",
                 "--unrestricted-network",
                 "--allow-path",
                 "lib",
                 "--allow-path",
                 "test",
                 "--timeout",
                 "10m",
                 "--budget-tokens",
                 "12000",
                 "--budget-cost-micros",
                 "900000",
                 "--budget-tool-calls",
                 "120",
                 "--endpoint",
                 endpoint
               ],
               client: client
             )

    assert output =~ "Session accepted: sess_cli"
    assert output =~ "Sandbox: apple-container"

    assert_receive {:start_request, {:tcp, {127, 0, 0, 1}, 4321}, request, client_opts}
    assert request["runtime"] == "codex"
    assert is_binary(request["request_id"])
    assert client_opts[:request_id] == request["request_id"]
    assert request["task"] == "Fix the tests"
    assert request["base_ref"] == "main"
    assert request["network"] == "unrestricted"
    assert request["allow_unrestricted_network"]
    assert request["allowed_paths"] == ["lib", "test"]
    assert request["timeout_ms"] == 600_000
    assert request["budget"]["tokens"] == 12_000
    assert request["budget"]["cost_micros"] == 900_000
    assert request["budget"]["tool_calls"] == 120
    assert client_opts[:token] == "control-token"
  end

  test "session start forwards an explicit idempotency key in the body and IPC envelope" do
    endpoint = endpoint_file()
    parent = self()

    client = fn _address, request, opts ->
      send(parent, {:idempotent_start, request, opts})

      {:ok,
       %{
         "request_id" => request["request_id"],
         "plan_id" => "mgr_idempotent",
         "child_id" => "child_idempotent",
         "session_id" => "sess_idempotent",
         "status" => "submitted",
         "replayed" => false,
         "sandbox" => request["sandbox"],
         "repository" => request["repository"]
       }}
    end

    assert {:ok, output, 0} =
             SessionStart.run(
               [
                 "--task",
                 "Fix the retry boundary",
                 "--auth-profile",
                 "codex-service",
                 "--request-id",
                 "req-user-selected",
                 "--endpoint",
                 endpoint
               ],
               client: client
             )

    assert output =~ "Request: req-user-selected"
    assert output =~ "Replay: false"

    assert_receive {:idempotent_start, request, opts}
    assert request["request_id"] == "req-user-selected"
    assert opts[:request_id] == "req-user-selected"
  end

  test "session start rejects incomplete and invalid authority before daemon discovery" do
    assert {:ok, output, code} = SessionStart.run(["--task", "Fix it"])
    assert code != 0
    assert output =~ "session_auth_profile_required"

    assert {:ok, output, code} =
             SessionStart.run([
               "--task",
               "Fix it",
               "--auth-profile",
               "service",
               "--timeout",
               "eventually"
             ])

    assert code != 0
    assert output =~ "session_timeout_invalid"
  end

  test "session start reads YAML and lets explicit CLI authority override file values" do
    endpoint = endpoint_file()
    task_file = task_file("task.yaml", structured_task_yaml())
    parent = self()

    client = fn _address, request, _opts ->
      send(parent, {:file_request, request})

      {:ok,
       %{
         "plan_id" => "mgr_file",
         "child_id" => "child_file",
         "session_id" => "sess_file",
         "status" => "submitted",
         "sandbox" => request["sandbox"],
         "repository" => request["repository"]
       }}
    end

    assert {:ok, _output, 0} =
             SessionStart.run(
               [
                 "--task-file",
                 task_file,
                 "--task",
                 "CLI objective wins.",
                 "--sandbox",
                 "podman",
                 "--allow-path",
                 "apps/core",
                 "--budget-tokens",
                 "7000",
                 "--endpoint",
                 endpoint
               ],
               client: client
             )

    assert_receive {:file_request, request}
    assert request["task"] == "CLI objective wins."
    assert request["auth_profile"] == "file-service"
    assert request["sandbox"] == "podman"
    assert request["network"] == "none"
    assert request["allowed_paths"] == ["apps/core"]
    assert request["timeout_ms"] == 900_000
    assert request["budget"]["tokens"] == 7_000
    assert request["budget"]["cost_micros"] == 2_000_000
    assert request["budget"]["time_ms"] == 600_000
    assert request["budget"]["tool_calls"] == 90
    assert request["repository"] == Path.expand("repository", Path.dirname(task_file))
  end

  test "session start reads Markdown and rejects unknown YAML fields before discovery" do
    endpoint = endpoint_file()
    markdown = task_file("task.md", "# Fix restart\n\nVerify the durable state.")
    parent = self()

    client = fn _address, request, _opts ->
      send(parent, {:markdown_request, request})

      {:ok,
       %{
         "plan_id" => "mgr_md",
         "child_id" => "child_md",
         "session_id" => "sess_md",
         "status" => "submitted",
         "sandbox" => request["sandbox"],
         "repository" => request["repository"]
       }}
    end

    assert {:ok, _output, 0} =
             SessionStart.run(
               [
                 "--task-file",
                 markdown,
                 "--auth-profile",
                 "codex-service",
                 "--endpoint",
                 endpoint
               ],
               client: client
             )

    assert_receive {:markdown_request, %{"task" => objective}}
    assert objective == "# Fix restart\n\nVerify the durable state."

    invalid = task_file("invalid.yaml", "task: Fix it.\nelevated: true\n")
    assert {:ok, error, code} = SessionStart.run(["--task-file", invalid])
    assert code != 0
    assert error =~ "session_task_file_unknown_fields"
  end

  test "session start accepts a positional task file and explicit working-tree input" do
    endpoint = endpoint_file()
    markdown = task_file("positional-task.md", "Fix the workspace race.")
    parent = self()

    client = fn _address, request, _opts ->
      send(parent, {:positional_request, request})

      {:ok,
       %{
         "plan_id" => "mgr_positional",
         "child_id" => "child_positional",
         "session_id" => "sess_positional",
         "status" => "submitted",
         "sandbox" => request["sandbox"],
         "repository" => request["repository"],
         "source_mode" => request["source_mode"],
         "base_commit" => "abc123"
       }}
    end

    assert {:ok, output, 0} =
             SessionStart.run(
               [
                 markdown,
                 "--auth-profile",
                 "codex-service",
                 "--source",
                 "working-tree",
                 "--include-untracked",
                 "--endpoint",
                 endpoint
               ],
               client: client
             )

    assert output =~ "Source: working-tree@abc123"

    assert_receive {:positional_request, request}
    assert request["task"] == "Fix the workspace race."
    assert request["source_mode"] == "working-tree"
    assert request["include_untracked"]
    refute request["include_ignored"]
  end

  test "source include flags require the explicit working-tree authority" do
    assert {:ok, output, code} =
             SessionStart.run([
               "--task",
               "Fix it",
               "--auth-profile",
               "service",
               "--include-untracked"
             ])

    assert code != 0
    assert output =~ "source_include_requires_working_tree"
  end

  test "sandbox setup passes explicit resource sizing to onboarding" do
    parent = self()

    setup = fn backend, opts ->
      send(parent, {:setup, backend, opts})

      {:ok,
       %{
         status: :ready,
         backend: backend,
         data_root: opts[:data_root],
         steps: [%{name: :podman_machine}, %{name: :worker_image_qualified}]
       }}
    end

    assert {:ok, output, 0} =
             SandboxSetup.run(
               [
                 "--backend",
                 "podman",
                 "--qualify-image",
                 "--data-root",
                 "/tmp/twelvgaige-cli-data",
                 "--source-root",
                 "/tmp/source",
                 "--machine",
                 "dedicated",
                 "--cpus",
                 "6",
                 "--memory-mib",
                 "8192",
                 "--disk-gib",
                 "80",
                 "--worker-image",
                 "localhost/worker:pinned"
               ],
               setup_fun: setup
             )

    assert output =~ "Sandbox ready: podman"
    assert output =~ "worker_image_qualified"

    assert_receive {:setup, :podman, opts}
    assert opts[:qualify_image?]
    assert opts[:machine_name] == "dedicated"
    assert opts[:cpus] == 6
    assert opts[:memory_mib] == 8192
    assert opts[:disk_size_gib] == 80
    assert opts[:worker_image] == "localhost/worker:pinned"
  end

  test "sandbox check is read-only, Podman-authoritative, and supports JSON" do
    check = fn backend, opts ->
      concrete = if backend == :auto, do: :podman, else: backend
      {:ok, %{status: :ready, backend: concrete, data_root: opts[:data_root]}}
    end

    assert {:ok, output, 0} =
             SandboxSetup.run(
               [
                 "--backend",
                 "auto",
                 "--check",
                 "--data-root",
                 "/tmp/check",
                 "--format",
                 "json"
               ],
               check_fun: check
             )

    assert Jason.decode!(output) == %{
             "backend" => "podman",
             "data_root" => "/tmp/check",
             "status" => "ready"
           }

    assert {:ok, error, code} = SandboxSetup.run(["--cpus", "0"])
    assert code != 0
    assert error =~ "sandbox_setup_positive_integer_required"
  end

  defp endpoint_file do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-cli-endpoint-#{System.unique_integer([:positive])}"
      )

    path = Path.join(root, "breech.endpoint.json")
    on_exit(fn -> File.rm_rf!(root) end)

    :ok =
      Endpoint.write(%{address: {:tcp, {127, 0, 0, 1}, 4321}, token: "control-token"},
        path: path
      )

    path
  end

  defp task_file(name, contents) do
    path = Path.join(Path.dirname(endpoint_file()), name)
    File.write!(path, contents)
    path
  end

  defp structured_task_yaml do
    """
    version: 1
    task: File objective.
    repository: repository
    auth_profile: file-service
    sandbox: apple-container
    network: none
    allowed_paths:
      - lib
      - test
    timeout: 15m
    budget:
      tokens: 20000
      cost_micros: 2000000
      time_ms: 600000
      tool_calls: 90
    """
  end

  defp planned_saved_plan(request) do
    {:ok, saved_plan} = Twelvgaige.Manager.SavedPlan.build(request, planned_result(request))
    saved_plan
  end

  defp planned_result(request) do
    %{
      status: :planned,
      mutates_state: false,
      request_id: request["request_id"],
      plan_id: "mgr_saved_cli",
      child_id: "child_saved_cli",
      session_id: "sess_saved_cli",
      approval_status: :within_envelope,
      runtime: request["runtime"],
      objective: request["task"],
      repository: request["repository"],
      base_ref: request["base_ref"],
      base_commit: String.duplicate("a", 40),
      source_mode: request["source_mode"],
      source_state_token: "sha256:planned-source",
      repository_state: %{
        dirtiness: %{staged: 0, unstaged: 0, untracked: 0, ignored: 0},
        warnings: [],
        unsupported_features: []
      },
      auth_profile: request["auth_profile"],
      profile: request["profile"],
      configuration_provenance: request["provenance"],
      sandbox: request["sandbox"],
      sandbox_profile: "coding_restricted:podman",
      network: "broker_only",
      allowed_paths: request["allowed_paths"],
      write: request["write"],
      capabilities: ["filesystem.write"],
      deadline: "2026-08-11T13:00:00Z",
      budget: request["budget"]
    }
  end
end
