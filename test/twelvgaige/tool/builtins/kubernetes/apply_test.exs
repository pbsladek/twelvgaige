defmodule Twelvgaige.Tool.Builtins.Kubernetes.ApplyTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Tool.Builtins.Kubernetes.Apply
  alias Twelvgaige.Tool.Executor

  test "builds structured apply argv for a trusted manifest file" do
    root = tmp_dir!()
    manifest = Path.join(root, "deploy.yaml")
    File.write!(manifest, "apiVersion: apps/v1\nkind: Deployment\n")

    runner = fn binary, args, opts ->
      send(self(), {:runner, binary, args, opts})
      {:ok, %{status: 0, stdout: "deployment.apps/api configured\n", stderr: "", duration_ms: 8}}
    end

    assert {:ok, output} =
             Apply.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "payments",
                 "path" => "deploy.yaml",
                 "confirm" => true
               },
               root: root,
               command_runner: runner
             )

    assert_receive {:runner, "kubectl",
                    [
                      "--context",
                      "kind-dev",
                      "-n",
                      "payments",
                      "apply",
                      "-f",
                      ^manifest
                    ], [timeout_ms: 30_000]}

    assert output["verb"] == "apply"
    assert output["manifest_path"] == "deploy.yaml"
    assert output["text_excerpt"] =~ "configured"
  end

  test "requires confirmation and idempotent-write executor safety" do
    root = tmp_dir!()
    File.write!(Path.join(root, "deploy.yaml"), "kind: ConfigMap\n")

    input = %{
      "context" => "kind-dev",
      "namespace" => "payments",
      "path" => "deploy.yaml",
      "confirm" => true
    }

    runner = fn _binary, _args, _opts ->
      {:ok, %{status: 0, stdout: "configured\n", stderr: "", duration_ms: 1}}
    end

    assert {:error, confirmation} =
             Apply.execute(
               %{"context" => "kind-dev", "namespace" => "payments", "path" => "deploy.yaml"},
               root: root,
               command_runner: runner
             )

    assert confirmation.class == :policy_error
    assert confirmation.reason == :policy_denied

    assert {:error, policy} =
             Executor.execute("kubectl_apply", input,
               allowed_tools: ["kubectl_apply"],
               max_safety: :read_only,
               limiter: nil,
               tool_opts: [root: root, command_runner: runner]
             )

    assert policy.class == :policy_error
    assert policy.reason == :policy_denied

    assert {:ok, %{"verb" => "apply"}} =
             Executor.execute("kubectl_apply", input,
               allowed_tools: ["kubectl_apply"],
               max_safety: :idempotent_write,
               limiter: nil,
               tool_opts: [root: root, command_runner: runner]
             )
  end

  test "denies root escapes, non-manifest extensions, directories, and symlinks" do
    root = tmp_dir!()
    File.mkdir_p!(Path.join(root, "dir"))
    File.write!(Path.join(root, "deploy.yaml"), "kind: ConfigMap\n")
    File.write!(Path.join(root, "note.txt"), "not a manifest\n")

    outside_root = tmp_dir!()
    outside = Path.join(outside_root, "outside.yaml")
    File.write!(outside, "kind: ConfigMap\n")

    symlink = Path.join(root, "linked.yaml")
    File.ln_s!(Path.join(root, "deploy.yaml"), symlink)

    base_input = %{"context" => "kind-dev", "namespace" => "payments", "confirm" => true}

    assert {:error, escape} =
             Apply.execute(Map.put(base_input, "path", outside),
               root: root,
               command_runner: unused_runner()
             )

    assert escape.reason == :tool_denied

    assert {:error, extension} =
             Apply.execute(Map.put(base_input, "path", "note.txt"),
               root: root,
               command_runner: unused_runner()
             )

    assert extension.reason == :tool_input_invalid

    assert {:error, directory} =
             Apply.execute(Map.put(base_input, "path", "dir"),
               root: root,
               command_runner: unused_runner()
             )

    assert directory.reason == :tool_input_invalid

    assert {:error, symlink_error} =
             Apply.execute(Map.put(base_input, "path", "linked.yaml"),
               root: root,
               command_runner: unused_runner()
             )

    assert symlink_error.reason == :tool_denied
  end

  test "redacts bounded kubectl apply output" do
    root = tmp_dir!()
    File.write!(Path.join(root, "deploy.yaml"), "kind: ConfigMap\n")

    runner = fn _binary, _args, _opts ->
      {:ok, %{status: 0, stdout: "configured token=secret\n", stderr: "", duration_ms: 1}}
    end

    assert {:ok, output} =
             Apply.execute(
               %{
                 "context" => "kind-dev",
                 "namespace" => "payments",
                 "path" => "deploy.yaml",
                 "confirm" => true
               },
               root: root,
               command_runner: runner
             )

    assert output["text_excerpt"] =~ "token=[REDACTED]"
  end

  defp unused_runner do
    fn _binary, _args, _opts -> flunk("kubectl should not run") end
  end

  defp tmp_dir! do
    root = Path.join(System.tmp_dir!(), "twelvgaige_apply_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    root
  end
end
