defmodule Twelvgaige.Manager.SupervisorTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Manager.Supervisor, as: ManagerSupervisor

  test "restarts the scheduler after its durable store authority is replaced" do
    supervisor_name = :manager_supervisor_test
    store_name = :manager_store_test
    scheduler_name = :manager_scheduler_test
    workspace_name = :manager_workspace_test
    path = Path.join(temp_dir(), "manager.store")

    {:ok, supervisor} =
      ManagerSupervisor.start_link(
        name: supervisor_name,
        store_name: store_name,
        scheduler_name: scheduler_name,
        workspace_manager_name: workspace_name,
        store_path: path,
        scheduler: [executor: fn _child -> {:error, :not_used} end]
      )

    on_exit(fn ->
      if Process.alive?(supervisor), do: safe_stop(supervisor)
    end)

    first_store = Process.whereis(store_name)
    first_scheduler = Process.whereis(scheduler_name)
    assert is_pid(first_store) and is_pid(first_scheduler)

    Process.exit(first_store, :kill)

    assert_eventually(fn ->
      store = Process.whereis(store_name)
      scheduler = Process.whereis(scheduler_name)

      is_pid(store) and is_pid(scheduler) and store != first_store and
        scheduler != first_scheduler
    end)
  end

  test "owns the sandbox authority and production executor when runtime is configured" do
    suffix = System.unique_integer([:positive])
    supervisor_name = String.to_atom("manager_runtime_supervisor_#{suffix}")
    store_name = String.to_atom("manager_runtime_store_#{suffix}")
    scheduler_name = String.to_atom("manager_runtime_scheduler_#{suffix}")
    workspace_name = String.to_atom("manager_runtime_workspace_#{suffix}")
    admission_name = String.to_atom("manager_runtime_admission_#{suffix}")
    sandbox_name = String.to_atom("manager_runtime_sandbox_#{suffix}")
    root = temp_dir()

    {:ok, supervisor} =
      ManagerSupervisor.start_link(
        name: supervisor_name,
        store_name: store_name,
        scheduler_name: scheduler_name,
        workspace_manager_name: workspace_name,
        store_path: Path.join(root, "manager.store"),
        workspace_root: Path.join(root, "workspaces"),
        scheduler: [],
        runtime: [
          backend: Twelvgaige.Sandbox.Backend.Podman,
          admission_name: admission_name,
          sandbox_manager_name: sandbox_name,
          admission_limits: [
            sandboxes: 1,
            cpu: 2,
            memory_bytes: 2_147_483_648,
            pids: 256,
            workspace_bytes: 10_737_418_240,
            artifact_bytes: 2_147_483_648,
            provider_tokens: 100_000
          ],
          backend_opts: [allowed_roots: [root], machine_name: "twelvgaige"],
          auth_profiles: %{},
          image_reference: "localhost/twelvgaige/worker",
          image_digest: "sha256:" <> String.duplicate("a", 64),
          policy_revision: "runtime-policy-v1"
        ]
      )

    on_exit(fn ->
      if Process.alive?(supervisor), do: safe_stop(supervisor)
    end)

    first_admission = Process.whereis(admission_name)
    first_sandbox = Process.whereis(sandbox_name)
    first_scheduler = Process.whereis(scheduler_name)

    assert is_pid(first_admission)
    assert is_pid(first_sandbox)
    assert is_pid(first_scheduler)
    assert is_function(:sys.get_state(first_scheduler).executor, 1)

    Process.exit(first_admission, :kill)

    assert_eventually(fn ->
      admission = Process.whereis(admission_name)
      sandbox = Process.whereis(sandbox_name)
      scheduler = Process.whereis(scheduler_name)

      is_pid(admission) and admission != first_admission and
        is_pid(sandbox) and sandbox != first_sandbox and
        is_pid(scheduler) and scheduler != first_scheduler
    end)
  end

  defp assert_eventually(fun) do
    deadline = System.monotonic_time(:millisecond) + 1_000
    do_assert_eventually(fun, deadline)
  end

  defp do_assert_eventually(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        do_assert_eventually(fun, deadline)
    end
  end

  defp temp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-manager-supervisor-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp safe_stop(pid) do
    Supervisor.stop(pid)
  catch
    :exit, _reason -> :ok
  end
end
