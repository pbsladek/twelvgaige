defmodule Twelvgaige.Manager.SessionStartTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.SessionStart

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
end
