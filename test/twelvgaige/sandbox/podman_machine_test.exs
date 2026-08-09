defmodule Twelvgaige.Sandbox.PodmanMachineTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Sandbox.PodmanMachine

  test "bootstrap is explicit and replaces Podman's broad default mounts with declared roots" do
    root = temp_dir()

    assert {:error, :podman_machine_bootstrap_confirmation_required} =
             PodmanMachine.bootstrap(allowed_roots: [root])

    assert {:ok, plan} = PodmanMachine.bootstrap_plan(allowed_roots: [root])
    assert plan.machine_name == "twelvgaige"
    assert contiguous?(plan.init_argv, ["--cpus", "4"])
    assert contiguous?(plan.init_argv, ["--memory", "6144"])
    assert contiguous?(plan.init_argv, ["--disk-size", "64"])
    assert contiguous?(plan.init_argv, ["--volume", "#{root}:#{root}"])
    refute Enum.any?(plan.init_argv, &String.contains?(&1, "/Users:/Users"))
    assert List.last(plan.init_argv) == "twelvgaige"
  end

  test "bootstrap refuses host-wide roots" do
    assert {:error, :podman_machine_root_too_broad} =
             PodmanMachine.bootstrap_plan(allowed_roots: [System.user_home!()])
  end

  defp contiguous?(values, pair),
    do: Enum.chunk_every(values, length(pair), 1, :discard) |> Enum.member?(pair)

  defp temp_dir do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-machine-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
