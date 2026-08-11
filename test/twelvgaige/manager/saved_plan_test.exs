defmodule Twelvgaige.Manager.SavedPlanTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.SavedPlan

  test "builds and verifies a canonical digest-bound plan" do
    assert {:ok, plan} = SavedPlan.build(request(), resolution())
    assert plan["schema"] == "twelvgaige.session-plan"
    assert plan["schema_version"] == 1
    assert plan["plan_digest"] =~ "sha256:"
    assert plan["request"]["task"] == "Do not print this task"
    assert {:ok, ^plan} = SavedPlan.verify(plan)

    reordered = plan |> Enum.reverse() |> Map.new()
    assert {:ok, ^reordered} = SavedPlan.verify(reordered)
  end

  test "rejects tampering and reports drift by field without returning values" do
    assert {:ok, plan} = SavedPlan.build(request(), resolution())

    tampered = put_in(plan, ["request", "task"], "changed secret task")
    assert {:error, :session_saved_plan_digest_mismatch} = SavedPlan.verify(tampered)

    assert {:error, {:session_saved_plan_drift, "request.task"}} =
             SavedPlan.validate_request(plan, %{request() | "task" => "changed secret task"})

    assert {:error, {:session_saved_plan_drift, "source_state_token"}} =
             SavedPlan.validate_resolution(plan, %{
               resolution()
               | source_state_token: "sha256:changed-secret-token"
             })
  end

  test "names every independently changed request and resolution field" do
    assert {:ok, plan} = SavedPlan.build(request(), resolution())

    Enum.each(request(), fn {field, original} ->
      changed = Map.put(request(), field, changed_value(original))
      expected_field = "request.#{field}"

      assert {:error, {:session_saved_plan_drift, ^expected_field}} =
               SavedPlan.validate_request(plan, changed)
    end)

    Enum.each(resolution(), fn {field, original} ->
      changed = Map.put(resolution(), field, changed_value(original))
      expected_field = Atom.to_string(field)

      assert {:error, {:session_saved_plan_drift, ^expected_field}} =
               SavedPlan.validate_resolution(plan, changed)
    end)
  end

  test "saves owner-only, loads without following symlinks, and never overwrites" do
    root = temp_dir()
    path = Path.join(root, "plan.json")
    link = Path.join(root, "plan-link.json")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, plan} = SavedPlan.build(request(), resolution())
    assert :ok = SavedPlan.save(path, plan)

    assert {:ok, stat} = File.lstat(path)
    assert stat.type == :regular
    assert Bitwise.band(stat.mode, 0o777) == 0o600
    assert {:ok, ^plan} = SavedPlan.load(path)

    assert {:error, :session_saved_plan_destination_exists} = SavedPlan.save(path, plan)
    assert {:ok, ^plan} = SavedPlan.load(path)

    assert :ok = File.ln_s(path, link)
    assert {:error, :session_saved_plan_type_invalid} = SavedPlan.load(link)
  end

  test "refuses plans readable by another local account" do
    root = temp_dir()
    path = Path.join(root, "plan.json")
    on_exit(fn -> File.rm_rf(root) end)

    assert {:ok, plan} = SavedPlan.build(request(), resolution())
    assert :ok = SavedPlan.save(path, plan)
    assert :ok = File.chmod(path, 0o640)

    assert {:error, :session_saved_plan_permissions_invalid} = SavedPlan.load(path)
  end

  defp request do
    %{
      "request_id" => "req-plan",
      "runtime" => "codex",
      "repository" => "/tmp/example",
      "base_ref" => "HEAD",
      "task" => "Do not print this task",
      "auth_profile" => "codex-service",
      "sandbox" => "podman",
      "network" => "broker-only",
      "allow_unrestricted_network" => false,
      "allowed_paths" => ["lib", "test"],
      "source_mode" => "committed",
      "include_untracked" => false,
      "include_ignored" => false,
      "write" => true,
      "timeout_ms" => 2_700_000,
      "profile" => "default",
      "budget" => %{
        "tokens" => 80_000,
        "cost_micros" => 25_000_000,
        "time_ms" => 2_700_000,
        "tool_calls" => 1_000
      },
      "provenance" => %{"task" => "task_document"}
    }
  end

  defp resolution do
    %{
      repository: "/tmp/example",
      base_ref: "HEAD",
      base_commit: String.duplicate("a", 40),
      source_mode: "committed",
      source_state_token: "sha256:source",
      sandbox: "podman",
      sandbox_profile: "coding_restricted:podman",
      network: "broker_only",
      allowed_paths: ["lib", "test"],
      write: true,
      capabilities: ["filesystem.write"],
      configuration_provenance: %{"task" => "task_document"}
    }
  end

  defp temp_dir do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-saved-plan-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(path)
    path
  end

  defp changed_value(value) when is_boolean(value), do: not value
  defp changed_value(value) when is_integer(value), do: value + 1
  defp changed_value(value) when is_binary(value), do: value <> "-changed"
  defp changed_value(value) when is_list(value), do: value ++ ["changed"]
  defp changed_value(value) when is_map(value), do: Map.put(value, "changed", true)
  defp changed_value(nil), do: "changed"
end
