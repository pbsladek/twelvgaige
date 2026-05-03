defmodule Twelvgaige.CLI.CommandsTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.CLI.Main

  @workflow_path "test/fixtures/shells/simple_workflow.yaml"

  test "shell validate succeeds for workflow shells" do
    assert {:ok, output, 0} = Main.run(["shell", "validate", @workflow_path])

    assert output == "valid workflow shell: simple 1.0.0\n"
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

    assert [event] =
             output
             |> String.split("\n", trim: true)
             |> Enum.map(&Jason.decode!/1)

    assert event["round_id"] == round_id
    assert event["seq"] == 1
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

  test "round watch can follow for the next daemon-owned round event" do
    assert {:ok, round_id} =
             Twelvgaige.run_round("test/fixtures/shells/safety_workflow.yaml", %{
               "cluster" => "dev"
             })

    assert eventually(fn ->
             match?({:ok, %{status: :awaiting_safety}}, Twelvgaige.get_round(round_id))
           end)

    assert {:ok, [awaiting_event]} = Twelvgaige.list_round_events(round_id)

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
    assert event["event_type"] == "round_completed"
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

    assert Enum.map(events, & &1["round_id"]) == [round_id, round_id]
    assert Enum.map(events, & &1["event_type"]) == ["round_awaiting_safety", "round_completed"]
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
end
