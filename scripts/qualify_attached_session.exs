defmodule Twelvgaige.Qualification.AttachedSession do
  alias Twelvgaige.DelegatedSession
  alias Twelvgaige.DelegatedSession.Adapter.CodexAppServer
  alias Twelvgaige.DelegatedSession.Codex.{AuthProfile, Schema}
  alias Twelvgaige.DelegatedSession.Controller
  alias Twelvgaige.Sandbox.{Admission, LaunchManifest, Manager}
  alias Twelvgaige.Sandbox.Backend.{AppleContainer, Podman}

  @timeout_ms 300_000

  def run do
    backend_name = System.get_env("TWELVGAIGE_ATTACHED_BACKEND", "podman")
    {backend, backend_atom} = backend(backend_name)
    root = File.cwd!()
    data_root = System.get_env("TWELVGAIGE_DATA_ROOT") || default_data_root()

    auth_source =
      Path.join(
        System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"),
        "auth.json"
      )

    image = read_image!(root)
    suffix = Integer.to_string(System.system_time(:millisecond))
    resource_id = "twelvgaige-attached-#{backend_name}-#{suffix}"
    workspace = Path.join([data_root, "workspaces", "attached-session-#{suffix}"])
    credential_root = Path.join([data_root, "state", "attached-auth-#{suffix}"])

    report_path =
      Path.join([root, "qualification", "evidence", "attached-session", "#{backend_name}.json"])

    File.mkdir_p!(workspace)
    File.mkdir_p!(credential_root)
    File.chmod!(workspace, 0o700)
    File.chmod!(credential_root, 0o700)
    File.cp!(auth_source, Path.join(credential_root, "auth.json"))
    File.chmod!(Path.join(credential_root, "auth.json"), 0o600)
    initialize_repository!(workspace)

    backend_opts = backend_opts(backend_atom, data_root)
    spec = launch_spec(resource_id, workspace, credential_root, image)
    digest = manifest_digest!(backend, backend_atom, spec, backend_opts, resource_id)
    admission = start_admission!()

    {:ok, manager} =
      Manager.start_link(
        name: nil,
        admission: admission,
        backend: backend
      )

    session = session(digest, workspace)

    controller_opts = [
      session: session,
      adapter: CodexAppServer,
      adapter_config: adapter_config(),
      sandbox_manager: manager,
      sandbox_launch_spec: spec,
      sandbox_opts:
        Keyword.merge(backend_opts,
          environment: %{"CODEX_HOME" => "/run/codex-home"},
          allow_unrestricted?: true,
          timeout_ms: @timeout_ms,
          max_export_bytes: 512 * 1_024 * 1_024,
          allowed_export_roots: [Path.dirname(workspace)]
        ),
      runtime_command: [
        "/opt/codex/bin/codex",
        "app-server",
        "--stdio",
        "--strict-config"
      ],
      result_destination: workspace
    ]

    result =
      try do
        {:ok, controller} = Controller.start_link(controller_opts)
        {:ok, started} = Controller.start(controller)
        events = await_turn(controller, started.deadline, [])
        {:ok, finalized} = Controller.finalize(controller)
        GenServer.stop(controller)
        verify_result!(workspace, auth_source)
        verify_cleanup!(backend, backend_opts)
        {finalized, events}
      after
        if Process.alive?(manager), do: GenServer.stop(manager)
        if Process.alive?(admission), do: GenServer.stop(admission)
        File.rm_rf(credential_root)
      end

    {finalized, events} = result
    sync = finalized.result.runtime_quiescence.workspace_sync

    report = %{
      schema_version: 1,
      generated_at: DateTime.utc_now(),
      result: "pass",
      backend: backend_name,
      image: image,
      sandbox: %{
        runtime_identity: finalized.result.runtime_quiescence.runtime_identity,
        attached_stdio: true,
        detached_start_used: false,
        source_host_mount_visible_to_worker: false,
        outer_sandbox_authoritative: true,
        network: "explicit_unrestricted_qualification_flag"
      },
      auth: %{
        mode: "interactive_local_login_qualification_only",
        sandbox_copy: "/run/codex-home",
        persisted_in_result: false,
        source_mounted_in_worker: false
      },
      result_capture: %{
        complete_workspace_repatriated: true,
        destination: sync.destination,
        bytes: sync.bytes,
        entries: sync.entries,
        exact_file_verified: true
      },
      lifecycle: %{
        provider_initialized_inside_sandbox: true,
        turn_completed: true,
        runtime_quiescence_proven: true,
        exact_cleanup: true
      },
      events: events |> Enum.map(&Atom.to_string(&1.event_type)) |> Enum.uniq() |> Enum.sort()
    }

    File.mkdir_p!(Path.dirname(report_path))
    File.write!(report_path, Jason.encode!(report, pretty: true) <> "\n")
    IO.puts("Attached session qualification passed: #{report_path}")
  end

  defp await_turn(controller, deadline, events) do
    if DateTime.compare(DateTime.utc_now(), deadline) != :lt,
      do: raise("attached session qualification timed out")

    {:ok, polled} = Controller.poll(controller, 512)
    events = events ++ polled

    cond do
      Enum.any?(polled, &(&1.event_type == :session_failed)) ->
        raise "Codex App Server reported a failed session"

      Enum.any?(polled, &(&1.event_type == :approval_required)) ->
        raise "qualification unexpectedly required an approval"

      Enum.any?(polled, &(&1.event_type == :turn_completed)) ->
        events

      true ->
        Process.sleep(100)
        await_turn(controller, deadline, events)
    end
  end

  defp adapter_config do
    %{
      auth_profile:
        AuthProfile.new(%{
          id: "qualification-local-login",
          type: :local_user,
          revision: 1,
          codex_home: "/run/codex-home"
        }),
      mode: :interactive,
      runtime_version: Schema.cli_version(),
      objective:
        "Work only in /workspace. Create attached-session-qualified.txt containing exactly " <>
          "the single line qualified. Verify its exact contents with a shell command. " <>
          "Do not change README.md.",
      cwd: "/workspace",
      sandbox: "danger-full-access",
      sandbox_authority: :outer,
      external_network_access: "enabled",
      approval_policy: "never",
      approvals_reviewer: "user",
      ephemeral: true,
      client_opts: [
        policy_profile: :outer_authoritative,
        event_capacity: 2_048,
        critical_event_reserve: 256
      ]
    }
  end

  defp launch_spec(resource_id, workspace, credential_root, image) do
    %{
      resource_id: resource_id,
      profile: :coding_restricted,
      image_reference: image.reference,
      image_digest: image.digest,
      workspace_transport: :copy_snapshot,
      mounts: [
        %{source: workspace, destination: "/workspace", mode: :read_write},
        %{source: credential_root, destination: "/run/codex-home", mode: :read_write}
      ],
      network_mode: :unrestricted,
      allowed_destinations: [],
      limits: %{cpu: 2, memory_bytes: 2 * 1_073_741_824, pids: 128},
      deadline: DateTime.add(DateTime.utc_now(), @timeout_ms, :millisecond),
      credential_lease_id: nil,
      policy_revision: "attached-session-qualification-v1",
      environment_names: ["CODEX_HOME"],
      created_at: DateTime.utc_now(),
      reservation: %{
        sandboxes: 1,
        cpu: 2,
        memory_bytes: 2 * 1_073_741_824,
        pids: 128,
        workspace_bytes: 512 * 1_024 * 1_024,
        artifact_bytes: 64 * 1_024 * 1_024,
        provider_tokens: 80_000
      }
    }
  end

  defp session(digest, workspace) do
    now = DateTime.utc_now()

    DelegatedSession.new(%{
      id: "session-attached-qualification",
      round_id: "round-attached-qualification",
      shot_id: "shot-attached-qualification",
      attempt: 0,
      runtime: :codex,
      driver: :codex_app_server_v2,
      runtime_version: Schema.cli_version(),
      integration_descriptor_id: "codex-app-server",
      workspace_id: Path.basename(workspace),
      base_commit: git!(workspace, ["rev-parse", "HEAD"]),
      auth_profile_id: "qualification-local-login",
      auth_revision: 1,
      sandbox_profile: :coding_restricted,
      sandbox_manifest_digest: digest,
      policy_revision: "attached-session-qualification-v1",
      budgets: %{tokens: 80_000, cost_micros: 0, time_ms: @timeout_ms, tool_calls: 1_000},
      deadline: DateTime.add(now, @timeout_ms, :millisecond),
      created_at: now
    })
  end

  defp manifest_digest!(backend, backend_atom, spec, opts, resource_id) do
    {:ok, prepared} = backend.prepare(Map.delete(spec, :reservation), opts)

    bound =
      case backend_atom do
        :podman ->
          LaunchManifest.bind_resource(prepared, resource_id)

        :apple_container ->
          LaunchManifest.bind_resource(prepared, resource_id, machine_id: resource_id)
      end

    bound.manifest_digest
  end

  defp start_admission! do
    {:ok, admission} =
      Admission.start_link(
        name: nil,
        limits: [
          sandboxes: 1,
          cpu: 2,
          memory_bytes: 2 * 1_073_741_824,
          pids: 128,
          workspace_bytes: 512 * 1_024 * 1_024,
          artifact_bytes: 64 * 1_024 * 1_024,
          provider_tokens: 80_000
        ]
      )

    admission
  end

  defp verify_result!(workspace, auth_source) do
    result = Path.join(workspace, "attached-session-qualified.txt")
    if File.read!(result) != "qualified\n", do: raise("attached result contents were not exact")

    if File.exists?(Path.join(workspace, "deleted.txt")),
      do: raise("deleted runtime file survived")

    secrets =
      auth_source
      |> File.read!()
      |> Jason.decode!()
      |> strings()
      |> Enum.filter(&(byte_size(&1) >= 12))

    leaked? =
      workspace
      |> files()
      |> Enum.any?(fn path ->
        case File.read(path) do
          {:ok, contents} -> Enum.any?(secrets, &String.contains?(contents, &1))
          {:error, _reason} -> false
        end
      end)

    if leaked?, do: raise("credential material appeared in the captured workspace")
  end

  defp verify_cleanup!(Podman, opts) do
    {:ok, resources} = Podman.managed_resources(opts)
    if resources != [], do: raise("managed Podman resources remain: #{inspect(resources)}")
  end

  defp verify_cleanup!(AppleContainer, opts) do
    {:ok, resources} = AppleContainer.managed_resources(opts)

    if resources != [],
      do: raise("managed Apple container resources remain: #{inspect(resources)}")
  end

  defp initialize_repository!(workspace) do
    git!(workspace, ["init", "--quiet"])
    git!(workspace, ["config", "user.name", "Twelvgaige Qualification"])
    git!(workspace, ["config", "user.email", "qualification@localhost"])
    File.write!(Path.join(workspace, "README.md"), "Attached session qualification\n")
    git!(workspace, ["add", "README.md"])
    git!(workspace, ["commit", "--quiet", "-m", "Initialize attached session fixture"])
  end

  defp git!(directory, args) do
    case System.cmd("git", ["-C", directory | args], stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, status} -> raise "git failed with #{status}: #{output}"
    end
  end

  defp read_image!(root) do
    catalog =
      root
      |> Path.join("qualification/evidence/podman-worker/catalog.json")
      |> File.read!()
      |> Jason.decode!()

    image = catalog |> Map.fetch!("images") |> List.first()
    %{reference: image["reference"], digest: image["digest"]}
  end

  defp backend("podman"), do: {Podman, :podman}
  defp backend("apple-container"), do: {AppleContainer, :apple_container}
  defp backend(other), do: raise("unsupported attached qualification backend #{inspect(other)}")

  defp backend_opts(:podman, data_root),
    do: [
      allowed_roots: [data_root],
      machine_name: System.get_env("TWELVGAIGE_PODMAN_MACHINE", "twelvgaige")
    ]

  defp backend_opts(:apple_container, data_root), do: [allowed_roots: [data_root]]

  defp default_data_root,
    do: Path.join([System.user_home!(), "Library", "Application Support", "Twelvgaige"])

  defp strings(value) when is_binary(value), do: [value]
  defp strings(value) when is_list(value), do: Enum.flat_map(value, &strings/1)
  defp strings(value) when is_map(value), do: value |> Map.values() |> Enum.flat_map(&strings/1)
  defp strings(_value), do: []

  defp files(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} ->
        [path]

      {:ok, %{type: :directory}} ->
        path |> File.ls!() |> Enum.flat_map(&files(Path.join(path, &1)))

      _other ->
        []
    end
  end
end

Twelvgaige.Qualification.AttachedSession.run()
