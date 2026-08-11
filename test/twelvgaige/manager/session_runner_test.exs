defmodule Twelvgaige.Manager.SessionRunnerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession
  alias Twelvgaige.DelegatedSession.Event
  alias Twelvgaige.Manager.{Budget, ChildRecord, SessionRunner}
  alias Twelvgaige.Manager.Plan.Task

  defmodule Backend do
    @behaviour Twelvgaige.Sandbox.Backend

    def probe(_opts), do: {:ok, %{available: true}}
    def prepare(spec, _opts), do: {:ok, Map.put(spec, :backend, :runner_test)}

    def create(manifest, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runtime_create, Keyword.fetch!(opts, :command)})
      {:ok, "sandbox_session_runner", %{manifest: manifest}}
    end

    def start(_resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), :unexpected_detached_start)
      {:error, :unexpected_detached_start}
    end

    def stdio_transport(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runtime_attach, resource_id})

      {:ok,
       %{
         binary: "/qualified/container-runtime",
         arguments: ["start", "--attach", "--interactive", resource_id],
         environment: [{"PATH", "/qualified/bin"}]
       }}
    end

    def inspect(resource_id, _opts), do: {:ok, %{resource_id: resource_id, status: :created}}

    def stop(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runtime_stop, resource_id})
      :ok
    end

    def destroy(resource_id, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runtime_destroy, resource_id})
      :ok
    end

    def export_workspace(resource_id, destination, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:runtime_export, resource_id, destination})
      {:ok, %{destination: destination, bytes: 0, entries: 0}}
    end

    def reconcile(durable, _opts), do: {:ok, :resume, durable}
  end

  defmodule Adapter do
    @behaviour Twelvgaige.DelegatedSession.Adapter

    def capabilities(_config), do: {:ok, %{}}

    def prepare(%{adapter_config: config}) do
      send(config.test_pid, {:adapter_config, config})

      if config[:fail_prepare],
        do: {:error, :adapter_prepare_failed},
        else: {:ok, config}
    end

    def authenticate(config, lease) do
      send(config.test_pid, {:authenticated, lease})
      {:ok, config}
    end

    def start(config, _spec),
      do:
        {:ok, config,
         %{external_session_id: "thread_session_runner", external_turn_id: "turn_session_runner"}}

    def resume(external_id, prepared, _spec),
      do: {:ok, prepared, %{external_session_id: external_id}}

    def send_input(_handle, _input), do: :ok
    def decide(_handle, _approval_id, _receipt), do: :ok
    def cancel(_handle, _reason), do: :ok
    def snapshot(_handle), do: {:ok, %{}}
    def reconcile(_durable, observed), do: {:ok, :resume, observed}

    def drain(config, _limit) do
      Agent.get_and_update(config.events, fn
        [events | rest] -> {{:ok, events}, rest}
        [] -> {{:ok, []}, []}
      end)
    end

    def finalize(_handle), do: {:ok, %{events: []}}
  end

  test "runs a delegated turn through one attached sandbox lifecycle" do
    {manager, events} = runtime()
    on_exit(fn -> if Process.alive?(events), do: Agent.stop(events) end)

    :ok = Agent.update(events, fn _ -> [[event(:turn_completed)]] end)
    session = session()
    child = child()
    result_destination = result_destination()

    assert {:ok,
            %{
              handoff: %{objective_status: :complete, base_commit: "base-commit"},
              runtime_quiescence: %{
                runtime_stopped: true,
                runtime_identity: "sandbox_session_runner"
              },
              usage: %Budget{}
            }} =
             SessionRunner.run(session, child, %{},
               sandbox_manager: manager,
               sandbox_spec_resolver: fn ^session, ^child ->
                 %{reservation: %{sandboxes: 1}}
               end,
               sandbox_opts: [test_pid: self()],
               adapter: Adapter,
               adapter_config: %{
                 test_pid: self(),
                 events: events,
                 client: self(),
                 client_module: :host_bypass,
                 client_opts: [send_frame: fn _frame -> :ok end, binary: "/host/codex"]
               },
               result_destination: result_destination,
               poll_ms: 0
             )

    assert_receive {:runtime_create,
                    ["/opt/codex/bin/codex", "app-server", "--stdio", "--strict-config"]}

    assert_receive {:runtime_attach, "sandbox_session_runner"}
    assert_receive {:adapter_config, config}
    refute Map.has_key?(config, :client)
    refute Map.has_key?(config, :client_module)
    refute Keyword.has_key?(config.client_opts, :send_frame)
    assert config.client_opts[:binary] == "/qualified/container-runtime"
    assert config.client_opts[:policy_profile] == :outer_authoritative
    refute_received :unexpected_detached_start
    assert_receive {:runtime_stop, "sandbox_session_runner"}
    assert_receive {:runtime_export, "sandbox_session_runner", ^result_destination}
    assert_receive {:runtime_destroy, "sandbox_session_runner"}
  end

  test "destroys the governed sandbox when provider preparation fails" do
    {manager, events} = runtime()
    on_exit(fn -> if Process.alive?(events), do: Agent.stop(events) end)

    assert {:error, :adapter_prepare_failed, %{usage: %Budget{}}} =
             SessionRunner.run(session(), child(), %{},
               sandbox_manager: manager,
               sandbox_spec_resolver: fn _session, _child ->
                 %{reservation: %{sandboxes: 1}}
               end,
               sandbox_opts: [test_pid: self()],
               adapter: Adapter,
               adapter_config: %{test_pid: self(), events: events, fail_prepare: true},
               result_destination: result_destination(),
               poll_ms: 0
             )

    assert_receive {:runtime_stop, "sandbox_session_runner"}
    assert_receive {:runtime_destroy, "sandbox_session_runner"}
    refute_received :unexpected_detached_start
  end

  test "fails before allocation when the bound sandbox context cannot be resolved" do
    assert {:error, :sandbox_context_unavailable} =
             SessionRunner.run(session(), child(), %{},
               sandbox_manager: self(),
               sandbox_spec_resolver: fn _session, _child ->
                 {:error, :sandbox_context_unavailable}
               end
             )

    refute_received {:runtime_create, _command}
  end

  defp runtime do
    admission =
      start_supervised!(
        {Twelvgaige.Sandbox.Admission,
         name: nil,
         limits: [
           sandboxes: 1,
           cpu: 1,
           memory_bytes: 1_024,
           pids: 10,
           workspace_bytes: 1_024,
           artifact_bytes: 1_024,
           provider_tokens: 100
         ]}
      )

    manager =
      start_supervised!(
        {Twelvgaige.Sandbox.Manager, name: nil, admission: admission, backend: Backend}
      )

    {:ok, events} = Agent.start_link(fn -> [] end)
    {manager, events}
  end

  defp result_destination do
    path =
      Path.join(System.tmp_dir!(), "session-runner-result-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp event(type) do
    Event.new(
      session_id: "session-runner",
      event_type: type,
      native_session_id: "thread_session_runner",
      native_turn_id: "turn_session_runner",
      native_event_id: "event-#{type}",
      payload: %{},
      occurred_at: DateTime.utc_now()
    )
  end

  defp session do
    DelegatedSession.new(%{
      id: "session-runner",
      round_id: "round",
      shot_id: "shot",
      attempt: 0,
      runtime: :codex,
      driver: :codex_app_server_v2,
      runtime_version: Twelvgaige.DelegatedSession.Codex.Schema.cli_version(),
      integration_descriptor_id: "codex",
      workspace_id: "workspace-runner",
      base_commit: "base-commit",
      auth_profile_id: "api",
      auth_revision: 1,
      sandbox_profile: :coding_restricted,
      sandbox_manifest_digest: String.duplicate("a", 64),
      policy_revision: "policy-1",
      budgets: Map.from_struct(Budget.zero()),
      deadline: DateTime.add(DateTime.utc_now(), 60, :second),
      created_at: DateTime.utc_now()
    })
  end

  defp child do
    task = %Task{
      id: "task",
      agent: "codex",
      workflow: "coding.change.v1",
      objective: "change code",
      repository: "/repo",
      base_ref: "main",
      auth_profile_id: "api",
      sandbox_profile: :coding_restricted,
      network_mode: :none,
      capabilities: ["filesystem.write"],
      budget: Budget.zero(),
      deadline: DateTime.add(DateTime.utc_now(), 60, :second)
    }

    %ChildRecord{
      id: "child",
      plan_id: "plan",
      task_id: "task",
      attempt: 0,
      round_id: "round",
      shot_id: "shot",
      parent_session_id: "parent",
      delegated_session_id: "session-runner",
      workspace_id: "workspace-runner",
      task: task,
      budget: task.budget,
      deadline: task.deadline,
      created_at: DateTime.utc_now()
    }
  end
end
