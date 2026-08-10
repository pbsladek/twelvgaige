defmodule Twelvgaige.Sandbox.Onboarding do
  @moduledoc """
  Idempotent, single-user onboarding for supported macOS sandbox backends.

  Setup reuses the pinned worker build scripts in the source distribution. It
  never changes an existing Podman machine configuration and never falls back
  from the selected backend. `check/2` is the read-only counterpart.
  """

  alias Twelvgaige.Operations.{LocalIdentity, Paths}
  alias Twelvgaige.Sandbox.Backend.AppleContainer
  alias Twelvgaige.Sandbox.PodmanMachine
  alias Twelvgaige.Tool.CommandRunner

  @backends [:podman, :apple_container]
  @default_timeout_ms 30 * 60 * 1_000

  @spec setup(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def setup(selection, opts \\ []) do
    backend = concrete_backend(selection)

    with :ok <- supported_backend(backend),
         :ok <- require_macos(opts),
         {:ok, source_root} <- source_root(opts),
         {:ok, data_root} <- prepare_data_root(opts),
         {:ok, steps} <- run_setup(backend, source_root, data_root, opts),
         {:ok, health} <- health(backend, data_root, opts) do
      {:ok,
       %{
         status: :ready,
         backend: backend,
         data_root: data_root,
         source_root: source_root,
         image: Keyword.get(opts, :worker_image),
         steps: steps,
         health: health
       }}
    end
  end

  @spec check(atom(), keyword()) :: {:ok, map()} | {:error, term()}
  def check(selection, opts \\ []) do
    backend = concrete_backend(selection)
    data_root = Paths.data_root(opts)

    with :ok <- supported_backend(backend),
         :ok <- require_macos(opts),
         {:ok, health} <- health(backend, data_root, opts) do
      {:ok, %{status: :ready, backend: backend, data_root: data_root, health: health}}
    end
  end

  defp run_setup(:podman, source_root, data_root, opts) do
    with {:ok, machine} <- run_machine_setup(source_root, data_root, opts),
         {:ok, image} <- run_worker_build(source_root, data_root, opts) do
      {:ok, [machine, image]}
    end
  end

  defp run_setup(:apple_container, source_root, data_root, opts) do
    with {:ok, service} <- start_apple_service(opts),
         {:ok, machine} <- run_machine_setup(source_root, data_root, opts),
         {:ok, image} <- run_worker_build(source_root, data_root, opts),
         {:ok, archive} <- export_worker(source_root, data_root, opts),
         {:ok, imported} <- import_worker_archive(source_root, opts) do
      {:ok, [service, machine, image, archive, imported]}
    end
  end

  defp run_machine_setup(source_root, data_root, opts) do
    env = common_env(data_root, opts) ++ [{"TWELVGAIGE_PODMAN_CONFIRM", "1"}]

    run_script(source_root, "podman_machine.sh", ["create"], env, opts)
    |> step(:podman_machine)
  end

  defp run_worker_build(source_root, data_root, opts) do
    action = if Keyword.get(opts, :qualify_image?, false), do: "qualify-image", else: "build"

    run_script(source_root, "podman_worker.sh", [action], common_env(data_root, opts), opts)
    |> step(if(action == "build", do: :worker_image_built, else: :worker_image_qualified))
  end

  defp export_worker(source_root, data_root, opts) do
    run_script(
      source_root,
      "podman_worker.sh",
      ["export-oci"],
      common_env(data_root, opts),
      opts
    )
    |> step(:worker_image_exported)
  end

  defp start_apple_service(opts) do
    starter = Keyword.get(opts, :apple_service_fun, &AppleContainer.ensure_system_started/1)

    case starter.(opts) do
      {:ok, result} -> {:ok, %{name: :apple_container_service, output: output(result)}}
      {:error, reason} -> {:error, {:apple_container_service_start_failed, reason}}
    end
  end

  defp import_worker_archive(source_root, opts) do
    archive =
      Keyword.get(
        opts,
        :worker_archive,
        Path.join(source_root, "artifacts/qualification/podman-worker/worker.oci.tar")
      )

    if File.regular?(archive) or Keyword.has_key?(opts, :command_runner) do
      importer = Keyword.get(opts, :apple_image_load_fun, &AppleContainer.load_image/2)

      case importer.(archive, opts) do
        {:ok, result} -> {:ok, %{name: :worker_image_imported, output: output(result)}}
        {:error, reason} -> {:error, {:apple_container_image_import_failed, reason}}
      end
    else
      {:error, {:worker_oci_archive_missing, archive}}
    end
  end

  defp health(:podman, data_root, opts) do
    case Keyword.get(opts, :health_fun) do
      fun when is_function(fun, 2) -> fun.(:podman, health_opts(data_root, opts))
      nil -> PodmanMachine.health(health_opts(data_root, opts))
    end
  end

  defp health(:apple_container, data_root, opts) do
    case Keyword.get(opts, :health_fun) do
      fun when is_function(fun, 2) -> fun.(:apple_container, health_opts(data_root, opts))
      nil -> AppleContainer.probe(health_opts(data_root, opts))
    end
  end

  defp health_opts(data_root, opts) do
    [
      allowed_roots: [data_root],
      machine_allowed_mounts: [data_root],
      machine_name: Keyword.get(opts, :machine_name, "twelvgaige"),
      command_runner: Keyword.get(opts, :command_runner, &CommandRunner.run/3),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    ]
  end

  defp prepare_data_root(opts) do
    identity_fun = Keyword.get(opts, :identity_fun, &LocalIdentity.current/1)

    with {:ok, identity} <- identity_fun.([]),
         {:ok, prepared} <- Paths.prepare(Keyword.put(opts, :owner_uid, identity.uid)),
         :ok <- prepare_extra_directories(prepared.data_root) do
      {:ok, prepared.data_root}
    end
  end

  defp prepare_extra_directories(root) do
    ["cache", "integrations", "state", "tools"]
    |> Enum.reduce_while(:ok, fn name, :ok ->
      path = Path.join(root, name)

      with :ok <- File.mkdir_p(path), :ok <- File.chmod(path, 0o700) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:sandbox_data_root_prepare_failed, reason}}}
      end
    end)
  end

  defp source_root(opts) do
    root = opts |> Keyword.get(:source_root, File.cwd!()) |> Path.expand()

    if File.regular?(Path.join(root, "scripts/podman_machine.sh")) and
         File.regular?(Path.join(root, "scripts/podman_worker.sh")),
       do: {:ok, root},
       else: {:error, {:sandbox_source_distribution_required, root}}
  end

  defp run_script(source_root, name, args, env, opts) do
    run_command(
      Path.join(source_root, "scripts/#{name}"),
      args,
      Keyword.merge(opts, cwd: source_root, env: env, require_absolute_binary?: true)
    )
  end

  defp run_command(binary, args, opts) do
    runner = Keyword.get(opts, :command_runner, &CommandRunner.run/3)

    command_opts = [
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      cwd: Keyword.get(opts, :cwd),
      env: Keyword.get(opts, :env, []),
      require_absolute_binary?: Keyword.get(opts, :require_absolute_binary?, false),
      scrub_env?: true
    ]

    case runner.(binary, args, command_opts) do
      {:ok, %{status: 0} = result} -> {:ok, result}
      {:ok, %{status: status} = result} -> {:error, %{status: status, output: output(result)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp common_env(data_root, opts) do
    [
      {"TWELVGAIGE_DATA_ROOT", data_root},
      {"TWELVGAIGE_PODMAN_MACHINE", Keyword.get(opts, :machine_name, "twelvgaige")},
      {"TWELVGAIGE_PODMAN_CPUS", to_string(Keyword.get(opts, :cpus, 4))},
      {"TWELVGAIGE_PODMAN_MEMORY_MIB", to_string(Keyword.get(opts, :memory_mib, 6144))},
      {"TWELVGAIGE_PODMAN_DISK_GIB", to_string(Keyword.get(opts, :disk_size_gib, 64))},
      {"TWELVGAIGE_WORKER_IMAGE", Keyword.get(opts, :worker_image)}
    ]
    |> Enum.reject(fn {_name, value} -> is_nil(value) end)
  end

  defp step({:ok, result}, name), do: {:ok, %{name: name, output: output(result)}}
  defp step({:error, reason}, name), do: {:error, {:sandbox_setup_step_failed, name, reason}}

  defp output(result) when is_binary(result), do: String.trim(result)

  defp output(result) when is_map(result) do
    result
    |> Map.get(:stdout, Map.get(result, :output, ""))
    |> String.trim()
  end

  defp require_macos(opts) do
    if Keyword.get(opts, :os_type, :os.type()) == {:unix, :darwin},
      do: :ok,
      else: {:error, :sandbox_setup_requires_macos}
  end

  defp concrete_backend(:auto), do: :podman
  defp concrete_backend(backend), do: backend
  defp supported_backend(backend) when backend in @backends, do: :ok
  defp supported_backend(backend), do: {:error, {:sandbox_backend_invalid, backend}}
end
