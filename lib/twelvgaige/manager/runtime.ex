defmodule Twelvgaige.Manager.Runtime do
  @moduledoc "Builds deterministic production executor and sandbox context for manager children."

  alias Twelvgaige.DelegatedSession.Codex.AuthProfile
  alias Twelvgaige.Manager.AuthContext
  alias Twelvgaige.Manager.Executor
  alias Twelvgaige.Sandbox.LaunchManifest
  alias Twelvgaige.Workspace.Manager, as: WorkspaceManager

  @default_limits %{cpu: 2, memory_bytes: 2 * 1_073_741_824, pids: 256}
  @default_workspace_bytes 10 * 1_073_741_824
  @default_artifact_bytes 2 * 1_073_741_824

  def executor(workspace_manager, opts) do
    executor_opts = executor_options(workspace_manager, opts)
    fn child -> Executor.run(child, executor_opts) end
  end

  @doc "Stops, exports, and destroys the exact sandbox owned by a running manager child."
  def cancel(child, workspace_manager, opts) do
    sandbox_manager = Keyword.fetch!(opts, :sandbox_manager)

    completion_opts =
      opts
      |> sandbox_opts()
      |> Keyword.put(:server, sandbox_manager)

    with {:ok, workspace} <- WorkspaceManager.get(child.workspace_id, server: workspace_manager),
         {:ok, report} <-
           Twelvgaige.Sandbox.Manager.complete_workspace(
             sandbox_resource_id(child),
             workspace.path,
             completion_opts
           ) do
      {:ok, Map.fetch!(report, :runtime_quiescence)}
    else
      :already_stopped -> {:error, :manager_runtime_already_stopped_without_evidence}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the stable outer-sandbox identity reserved for a manager child."
  def sandbox_resource_id(child) do
    suffix =
      :crypto.hash(:sha256, child.delegated_session_id || child.id)
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 20)

    "sandbox-" <> suffix
  end

  def executor_options(workspace_manager, opts) do
    sandbox_manager = Keyword.fetch!(opts, :sandbox_manager)
    {auth_context_resolver, auth_cleanup_fun} = auth_context_callbacks(opts)

    [
      workspace_resolver: &WorkspaceManager.get(&1, server: workspace_manager),
      auth_profiles: Keyword.get(opts, :auth_profiles, %{}),
      auth_context_resolver: auth_context_resolver,
      auth_cleanup_fun: auth_cleanup_fun,
      sandbox_context_resolver: &sandbox_context(&1, &2, &3, opts),
      policy_revision: Keyword.fetch!(opts, :policy_revision),
      sandbox_manager: sandbox_manager,
      sandbox_opts: sandbox_opts(opts),
      adapter_config: Keyword.get(opts, :adapter_config, %{}),
      session_control: Keyword.get(opts, :session_control),
      approval_policy: Keyword.get(opts, :approval_policy, "never"),
      approvals_reviewer: Keyword.get(opts, :approvals_reviewer, "user"),
      runtime_command:
        Keyword.get(opts, :runtime_command, [
          "/opt/codex/bin/codex",
          "app-server",
          "--stdio",
          "--strict-config"
        ])
    ]
  end

  defp auth_context_callbacks(opts) do
    explicit_resolver = Keyword.get(opts, :auth_context_resolver)
    explicit_cleanup = Keyword.get(opts, :auth_cleanup_fun)

    case {explicit_resolver, Keyword.get(opts, :credential_profiles)} do
      {resolver, _profiles} when is_function(resolver, 1) ->
        {resolver, explicit_cleanup}

      {nil, profiles} when is_map(profiles) ->
        resolver = fn child -> AuthContext.resolve(child, profiles, opts) end
        cleanup = explicit_cleanup || fn context -> AuthContext.cleanup(context, opts) end
        {resolver, cleanup}

      _other ->
        {explicit_resolver, explicit_cleanup}
    end
  end

  def sandbox_context(child, workspace, opts) do
    with {:ok, auth} <- auth_profile(child, opts) do
      sandbox_context(
        child,
        workspace,
        %{profile: auth, environment: %{}, credential_mount: nil},
        opts
      )
    end
  end

  def sandbox_context(child, workspace, auth_context, opts) do
    auth = Map.fetch!(auth_context, :profile)

    with :ok <- validate_auth_context(auth_context),
         {:ok, network} <- network_context(child, opts),
         {:ok, mounts} <- mounts(child, workspace, auth, auth_context, opts),
         {:ok, environment} <- environment(network, mounts, auth_context, opts),
         resource_id <- sandbox_resource_id(child),
         spec <-
           launch_spec(child, workspace, auth, network, mounts, environment, resource_id, opts),
         backend <- Keyword.fetch!(opts, :backend),
         runtime_opts <-
           opts
           |> sandbox_opts()
           |> Keyword.put(:environment, environment)
           |> Keyword.merge(network.runner_opts),
         prepare_opts <- runtime_opts,
         {:ok, manifest} <-
           backend.prepare(
             Map.drop(spec, [
               :reservation,
               :egress_access_token,
               :egress_lease_id,
               :result_destination
             ]),
             prepare_opts
           ),
         bound <- bind_manifest(manifest, backend, resource_id) do
      {:ok,
       %{
         manifest_digest: bound.manifest_digest,
         launch_spec: spec,
         runner_opts: [sandbox_opts: runtime_opts]
       }}
    end
  end

  defp validate_auth_context(%{profile: %AuthProfile{}, environment: environment} = context) do
    mount = Map.get(context, :credential_mount)

    cond do
      not is_map(environment) -> {:error, :manager_auth_context_environment_invalid}
      not is_nil(mount) and not is_map(mount) -> {:error, :manager_auth_context_mount_invalid}
      true -> :ok
    end
  end

  defp validate_auth_context(_context), do: {:error, :manager_auth_context_invalid}

  defp auth_profile(child, opts) do
    case Map.get(Keyword.fetch!(opts, :auth_profiles), child.task.auth_profile_id) do
      %AuthProfile{} = profile -> {:ok, profile}
      attrs when is_map(attrs) -> new_auth_profile(attrs)
      nil -> {:error, :manager_auth_profile_not_found}
    end
  end

  defp new_auth_profile(attrs) do
    {:ok, AuthProfile.new(attrs)}
  rescue
    _error -> {:error, :manager_auth_profile_invalid}
  end

  defp network_context(%{task: %{network_mode: :broker_only}} = child, opts) do
    case Keyword.get(opts, :egress_context_resolver) do
      resolver when is_function(resolver, 1) ->
        with {:ok, context} <- normalize_context(resolver.(child)),
             lease_id when is_binary(lease_id) and lease_id != "" <-
               value(context, :egress_lease_id, value(context, :proxy_lease_id)),
             token when is_binary(token) and token != "" <- value(context, :egress_access_token),
             runner_opts when is_list(runner_opts) <- value(context, :runner_opts, []) do
          {:ok,
           %{
             mode: :broker_only,
             proxy_lease_id: lease_id,
             egress_access_token: token,
             runner_opts: runner_opts
           }}
        else
          _invalid -> {:error, :manager_egress_context_invalid}
        end

      nil ->
        {:error, :manager_egress_context_required}
    end
  end

  defp network_context(%{task: %{network_mode: :unrestricted}}, opts) do
    if Keyword.get(opts, :allow_unrestricted?, false),
      do: {:ok, %{mode: :unrestricted, runner_opts: [allow_unrestricted?: true]}},
      else: {:error, :manager_unrestricted_network_not_enabled}
  end

  defp network_context(_child, _opts),
    do: {:ok, %{mode: :none, runner_opts: []}}

  defp mounts(child, workspace, auth, auth_context, opts) do
    workspace_mount = %{
      source: workspace.path,
      destination: "/workspace",
      mode: if(child.task.write, do: :read_write, else: :read_only)
    }

    case Map.get(auth_context, :credential_mount) do
      mount when is_map(mount) ->
        {:ok, [workspace_mount, normalize_credential_mount(mount)]}

      nil ->
        resolve_credential_mount(workspace_mount, child, auth, opts)
    end
  end

  defp resolve_credential_mount(workspace_mount, child, auth, opts) do
    case Keyword.get(opts, :credential_mount_resolver) do
      resolver when is_function(resolver, 2) ->
        case resolver.(child, auth) do
          {:ok, nil} ->
            {:ok, [workspace_mount]}

          {:ok, mount} when is_map(mount) ->
            {:ok, [workspace_mount, normalize_credential_mount(mount)]}

          {:error, _reason} = error ->
            error

          _invalid ->
            {:error, :manager_credential_mount_invalid}
        end

      nil ->
        {:ok, [workspace_mount]}
    end
  end

  defp normalize_credential_mount(mount) do
    %{
      source: value(mount, :source),
      destination: "/run/codex-home",
      mode: :read_write
    }
  end

  defp environment(network, mounts, auth_context, opts) do
    base = Keyword.get(opts, :environment, %{}) |> Map.merge(auth_context.environment)
    proxy = Keyword.get(network.runner_opts, :proxy_environment, %{})

    credential_environment =
      if Enum.any?(mounts, &(value(&1, :destination) == "/run/codex-home")),
        do: %{"CODEX_HOME" => "/run/codex-home"},
        else: %{}

    environment = base |> Map.merge(proxy) |> Map.merge(credential_environment)

    if Enum.all?(environment, fn {key, value} ->
         is_binary(key) and key != "" and is_binary(value) and value != ""
       end),
       do: {:ok, environment},
       else: {:error, :manager_runtime_environment_invalid}
  end

  defp launch_spec(child, workspace, auth, network, mounts, environment, resource_id, opts) do
    limits = Keyword.get(opts, :limits, @default_limits)
    workspace_bytes = reservation_value(workspace, :workspace_bytes, @default_workspace_bytes)
    artifact_bytes = Keyword.get(opts, :artifact_bytes, @default_artifact_bytes)

    %{
      resource_id: resource_id,
      profile: sandbox_profile(child.task.sandbox_profile),
      image_reference: Keyword.fetch!(opts, :image_reference),
      image_digest: Keyword.fetch!(opts, :image_digest),
      workspace_transport: :copy_snapshot,
      mounts: mounts,
      network_mode: network.mode,
      allowed_destinations: [],
      limits: limits,
      deadline: child.deadline,
      credential_lease_id: auth.credential_lease_id,
      proxy_lease_id: Map.get(network, :proxy_lease_id),
      egress_lease_id: Map.get(network, :proxy_lease_id),
      egress_access_token: Map.get(network, :egress_access_token),
      policy_revision: Keyword.fetch!(opts, :policy_revision),
      environment_names: environment |> Map.keys() |> Enum.sort(),
      result_destination: workspace.path,
      created_at: child.created_at,
      reservation: %{
        sandboxes: 1,
        cpu: value(limits, :cpu),
        memory_bytes: value(limits, :memory_bytes),
        pids: value(limits, :pids),
        workspace_bytes: workspace_bytes,
        artifact_bytes: artifact_bytes,
        provider_tokens: child.budget.tokens
      }
    }
  end

  defp bind_manifest(manifest, Twelvgaige.Sandbox.Backend.AppleContainer, resource_id),
    do: LaunchManifest.bind_resource(manifest, resource_id, machine_id: resource_id)

  defp bind_manifest(manifest, _backend, resource_id),
    do: LaunchManifest.bind_resource(manifest, resource_id)

  defp sandbox_opts(opts) do
    opts
    |> Keyword.fetch!(:backend_opts)
    |> Keyword.merge(
      environment: Keyword.get(opts, :environment, %{}),
      allow_unrestricted?: Keyword.get(opts, :allow_unrestricted?, false),
      allowed_export_roots: Keyword.fetch!(opts, :allowed_export_roots)
    )
  end

  defp sandbox_profile(profile)
       when profile in [
              :analysis_only,
              :coding_restricted,
              :coding_unrestricted_network,
              :integration_test
            ],
       do: profile

  defp sandbox_profile("coding_restricted:" <> _backend), do: :coding_restricted
  defp sandbox_profile("analysis_only:" <> _backend), do: :analysis_only
  defp sandbox_profile(_profile), do: :coding_restricted

  defp reservation_value(%{storage_reservation: reservation}, key, default)
       when is_map(reservation),
       do: value(reservation, key, default)

  defp reservation_value(_workspace, _key, default), do: default

  defp normalize_context({:ok, context}) when is_map(context), do: {:ok, context}
  defp normalize_context(context) when is_map(context), do: {:ok, context}
  defp normalize_context({:error, _reason} = error), do: error
  defp normalize_context(_invalid), do: {:error, :manager_egress_context_invalid}

  defp value(map, key, default \\ nil) when is_map(map),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
