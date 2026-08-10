defmodule Twelvgaige.Developer.Init do
  @moduledoc "Creates a minimal, secret-free project configuration and example task."

  alias Twelvgaige.Authoring.AtomicFile
  alias Twelvgaige.Developer.Config

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    root = Config.project_root(opts)
    profile = Keyword.get(opts, :profile, "local-dev")
    sandbox = Keyword.get(opts, :sandbox, "podman")
    auth_profile = Keyword.get(opts, :auth_profile)
    force? = Keyword.get(opts, :force?, false)
    config_path = Config.project_config_path(root)
    task_path = Path.join([root, ".twelvgaige", "tasks", "example.yaml"])

    with :ok <- valid_name(profile),
         :ok <- valid_sandbox(sandbox),
         :ok <- writable(config_path, force?),
         :ok <- writable(task_path, force?),
         :ok <- AtomicFile.write(config_path, config(profile, sandbox, auth_profile)),
         :ok <- AtomicFile.write(task_path, example_task()) do
      {:ok,
       %{
         status: :initialized,
         project_root: root,
         profile: profile,
         config_path: config_path,
         task_path: task_path,
         auth_configured: present?(auth_profile)
       }}
    end
  end

  defp config(profile, sandbox, auth_profile) do
    auth =
      if present?(auth_profile), do: "    auth_profile: #{yaml_string(auth_profile)}\n", else: ""

    """
    version: 1
    default_profile: #{yaml_string(profile)}
    profiles:
      #{profile}:
        runtime: codex
        repository: ..
    #{auth}    sandbox: #{sandbox}
        network: broker-only
        allowed_paths:
          - lib
          - test
        write: true
        timeout: 45m
        budget:
          tokens: 80000
          cost_micros: 25000000
          tool_calls: 1000
    """
  end

  defp example_task do
    """
    version: 1
    objective: >-
      Describe the change, the constraints that matter, and how the result should be verified.
    """
  end

  defp writable(path, true),
    do: if(File.dir?(path), do: {:error, {:init_target_is_directory, path}}, else: :ok)

  defp writable(path, false),
    do: if(File.exists?(path), do: {:error, {:init_target_exists, path}}, else: :ok)

  defp valid_name(name) do
    if is_binary(name) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9._-]*$/, name),
      do: :ok,
      else: {:error, :developer_profile_name_invalid}
  end

  defp valid_sandbox(value) when value in ["podman", "apple-container"], do: :ok
  defp valid_sandbox(value), do: {:error, {:sandbox_backend_invalid, value}}
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp yaml_string(value), do: Jason.encode!(value)
end
