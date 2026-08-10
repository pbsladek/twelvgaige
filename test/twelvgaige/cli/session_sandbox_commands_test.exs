defmodule Twelvgaige.CLI.SessionSandboxCommandsTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.CLI.Commands.{SandboxSetup, SessionStart}

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
end
