defmodule Twelvgaige.DeveloperExperienceTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.IPC.Endpoint

  alias Twelvgaige.CLI.Commands.{
    Developer,
    SessionFollow,
    SessionPlan,
    SessionRetry,
    SessionReview,
    SessionStart,
    TaskValidate
  }

  alias Twelvgaige.Developer.{Config, Doctor, Init}
  alias Twelvgaige.Manager.SessionRetry, as: ManagerSessionRetry
  alias Twelvgaige.Manager.SessionStart, as: ManagerSessionStart
  alias Twelvgaige.Operations.{SessionControl, Store}

  test "project profiles override user defaults while CLI values remain authoritative" do
    root = temp_dir("profiles")
    user = Path.join(root, "user.yaml")
    project = Path.join([root, ".twelvgaige", "config.yaml"])
    File.mkdir_p!(Path.dirname(project))

    File.write!(user, """
    version: 1
    default_profile: local
    profiles:
      local:
        auth_profile: user-auth
        sandbox: podman
        network: none
    """)

    File.write!(project, """
    version: 1
    profiles:
      local:
        auth_profile: project-auth
        allowed_paths: [lib]
    """)

    assert {:ok, profile} =
             Config.resolve_profile(nil,
               project_root: root,
               user_config_path: user,
               project_config_path: project
             )

    assert profile.name == "local"
    assert profile.values.auth_profile == "project-auth"
    assert profile.values.sandbox == "podman"
    assert profile.values.allowed_paths == ["lib"]

    assert {:ok, opts} =
             Twelvgaige.CLI.Commands.SessionStart.resolve(
               ["--task", "Fix it", "--auth-profile", "cli-auth"],
               config_opts: [
                 project_root: root,
                 user_config_path: user,
                 project_config_path: project
               ]
             )

    assert opts[:auth_profile] == "cli-auth"
    assert opts[:network] == "none"
  end

  test "init writes a secret-free usable project and refuses accidental overwrite" do
    root = temp_dir("init")
    assert {:ok, result} = Init.run(project_root: root, auth_profile: "local-account")
    assert File.regular?(result.config_path)
    assert File.regular?(result.task_path)
    refute File.read!(result.config_path) =~ "secret"

    assert {:ok, profile} =
             Config.resolve_profile(nil,
               project_root: root,
               user_config_path: Path.join(root, "missing.yaml")
             )

    assert profile.values.repository == root
    assert profile.values.auth_profile == "local-account"
    assert {:error, {:init_target_exists, _path}} = Init.run(project_root: root)
  end

  test "doctor reports concrete fixes and --fix delegates only explicit repairs" do
    root = temp_dir("doctor")

    assert {:ok, report} =
             Doctor.run(
               project_root: root,
               auth_profile: "local-account",
               fix?: true,
               disk_available_fun: fn _path -> {:ok, 10 * 1_024 * 1_024 * 1_024} end,
               executable_finder: fn "codex" -> "/usr/local/bin/codex" end,
               sandbox_check_fun: fn :podman, _opts -> {:error, :not_ready} end,
               sandbox_setup_fun: fn :podman, _opts -> {:ok, %{ready: true}} end
             )

    assert report.status == :ready
    assert report.fixes == [:project_initialized, :sandbox_configured]
    assert report.versions.cli == Twelvgaige.version()
    assert report.versions.daemon_protocol == Twelvgaige.Breech.IPC.Protocol.api_version()
    assert report.versions.provider == Twelvgaige.Integration.Codex.descriptor().artifact_version
    assert report.versions.credential_mode == :brokered_service
    assert report.capabilities.provider.structured_protocol
    assert report.capabilities.native_subagents
    assert Enum.find(report.checks, &(&1.name == :disk_capacity)).status == :ok

    missing_auth_root = temp_dir("doctor-missing-auth")
    assert {:ok, _initialized} = Init.run(project_root: missing_auth_root)

    assert {:ok, missing_auth} =
             Doctor.run(
               project_root: missing_auth_root,
               user_config_path: Path.join(missing_auth_root, "missing.yaml"),
               disk_available_fun: fn _path -> {:ok, 10 * 1_024 * 1_024 * 1_024} end,
               executable_finder: fn "codex" -> "/usr/local/bin/codex" end,
               sandbox_check_fun: fn :podman, _opts -> {:ok, %{ready: true}} end
             )

    assert missing_auth.status == :action_required
    assert Enum.find(missing_auth.checks, &(&1.name == :authentication_profile)).status == :error
  end

  test "doctor reports actionable disk pressure without exposing a data path" do
    root = temp_dir("doctor-disk-pressure")
    assert {:ok, _initialized} = Init.run(project_root: root, auth_profile: "local-account")

    assert {:ok, report} =
             Doctor.run(
               project_root: root,
               executable_finder: fn "codex" -> "/usr/local/bin/codex" end,
               sandbox_check_fun: fn :podman, _opts -> {:ok, %{ready: true}} end,
               disk_available_fun: fn _path -> {:ok, 1_024} end
             )

    assert report.status == :action_required
    disk = Enum.find(report.checks, &(&1.name == :disk_capacity))
    assert disk.status == :error
    assert disk.detail.available_bytes == 1_024
    assert disk.remedy =~ "workspace retention status"
    refute inspect(disk) =~ System.user_home!()
  end

  test "task validate and session plan catch errors without daemon submission" do
    root = temp_dir("plan")
    task = Path.join(root, "task.yaml")

    File.write!(task, """
    version: 1
    objective: Verify dry-run behavior.
    repository: .
    auth_profile: local-account
    sandbox: podman
    network: none
    """)

    config_opts = [project_root: root, user_config_path: Path.join(root, "missing.yaml")]

    assert {:ok, validation, 0} =
             TaskValidate.run(task, ["--format", "json"], config_opts: config_opts)

    assert Jason.decode!(validation)["status"] == "valid"

    plan_fun = fn request, _opts ->
      send(self(), {:planned, request})

      {:ok,
       %{
         status: :planned,
         runtime: "codex",
         repository: request["repository"],
         base_commit: "abc123",
         sandbox_profile: "coding_restricted:podman",
         network: "none",
         write: true,
         allowed_paths: [],
         approval_status: :within_envelope,
         deadline: "2026-08-09T00:00:00Z"
       }}
    end

    assert {:ok, output, 0} =
             SessionPlan.run(["--task-file", task],
               plan_fun: plan_fun,
               config_opts: config_opts
             )

    assert output =~ "no state changed"
    assert_receive {:planned, %{"task" => "Verify dry-run behavior."}}

    assert {:ok, planned} =
             ManagerSessionStart.plan(
               %{
                 "task" => "Inspect",
                 "repository" => root,
                 "auth_profile" => "local-account",
                 "network" => "none"
               },
               identity_fun: fn [] -> {:ok, %{uid: 501, username: "operator"}} end,
               git_resolver: fn ^root, "HEAD", [] -> {:ok, "abc123"} end
             )

    assert planned.mutates_state == false
    assert planned.base_commit == "abc123"
  end

  test "follow returns durable events and terminal state" do
    endpoint = %{address: {:tcp, {127, 0, 0, 1}, 1}, token: "token"}

    events = fn _address, "sess_one", opts ->
      assert opts[:after_seq] == -1
      {:ok, [%{"seq" => 1, "type" => "completed"}]}
    end

    session = fn _address, "sess_one", _opts -> {:ok, %{"status" => "completed"}} end

    assert {:ok, result} =
             SessionFollow.follow(
               endpoint,
               "sess_one",
               [poll_ms: 1, follow_timeout_ms: 100, ipc_timeout_ms: 10],
               events_client: events,
               session_client: session
             )

    assert result.status == "completed"
    assert length(result.events) == 1
  end

  test "developer and lifecycle command front doors preserve JSON and explicit options" do
    root = temp_dir("commands")
    endpoint_path = endpoint_file(root)
    parent = self()

    init_fun = fn opts ->
      send(parent, {:init_opts, opts})

      {:ok,
       %{
         status: :initialized,
         project_root: root,
         profile: opts[:profile],
         config_path: Path.join(root, "config.yaml"),
         task_path: Path.join(root, "task.yaml"),
         auth_configured: true
       }}
    end

    assert {:ok, initialized, 0} =
             Developer.init(
               ["--root", root, "--profile", "focused", "--auth-profile", "service"],
               init_fun: init_fun
             )

    assert initialized =~ "Project initialized"
    assert_receive {:init_opts, opts}
    assert opts[:profile] == "focused"
    assert opts[:auth_profile] == "service"

    doctor_fun = fn opts ->
      send(parent, {:doctor_opts, opts})
      {:ok, %{status: :ready, checks: [], fixes: [:sandbox_configured]}}
    end

    assert {:ok, doctor_json, 0} =
             Developer.doctor(["--fix", "--format", "json"], doctor_fun: doctor_fun)

    assert Jason.decode!(doctor_json)["status"] == "ready"
    assert_receive {:doctor_opts, doctor_opts}
    assert doctor_opts[:fix?]

    review_client = fn _address, "sess_one", opts ->
      send(parent, {:review_opts, opts})
      {:ok, %{"session" => %{"status" => "completed"}, "mutates_state" => false}}
    end

    assert {:ok, review_json, 0} =
             SessionReview.run(
               "sess_one",
               ["--endpoint", endpoint_path, "--format", "json"],
               client: review_client
             )

    assert Jason.decode!(review_json)["mutates_state"] == false
    assert_receive {:review_opts, review_opts}
    assert review_opts[:token] == "control-token"

    retry_client = fn _address, "sess_one", opts ->
      send(parent, {:retry_opts, opts})

      {:ok,
       %{
         "session_id" => "sess_two",
         "retry_of_session_id" => "sess_one",
         "retry_mode" => "repair"
       }}
    end

    assert {:ok, retried, 0} =
             SessionRetry.run(
               "sess_one",
               ["--repair", "--endpoint", endpoint_path],
               client: retry_client
             )

    assert retried =~ "sess_two"
    assert_receive {:retry_opts, retry_opts}
    assert retry_opts[:repair?]
  end

  test "session start --follow and standalone watch share the event follower" do
    root = temp_dir("start-follow")
    endpoint_path = endpoint_file(root)
    parent = self()
    config_opts = [project_root: root, user_config_path: Path.join(root, "missing.yaml")]

    start_client = fn _address, request, _opts ->
      send(parent, {:start_follow_request, request})

      {:ok,
       %{
         "plan_id" => "plan_one",
         "child_id" => "child_one",
         "session_id" => "sess_one",
         "status" => "submitted",
         "sandbox" => request["sandbox"],
         "repository" => request["repository"]
       }}
    end

    follow_fun = fn _endpoint, "sess_one", opts, _deps ->
      assert opts[:poll_ms] == 5
      {:ok, %{status: "completed", events: [%{"seq" => 1}]}}
    end

    assert {:ok, started, 0} =
             SessionStart.run(
               [
                 "--task",
                 "Fix it",
                 "--auth-profile",
                 "service",
                 "--follow",
                 "--poll-ms",
                 "5",
                 "--endpoint",
                 endpoint_path
               ],
               client: start_client,
               follow_fun: follow_fun,
               config_opts: config_opts
             )

    assert started =~ "Final status: completed"
    assert_receive {:start_follow_request, %{"task" => "Fix it"}}

    events = fn _address, "sess_one", _opts -> {:ok, [%{"seq" => 2}]} end
    session = fn _address, "sess_one", _opts -> {:ok, %{"status" => "failed"}} end

    assert {:ok, watched, 0} =
             SessionFollow.run(
               "sess_one",
               ["--endpoint", endpoint_path, "--poll-ms", "5"],
               events_client: events,
               session_client: session
             )

    assert watched =~ "Session sess_one: failed"
  end

  test "repair reuses exact authority, adds failure context, and stays single-attempt" do
    root = temp_dir("retry")
    store = start_supervised!({Store, name: nil, path: Path.join(root, "operations.sqlite3")})

    control =
      start_supervised!(
        {SessionControl,
         name: nil,
         store: store,
         owner_uid: 42,
         username: "operator",
         workspace_root: Path.join(root, "workspaces")}
      )

    request = %{
      "runtime" => "codex",
      "repository" => root,
      "base_ref" => "HEAD",
      "task" => "Make the tests pass",
      "auth_profile" => "local-account",
      "sandbox" => "podman",
      "network" => "none",
      "allowed_paths" => ["lib", "test"],
      "write" => true,
      "timeout_ms" => 60_000,
      "budget" => %{
        "tokens" => 1_000,
        "cost_micros" => 1_000,
        "time_ms" => 60_000,
        "tool_calls" => 20
      }
    }

    assert {:ok, _} =
             SessionControl.register(
               %{
                 id: "sess_failed",
                 status: :failed,
                 runtime: :codex,
                 start_request: request,
                 error: "verification failed",
                 created_at: ~U[2026-08-09 00:00:00Z]
               },
               server: control,
               uid: 42
             )

    parent = self()

    starter = fn retried_request, opts ->
      send(parent, {:retried, retried_request, opts})
      {:ok, %{session_id: "sess_repair", plan_id: "plan_repair"}}
    end

    assert {:ok, result} =
             ManagerSessionRetry.retry("sess_failed", %{"repair" => true},
               session_control: control,
               start_fun: starter,
               uid: 42
             )

    assert result.retry_mode == :repair

    assert_receive {:retried, retried, retry_opts}
    assert retried["repository"] == root
    assert retried["sandbox"] == "podman"
    assert retried["allowed_paths"] == ["lib", "test"]
    assert retried["task"] =~ "verification failed"
    assert retry_opts[:retry_of_session_id] == "sess_failed"

    assert {:error, :session_repair_already_attempted} =
             ManagerSessionRetry.retry("sess_failed", %{"repair" => true},
               session_control: control,
               start_fun: starter,
               uid: 42
             )

    assert {:ok, _} =
             SessionControl.register(
               %{
                 id: "sess_normal_retry",
                 status: :failed,
                 runtime: :codex,
                 start_request: request,
                 created_at: ~U[2026-08-09 00:00:00Z]
               },
               server: control,
               uid: 42
             )

    for _attempt <- 1..3 do
      assert {:ok, %{retry_mode: :retry}} =
               ManagerSessionRetry.retry("sess_normal_retry", %{},
                 session_control: control,
                 start_fun: starter,
                 uid: 42
               )
    end

    assert {:error, :session_retry_limit_reached} =
             ManagerSessionRetry.retry("sess_normal_retry", %{},
               session_control: control,
               start_fun: starter,
               uid: 42
             )

    assert {:ok, _} =
             SessionControl.register(
               %{
                 id: "sess_running_retry",
                 status: :running,
                 runtime: :codex,
                 start_request: request,
                 created_at: ~U[2026-08-09 00:00:00Z]
               },
               server: control,
               uid: 42
             )

    assert {:error, :session_retry_requires_terminal_session} =
             ManagerSessionRetry.retry("sess_running_retry", %{},
               session_control: control,
               start_fun: starter,
               uid: 42
             )
  end

  defp temp_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp endpoint_file(root) do
    path = Path.join(root, "breech.endpoint.json")

    :ok =
      Endpoint.write(%{address: {:tcp, {127, 0, 0, 1}, 4321}, token: "control-token"},
        path: path
      )

    path
  end
end
