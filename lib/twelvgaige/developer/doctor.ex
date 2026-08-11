defmodule Twelvgaige.Developer.Doctor do
  @moduledoc "Actionable project, runtime, and sandbox readiness checks."

  alias Twelvgaige.Developer.{Config, Init}
  alias Twelvgaige.Breech.IPC.Protocol
  alias Twelvgaige.Integration.Codex
  alias Twelvgaige.Operations.Paths
  alias Twelvgaige.Sandbox.Onboarding
  alias Twelvgaige.Workspace.Git.SourceRead, as: Git
  alias Twelvgaige.Workspace.Storage

  @disk_warning_bytes 4 * 1_024 * 1_024 * 1_024

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    root = Config.project_root(opts)
    config_path = Config.project_config_path(root)
    fix? = Keyword.get(opts, :fix?, false)

    with {:ok, fixes} <- maybe_fix_config(config_path, root, fix?, opts),
         {:ok, profile} <- resolve_profile(opts),
         {:ok, sandbox, sandbox_fixes} <- check_sandbox(profile, fix?, opts) do
      git = git_check(opts)
      disk = disk_check(opts)
      runtime = runtime_identity(profile, sandbox, git, opts)

      checks = [
        check(:project_config, File.regular?(config_path), config_path, "run `twelvgaige init`"),
        check(
          :profile,
          not is_nil(profile.name),
          profile.name || "none",
          "select or create a default profile"
        ),
        check(
          :authentication_profile,
          present?(profile.values[:auth_profile]),
          profile.values[:auth_profile] || "not configured",
          "add auth_profile to the selected developer profile"
        ),
        executable_check(:codex, opts),
        git.check,
        disk,
        sandbox
      ]

      {:ok,
       %{
         status: if(Enum.all?(checks, &(&1.status == :ok)), do: :ready, else: :action_required),
         project_root: root,
         profile: profile.name,
         checks: checks,
         fixes: fixes ++ sandbox_fixes,
         versions: runtime.versions,
         capabilities: runtime.capabilities
       }}
    end
  end

  defp maybe_fix_config(path, root, true, opts) do
    if File.regular?(path) do
      {:ok, []}
    else
      initializer = Keyword.get(opts, :init_fun, &Init.run/1)

      case initializer.(Keyword.merge(opts, project_root: root)) do
        {:ok, _result} -> {:ok, [:project_initialized]}
        {:error, reason} -> {:error, {:doctor_fix_failed, :project_config, reason}}
      end
    end
  end

  defp maybe_fix_config(_path, _root, false, _opts), do: {:ok, []}

  defp resolve_profile(opts) do
    resolver = Keyword.get(opts, :profile_resolver, &Config.resolve_profile/2)
    resolver.(Keyword.get(opts, :profile), opts)
  end

  defp check_sandbox(profile, fix?, opts) do
    backend = backend(profile.values[:sandbox] || "podman")
    checker = Keyword.get(opts, :sandbox_check_fun, &Onboarding.check/2)

    case checker.(backend, opts) do
      {:ok, result} ->
        {:ok, check(:sandbox, true, result, nil), []}

      {:error, reason} when fix? ->
        fix_sandbox(backend, reason, opts)

      {:error, reason} ->
        {:ok, check(:sandbox, false, inspect(reason), "run `twelvgaige doctor --fix`"), []}
    end
  end

  defp fix_sandbox(backend, original_reason, opts) do
    setup = Keyword.get(opts, :sandbox_setup_fun, &Onboarding.setup/2)

    case setup.(backend, opts) do
      {:ok, result} -> {:ok, check(:sandbox, true, result, nil), [:sandbox_configured]}
      {:error, reason} -> {:error, {:doctor_fix_failed, :sandbox, original_reason, reason}}
    end
  end

  defp executable_check(name, opts) do
    finder = Keyword.get(opts, :executable_finder, &System.find_executable/1)
    path = finder.(Atom.to_string(name))
    check(name, is_binary(path), path || "not found", "install #{name} and ensure it is on PATH")
  end

  defp git_check(opts) do
    result = Keyword.get(opts, :git_version_fun, &Git.version/0).()

    case result do
      {:ok, version} when is_tuple(version) ->
        supported? = version >= {2, 39, 0}

        %{
          check:
            check(
              :git,
              supported?,
              format_version(version),
              "install Git 2.39.0 or newer"
            ),
          version: format_version(version)
        }

      {:error, reason} ->
        %{
          check: check(:git, false, inspect(reason), "install Git 2.39.0 or newer"),
          version: "unavailable"
        }

      _invalid ->
        %{
          check: check(:git, false, "invalid version result", "install Git 2.39.0 or newer"),
          version: "unavailable"
        }
    end
  end

  defp disk_check(opts) do
    root = opts |> Paths.data_root() |> existing_ancestor()
    probe = Keyword.get(opts, :disk_available_fun, &Storage.available_bytes/1)
    warning_bytes = Keyword.get(opts, :disk_warning_bytes, @disk_warning_bytes)

    case probe.(root) do
      {:ok, available} when is_integer(available) and available >= warning_bytes ->
        check(:disk_capacity, true, %{available_bytes: available}, nil)

      {:ok, available} when is_integer(available) and available >= 0 ->
        check(
          :disk_capacity,
          false,
          %{available_bytes: available, warning_below_bytes: warning_bytes},
          "run `twelvgaige workspace retention status` and review retained workspaces"
        )

      {:error, reason} ->
        check(
          :disk_capacity,
          false,
          %{probe_error: inspect(reason)},
          "verify access to the Twelvgaige data volume"
        )

      _invalid ->
        check(
          :disk_capacity,
          false,
          %{probe_error: "invalid disk-capacity result"},
          "verify access to the Twelvgaige data volume"
        )
    end
  end

  defp existing_ancestor(path) do
    cond do
      File.dir?(path) -> path
      Path.dirname(path) == path -> path
      true -> path |> Path.dirname() |> existing_ancestor()
    end
  end

  defp runtime_identity(profile, sandbox, git, opts) do
    descriptor = Keyword.get(opts, :integration_descriptor, Codex.descriptor())
    sandbox_detail = Map.get(sandbox, :detail, %{})
    health = value(sandbox_detail, :health, %{})
    backend = backend(profile.values[:sandbox] || "podman")

    versions = %{
      cli: Twelvgaige.version(),
      daemon_protocol: Protocol.api_version(),
      git: git.version,
      provider: descriptor.artifact_version,
      provider_protocol: descriptor.protocol_version,
      sandbox_backend: backend,
      sandbox: nested_value(health, [:version, :client_version, :server_version]) || "unreported",
      image_digest:
        nested_value(sandbox_detail, [:image_digest, :digest]) ||
          nested_value(health, [:image_digest, :digest]) || "unreported",
      credential_mode:
        if(present?(profile.values[:auth_profile]), do: :brokered_service, else: :unconfigured)
    }

    capabilities = %{
      provider: descriptor.capabilities,
      sandbox: value(health, :capabilities, %{}),
      workspace_transport: :copy_snapshot,
      native_subagents: descriptor.capabilities.native_subagents
    }

    %{versions: versions, capabilities: capabilities}
  end

  defp nested_value(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case value(map, key) do
        nil -> find_nested(map, key)
        found -> found
      end
    end)
  end

  defp nested_value(_map, _keys), do: nil

  defp find_nested(map, key) do
    Enum.find_value(map, fn
      {_name, nested} when is_map(nested) -> value(nested, key) || find_nested(nested, key)
      _entry -> nil
    end)
  end

  defp format_version(version), do: version |> Tuple.to_list() |> Enum.join(".")

  defp value(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp check(name, true, detail, _remedy), do: %{name: name, status: :ok, detail: detail}

  defp check(name, false, detail, remedy),
    do: %{name: name, status: :error, detail: detail, remedy: remedy}

  defp backend("apple-container"), do: :apple_container
  defp backend(_other), do: :podman
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
