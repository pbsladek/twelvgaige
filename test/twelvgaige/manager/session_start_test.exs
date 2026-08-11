defmodule Twelvgaige.Manager.SessionStartTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.{SavedPlan, SessionStart}

  test "starts an unchanged digest-bound plan and returns its digest" do
    repository = temp_repository()
    request = saved_plan_request(repository)
    manager_opts = saved_plan_manager_opts(repository, "sha256:source-one")

    assert {:ok, planned} = SessionStart.plan(request, manager_opts)
    assert {:ok, saved_plan} = SavedPlan.build(request, planned)
    assert planned.plan_digest == saved_plan["plan_digest"]

    assert {:ok, started} =
             SessionStart.start(
               Map.put(request, "saved_plan", saved_plan),
               manager_opts ++
                 [submit_fun: fn compiled, _opts -> {:ok, compiled.plan.id, :submitted} end]
             )

    assert started.status == :submitted
    assert started.plan_digest == saved_plan["plan_digest"]
    assert started.plan_id == planned.plan_id
    assert started.session_id == planned.session_id
    assert started.source_state_token == planned.source_state_token
  end

  test "rejects saved-plan source drift before inventory allocation or submission" do
    repository = temp_repository()
    request = saved_plan_request(repository)

    assert {:ok, planned} =
             SessionStart.plan(request, saved_plan_manager_opts(repository, "sha256:planned"))

    assert {:ok, saved_plan} = SavedPlan.build(request, planned)
    parent = self()

    assert {:error, error} =
             SessionStart.start(
               Map.put(request, "saved_plan", saved_plan),
               saved_plan_manager_opts(repository, "sha256:changed") ++
                 [
                   session_control: :operations,
                   session_get_fun: fn _id, _opts -> {:error, :not_found} end,
                   session_register_fun: fn _record, _opts ->
                     send(parent, :saved_plan_allocated)
                     {:error, :unexpected}
                   end,
                   submit_fun: fn _compiled, _opts ->
                     send(parent, :saved_plan_submitted)
                     {:error, :unexpected}
                   end
                 ]
             )

    assert error.class == :input_error
    assert error.reason == :session_saved_plan_drift
    assert error.message == "saved session plan drifted at source_state_token"
    assert error.details.field == "source_state_token"
    refute_receive :saved_plan_allocated
    refute_receive :saved_plan_submitted
  end

  test "rejects changed saved-plan request fields without exposing their values" do
    repository = temp_repository()
    request = saved_plan_request(repository)

    assert {:ok, planned} =
             SessionStart.plan(request, saved_plan_manager_opts(repository, "sha256:planned"))

    assert {:ok, saved_plan} = SavedPlan.build(request, planned)
    parent = self()

    changed =
      request
      |> Map.put("task", "changed task that must remain private")
      |> Map.put("saved_plan", saved_plan)

    opts = [
      repository_inspector: fn _repository, _opts ->
        send(parent, :saved_plan_inspected)
        {:error, :unexpected}
      end
    ]

    assert {:error, error} = SessionStart.start(changed, opts)
    assert error.class == :input_error
    assert error.reason == :session_saved_plan_drift
    assert error.message == "saved session plan drifted at request.task"
    assert error.details.field == "request.task"
    refute inspect(error) =~ "changed task"
    refute inspect(error) =~ request["task"]
    refute_receive :saved_plan_inspected
  end

  test "submits one exact-authority manager child and returns stable identities" do
    repository = temp_repository()
    parent = self()

    submit = fn compiled, _opts ->
      send(parent, {:compiled, compiled})
      {:ok, compiled.plan.id, :submitted}
    end

    assert {:ok, result} =
             SessionStart.start(
               %{
                 "task" => "Add the health endpoint",
                 "repository" => repository,
                 "auth_profile" => "codex-service",
                 "sandbox" => "podman",
                 "network" => "broker-only",
                 "allowed_paths" => ["lib", "test"],
                 "budget" => %{
                   "tokens" => 20_000,
                   "cost_micros" => 2_000_000,
                   "time_ms" => 600_000,
                   "tool_calls" => 200
                 },
                 "timeout_ms" => 600_000
               },
               plan_id: "mgr_start",
               manager_session_id: "sess_parent",
               round_id: "round_start",
               shot_id: "shot_start",
               now: ~U[2026-08-09 12:00:00Z],
               identity_fun: fn [] -> {:ok, %{uid: 501, username: "operator"}} end,
               git_resolver: fn ^repository, "HEAD", [] -> {:ok, "abc123"} end,
               session_control: :operations,
               require_inventory?: true,
               session_register_fun: fn record, server: :operations ->
                 send(parent, {:inventory, record})
                 {:ok, record}
               end,
               submit_fun: submit
             )

    assert result.plan_id == "mgr_start"
    assert result.status == :submitted
    assert result.sandbox_profile == "coding_restricted:podman"
    assert result.network == "broker_only"
    assert String.starts_with?(result.child_id, "child_")
    assert String.starts_with?(result.session_id, "sess_")

    assert_receive {:compiled, compiled}
    assert compiled.approval_status == :within_envelope
    assert compiled.plan.manager_principal == "local-user:501:operator"
    assert [task] = compiled.tasks
    assert task.objective == "Add the health endpoint"
    assert task.allowed_paths == ["lib", "test"]
    assert task.capabilities == ["filesystem.write"]
    assert task.budget.tokens == 20_000

    assert_receive {:inventory, inventory}
    assert inventory.id == result.session_id
    assert inventory.plan_id == result.plan_id
    assert inventory.child_id == result.child_id
    assert inventory.workspace_id =~ "ws_"
    assert inventory.sandbox_backend == :podman
    assert inventory.status == :preparing
  end

  defp saved_plan_request(repository) do
    %{
      "request_id" => "req-saved-plan",
      "task" => "Implement the saved plan without logging its body",
      "repository" => repository,
      "auth_profile" => "codex-service",
      "allowed_paths" => ["lib", "test"],
      "provenance" => %{"task" => "task_document"}
    }
  end

  defp saved_plan_manager_opts(repository, source_token) do
    [
      now: ~U[2026-08-11 12:00:00Z],
      identity_fun: fn [] -> {:ok, %{uid: 501, username: "operator"}} end,
      repository_inspector: fn ^repository, base_ref: "HEAD" ->
        {:ok,
         %{
           base_commit: String.duplicate("a", 40),
           source_state_token: source_token,
           source_modes: [:committed, :staged, :working_tree],
           unsupported_features: [],
           warnings: [],
           dirtiness: %{
             clean: true,
             staged: 0,
             unstaged: 0,
             untracked: 0,
             ignored: 0,
             unmerged: 0
           }
         }}
      end
    ]
  end

  test "requires explicit confirmation for unrestricted networking" do
    assert {:error, error} =
             SessionStart.start(%{
               "task" => "Inspect the repository",
               "repository" => System.tmp_dir!(),
               "auth_profile" => "codex-service",
               "network" => "unrestricted"
             })

    assert error.class == :input_error
    assert error.details.reason =~ "session_unrestricted_network_confirmation_required"
  end

  test "fails closed when the manager control plane is unavailable" do
    repository = temp_repository()

    assert {:error, error} =
             SessionStart.start(
               %{
                 "task" => "Inspect the repository",
                 "repository" => repository,
                 "auth_profile" => "codex-service"
               },
               identity_fun: fn [] -> {:ok, %{uid: 501, username: "operator"}} end,
               git_resolver: fn ^repository, "HEAD", [] -> {:ok, "abc123"} end
             )

    assert error.class == :internal_error
    assert error.details.reason =~ "manager_control_plane_unavailable"
  end

  test "marks the reserved inventory failed when manager submission is rejected" do
    repository = temp_repository()
    parent = self()

    assert {:error, error} =
             SessionStart.start(
               %{
                 "task" => "Inspect the repository",
                 "repository" => repository,
                 "auth_profile" => "codex-service"
               },
               identity_fun: fn [] -> {:ok, %{uid: 501, username: "operator"}} end,
               git_resolver: fn ^repository, "HEAD", [] -> {:ok, "abc123"} end,
               session_control: :operations,
               session_register_fun: fn record, _opts -> {:ok, record} end,
               session_update_fun: fn id, attrs, _opts ->
                 send(parent, {:inventory_failed, id, attrs})
                 {:ok, attrs}
               end,
               submit_fun: fn _compiled, _opts -> {:error, :manager_queue_backpressure} end
             )

    assert error.class == :internal_error
    assert_receive {:inventory_failed, session_id, %{status: :failed, error: failure}}
    assert String.starts_with?(session_id, "sess_")
    assert failure =~ "manager_queue_backpressure"
  end

  test "preflights dirty source and binds the accepted source token into the child plan" do
    repository = git_repository()
    File.write!(Path.join(repository, "staged.txt"), "planned input")
    git!(repository, ["add", "staged.txt"])

    base_request = %{
      "task" => "Use the staged input",
      "repository" => repository,
      "auth_profile" => "codex-service"
    }

    manager_opts = [
      plan_id: "mgr_source_plan",
      manager_session_id: "sess_source_parent",
      round_id: "round_source",
      shot_id: "shot_source",
      identity_fun: fn [] -> {:ok, %{uid: 501, username: "operator"}} end
    ]

    assert {:error, committed_error} = SessionStart.plan(base_request, manager_opts)
    assert committed_error.details.reason =~ "committed_source_requires_clean_repository"

    parent = self()

    request =
      Map.merge(base_request, %{
        "source_mode" => "staged",
        "include_untracked" => false,
        "include_ignored" => false
      })

    assert {:ok, result} =
             SessionStart.start(
               request,
               manager_opts ++
                 [
                   submit_fun: fn compiled, _opts ->
                     send(parent, {:source_compiled, compiled})
                     {:ok, compiled.plan.id, :submitted}
                   end
                 ]
             )

    assert result.source_mode == "staged"
    assert result.source_state_token =~ "sha256:"
    assert_receive {:source_compiled, compiled}
    assert compiled.plan.source_mode == :staged
    assert compiled.plan.source_state_token == result.source_state_token
    assert [task] = compiled.tasks
    assert task.source_mode == :staged
    assert task.source_state_token == result.source_state_token
  end

  test "replays the same request id without creating or submitting a second session" do
    repository = temp_repository()
    {:ok, inventory} = Agent.start_link(fn -> %{} end)
    parent = self()

    get = fn id, _opts ->
      case Agent.get(inventory, &Map.get(&1, id)) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end

    register = fn record, _opts ->
      Agent.update(inventory, &Map.put(&1, record.id, record))
      {:ok, record}
    end

    submit = fn compiled, _opts ->
      send(parent, {:idempotent_submit, compiled.plan.id})
      {:ok, compiled.plan.id, :submitted}
    end

    request = %{
      "request_id" => "req-session-retry",
      "task" => "Fix retry behavior",
      "repository" => repository,
      "auth_profile" => "codex-service"
    }

    opts = [
      identity_fun: fn [] -> {:ok, %{uid: 501, username: "operator"}} end,
      git_resolver: fn ^repository, "HEAD", [] -> {:ok, "abc123"} end,
      session_control: :operations,
      session_get_fun: get,
      session_register_fun: register,
      submit_fun: submit,
      now: ~U[2026-08-11 12:00:00Z]
    ]

    assert {:ok, first} = SessionStart.start(request, opts)
    assert {:ok, replay} = SessionStart.start(request, opts)
    refute first.replayed
    assert replay.replayed
    assert replay.request_id == first.request_id
    assert replay.plan_id == first.plan_id
    assert replay.child_id == first.child_id
    assert replay.session_id == first.session_id
    assert_receive {:idempotent_submit, plan_id}
    assert plan_id == first.plan_id
    refute_receive {:idempotent_submit, _another_plan}

    assert {:error, conflict} =
             SessionStart.start(Map.put(request, "task", "A different task"), opts)

    assert conflict.class == :input_error
    assert conflict.details.reason =~ "session_request_id_conflict"
  end

  test "a concurrent inventory reservation race returns the existing session without submission" do
    repository = temp_repository()
    {:ok, inventory} = Agent.start_link(fn -> %{} end)

    get = fn id, _opts ->
      case Agent.get(inventory, &Map.get(&1, id)) do
        nil -> {:error, :not_found}
        record -> {:ok, record}
      end
    end

    register = fn record, _opts ->
      Agent.update(inventory, &Map.put(&1, record.id, record))
      {:error, :session_exists}
    end

    request = %{
      "request_id" => "req-session-race",
      "task" => "Resolve the concurrent request",
      "repository" => repository,
      "auth_profile" => "codex-service"
    }

    assert {:ok, result} =
             SessionStart.start(request,
               identity_fun: fn [] -> {:ok, %{uid: 501, username: "operator"}} end,
               git_resolver: fn ^repository, "HEAD", [] -> {:ok, "abc123"} end,
               session_control: :operations,
               session_get_fun: get,
               session_register_fun: register,
               submit_fun: fn _compiled, _opts -> flunk("race loser must not submit") end,
               now: ~U[2026-08-11 12:00:00Z]
             )

    assert result.replayed
    assert result.request_id == "req-session-race"
    assert result.status == :preparing
  end

  defp temp_repository do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-session-start-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp git_repository do
    path = temp_repository()
    git!(path, ["init", "--quiet"])
    git!(path, ["config", "user.name", "Test"])
    git!(path, ["config", "user.email", "test@localhost"])
    File.write!(Path.join(path, "base.txt"), "base")
    git!(path, ["add", "base.txt"])
    git!(path, ["commit", "--quiet", "-m", "base"])
    path
  end

  defp git!(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> flunk("git failed with #{status}: #{output}")
    end
  end
end
