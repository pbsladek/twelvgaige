defmodule Twelvgaige.Manager.CompilerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.{Approval, Compiler, Envelope}

  test "compiles registered children within the inherited authority and aggregate budget" do
    assert {:ok, compiled} = Compiler.compile(plan(), compiler_opts())
    assert compiled.approval_status == :within_envelope
    assert compiled.reserved_budget.tokens == 20_000
    assert Enum.map(compiled.tasks, & &1.repository) == ["repo", "repo"]
    assert Enum.all?(compiled.tasks, &(&1.auth_profile_id == "provider-api"))
  end

  test "rejects unregistered agents, workflows, repositories, credentials, mounts, and capabilities" do
    fields = [
      {:agent, "unknown"},
      {:workflow, "unknown"},
      {:repository, "unknown"},
      {:auth_profile_id, "unknown"},
      {:sandbox_profile, :unknown},
      {:network_mode, :unknown},
      {:capabilities, [:unknown]},
      {:mounts, ["unknown"]}
    ]

    for {field, value} <- fields do
      changed =
        update_in(plan().tasks, fn [first, second] -> [Map.put(first, field, value), second] end)

      assert {:error, {:manager_unregistered_authority, failures}} =
               Compiler.compile(changed, compiler_opts())

      assert failures != []
    end
  end

  test "requires an exact independent approval for authority expansion" do
    key = :crypto.strong_rand_bytes(32)
    expanded = update_first(plan(), &Map.put(&1, :external_effects, ["git.push"]))
    opts = Keyword.put(compiler_opts(), :approval_signing_key, key)

    assert {:error, {:manager_approval_required, reasons, intent}} =
             Compiler.compile(expanded, opts)

    assert {"api", :external_effects, ["git.push"]} in reasons

    self_receipt = Approval.receipt(intent, "manager-agent", key)

    assert {:error, :manager_cannot_self_approve} =
             Compiler.compile(
               expanded,
               opts ++ [approval_intent: intent, approval_receipt: self_receipt]
             )

    receipt = Approval.receipt(intent, "local-user", key)

    assert {:ok, %{approval_status: :independently_approved}} =
             Compiler.compile(
               expanded,
               opts ++ [approval_intent: intent, approval_receipt: receipt]
             )

    tampered = update_first(expanded, &Map.put(&1, :external_effects, ["deploy.production"]))

    assert {:error, :manager_approval_scope_mismatch} =
             Compiler.compile(
               tampered,
               opts ++ [approval_intent: intent, approval_receipt: receipt]
             )
  end

  test "enforces DAG, tree, deadline, and aggregate budget limits" do
    nested =
      plan()
      |> Map.put(:max_depth, 2)
      |> update_in([:tasks, Access.at(1)], fn task ->
        task |> Map.put(:parent_task_id, "api") |> Map.put(:depth, 2)
      end)

    assert {:ok, compiled_nested} = Compiler.compile(nested, compiler_opts(2))
    assert Enum.find(compiled_nested.tasks, &(&1.id == "verify")).depth == 2

    cyclic =
      plan()
      |> update_in([:tasks, Access.at(0)], &Map.put(&1, :depends_on, ["verify"]))
      |> update_in([:tasks, Access.at(1)], &Map.put(&1, :depends_on, ["api"]))

    assert {:error, :manager_dependency_cycle} = Compiler.compile(cyclic, compiler_opts())

    over_budget =
      update_first(plan(), fn task -> put_in(task, [:budget, :tokens], 99_999) end)

    assert {:error, {:manager_aggregate_budget_exceeded, [:tokens]}} =
             Compiler.compile(over_budget, compiler_opts())

    too_deep =
      plan()
      |> update_in([:tasks, Access.at(1)], fn task ->
        task |> Map.put(:parent_task_id, "api") |> Map.put(:depth, 2)
      end)

    assert {:error, {:manager_depth_exceeded, ["verify"]}} =
             Compiler.compile(too_deep, compiler_opts())

    unknown_parent = update_first(plan(), &Map.put(&1, :parent_task_id, "missing"))

    assert {:error, {:manager_parent_unknown, "api", "missing"}} =
             Compiler.compile(unknown_parent, compiler_opts())

    parent_cycle =
      plan()
      |> update_in([:tasks, Access.at(0)], &Map.put(&1, :parent_task_id, "verify"))
      |> update_in([:tasks, Access.at(1)], &Map.put(&1, :parent_task_id, "api"))

    assert {:error, :manager_parent_cycle} = Compiler.compile(parent_cycle, compiler_opts())

    too_late = update_first(plan(), &Map.put(&1, :deadline, DateTime.add(deadline(), 1)))

    assert {:error, {:manager_deadline_exceeded, ["api"]}} =
             Compiler.compile(too_late, compiler_opts())
  end

  defp plan do
    %{
      id: "manager-plan",
      manager_principal: "manager-agent",
      manager_session_id: "session-parent",
      round_id: "round-parent",
      shot_id: "shot-parent",
      repository: "repo",
      base_ref: "main",
      auth_profile_id: "provider-api",
      sandbox_profile: :coding_restricted,
      network_mode: :broker_only,
      capabilities: ["filesystem.write", "mcp.write"],
      allowed_paths: ["lib", "test"],
      budget: plan_budget(),
      deadline: deadline(),
      max_depth: 1,
      max_children: 2,
      max_fanout: 2,
      tasks: [
        %{
          id: "api",
          agent: "codex",
          workflow: "coding.change.v1",
          objective: "Implement API",
          allowed_paths: ["lib/api"],
          capabilities: ["filesystem.write", "mcp.write"],
          mounts: [],
          budget: budget(15_000)
        },
        %{
          id: "verify",
          agent: "codex",
          workflow: "coding.verify.v1",
          objective: "Verify API",
          role: :verifier,
          write: false,
          allowed_paths: ["test"],
          capabilities: [],
          mounts: [],
          depends_on: ["api"],
          budget: budget(5_000)
        }
      ]
    }
  end

  defp compiler_opts do
    compiler_opts(1)
  end

  defp compiler_opts(max_depth) do
    {:ok, envelope} =
      Envelope.new(%{
        repositories: ["repo"],
        agents: ["codex"],
        workflows: ["coding.change.v1", "coding.verify.v1"],
        auth_profiles: ["provider-api"],
        sandbox_profiles: [:coding_restricted],
        network_modes: [:broker_only],
        capabilities: ["filesystem.write", "mcp.write"],
        mounts: [],
        allowed_paths: ["lib", "test"],
        budget: plan_budget(),
        deadline: deadline(),
        max_depth: max_depth,
        max_children: 2,
        max_fanout: 2
      })

    [
      parent_envelope: envelope,
      catalog: %{
        repositories: ["repo"],
        agents: ["codex"],
        workflows: ["coding.change.v1", "coding.verify.v1"],
        auth_profiles: ["provider-api"],
        sandbox_profiles: [:coding_restricted],
        network_modes: [:broker_only],
        capabilities: ["filesystem.write", "mcp.write"],
        mounts: []
      }
    ]
  end

  defp budget(tokens),
    do: %{tokens: tokens, cost_micros: 1_000_000, time: "30m", tool_calls: 100}

  defp plan_budget,
    do: %{tokens: 25_000, cost_micros: 3_000_000, time: "90m", tool_calls: 300}

  defp deadline, do: DateTime.from_iso8601("2026-08-03T00:00:00Z") |> elem(1)

  defp update_first(plan, updater) do
    update_in(plan, [:tasks], fn [first | rest] -> [updater.(first) | rest] end)
  end
end
