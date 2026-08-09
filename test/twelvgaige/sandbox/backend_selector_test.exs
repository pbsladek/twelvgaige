defmodule Twelvgaige.Sandbox.BackendSelectorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Sandbox.Backend.Podman
  alias Twelvgaige.Sandbox.BackendSelector

  test "auto is Podman-authoritative and never falls back" do
    runner = fn _binary, _args, _opts ->
      {:error, :not_installed}
    end

    assert {:error, {:sandbox_backend_unavailable, :podman, _reason}} =
             BackendSelector.resolve(:auto, command_runner: runner)

    refute_received {:apple_fallback, _anything}
  end

  test "returns the explicitly selected ready backend" do
    runner = fn _binary, args, _opts ->
      output =
        case Enum.take(args, 2) do
          ["version", "--format"] -> Jason.encode!(%{"Client" => %{"Version" => "5.8.1"}})
          ["machine", "inspect"] -> Jason.encode!([%{"Name" => "twelvgaige"}])
          ["machine", "ssh"] -> Jason.encode!(%{"filesystems" => []})
        end

      {:ok, %{status: 0, stdout: output, stderr: "", duration_ms: 1}}
    end

    assert {:ok, Podman, %{backend: :podman}} =
             BackendSelector.resolve(:podman, command_runner: runner)
  end
end
