defmodule Twelvgaige.Manager.VerificationExecutorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.VerificationExecutor

  defmodule Backend do
    def prepare(spec, opts) do
      send(opts[:test_pid], {:prepared, spec, opts})
      {:ok, Map.put(spec, :backend, :test_backend)}
    end

    def create(manifest, opts) do
      Process.put({__MODULE__, :command}, opts[:command])
      send(opts[:test_pid], {:created, manifest, opts[:command]})
      {:ok, "sandbox-verification", %{manifest: manifest}}
    end

    def start(resource_id, opts) do
      send(opts[:test_pid], {:started, resource_id})
      {:ok, %{resource_id: resource_id}}
    end

    def await(resource_id, opts) do
      send(opts[:test_pid], {:awaited, resource_id})
      {:ok, %{status: :stopped, exit_status: 0}}
    end

    def logs(resource_id, opts) do
      ["/bin/sh", "-c", script] = Process.get({__MODULE__, :command})

      [marker] =
        Regex.run(~r/(__TWELVGAIGE_VERIFY_[A-Za-z0-9_-]+)_done/, script, capture: :all_but_first)

      command_lines =
        0..(opts[:verification_command_count] - 1)
        |> Enum.map_join("\n", &"#{marker}_#{&1}=0")

      send(opts[:test_pid], {:logs, resource_id})
      {:ok, command_lines <> "\n#{marker}_done=0\n"}
    end

    def destroy(resource_id, opts) do
      send(opts[:test_pid], {:destroyed, resource_id})
      :ok
    end
  end

  test "runs every command in an attested copy-only networkless sandbox and destroys it" do
    root = temp_dir("verification-executor")
    source = Path.join(root, "workspace")
    File.mkdir_p!(source)

    request = request(source)

    assert {:ok, evidence} = VerificationExecutor.execute(request, options(root))
    assert evidence.request_digest == request.request_digest
    assert evidence.backend == :test_backend
    assert evidence.network_mode == :none
    assert evidence.credentials_present == false
    assert evidence.provider_environment_present == false
    assert evidence.workspace_copy

    assert evidence.commands == [
             %{argv: ["mix", "test"], exit_status: 0},
             %{argv: ["mix", "format", "--check-formatted"], exit_status: 0}
           ]

    assert_receive {:prepared, spec, backend_opts}
    assert spec.workspace_transport == :copy_snapshot
    assert spec.network_mode == :none
    assert spec.credential_lease_id == nil
    assert spec.environment_names == []
    assert [%{source: ^source, destination: "/workspace", mode: :read_write}] = spec.mounts
    assert backend_opts[:allowed_roots] == [root]

    assert_receive {:created, _manifest, ["/bin/sh", "-c", script]}
    assert script =~ "'mix' 'test'"
    assert script =~ "'mix' 'format' '--check-formatted'"
    assert_receive {:started, "sandbox-verification"}
    assert_receive {:awaited, "sandbox-verification"}
    assert_receive {:logs, "sandbox-verification"}
    assert_receive {:destroyed, "sandbox-verification"}
  end

  test "fails closed before backend preparation when the source is outside managed roots" do
    root = temp_dir("verification-executor-root")
    outside = temp_dir("verification-executor-outside")

    assert {:error, :verification_source_outside_allowed_roots} =
             VerificationExecutor.execute(request(outside), options(root))

    refute_receive {:prepared, _spec, _opts}
  end

  test "builds an executor only from a complete digest-pinned configuration" do
    root = temp_dir("verification-executor-builder")
    assert is_function(VerificationExecutor.from_options(options(root)), 1)
    assert VerificationExecutor.from_options([]) == nil
  end

  defp request(source) do
    %{
      workspace_id: "ws_verification",
      source_path: source,
      workspace_copy: true,
      network_mode: :none,
      credential_lease_id: nil,
      provider_environment: false,
      environment_names: [],
      commands: [["mix", "test"], ["mix", "format", "--check-formatted"]],
      timeout_ms: 60_000,
      request_digest: "sha256:" <> String.duplicate("a", 64)
    }
  end

  defp options(root) do
    [
      backend: Backend,
      image_reference: "localhost/twelvgaige/worker:test",
      image_digest: "sha256:" <> String.duplicate("b", 64),
      allowed_roots: [root],
      backend_opts: [test_pid: self()]
    ]
  end

  defp temp_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
