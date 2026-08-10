defmodule Twelvgaige.Developer.Doctor do
  @moduledoc "Actionable project, runtime, and sandbox readiness checks."

  alias Twelvgaige.Developer.{Config, Init}
  alias Twelvgaige.Sandbox.Onboarding

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    root = Config.project_root(opts)
    config_path = Config.project_config_path(root)
    fix? = Keyword.get(opts, :fix?, false)

    with {:ok, fixes} <- maybe_fix_config(config_path, root, fix?, opts),
         {:ok, profile} <- resolve_profile(opts),
         {:ok, sandbox, sandbox_fixes} <- check_sandbox(profile, fix?, opts) do
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
        sandbox
      ]

      {:ok,
       %{
         status: if(Enum.all?(checks, &(&1.status == :ok)), do: :ready, else: :action_required),
         project_root: root,
         profile: profile.name,
         checks: checks,
         fixes: fixes ++ sandbox_fixes
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

  defp check(name, true, detail, _remedy), do: %{name: name, status: :ok, detail: detail}

  defp check(name, false, detail, remedy),
    do: %{name: name, status: :error, detail: detail, remedy: remedy}

  defp backend("apple-container"), do: :apple_container
  defp backend(_other), do: :podman
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
