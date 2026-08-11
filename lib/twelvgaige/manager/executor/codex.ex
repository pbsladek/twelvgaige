defmodule Twelvgaige.Manager.Executor.Codex do
  @moduledoc "Typed bridge from a governed manager child to the qualified Codex delegated-session driver."

  alias Twelvgaige.DelegatedSession
  alias Twelvgaige.DelegatedSession.Codex.AuthProfile
  alias Twelvgaige.Integration.{Catalog, Codex}
  alias Twelvgaige.Manager.ChildRecord
  alias Twelvgaige.Manager.SessionRunner

  def run(%ChildRecord{task: %{agent: "codex"}} = child, opts) do
    descriptor = Keyword.get(opts, :descriptor, Codex.descriptor())

    with {:ok, descriptor} <-
           Catalog.resolve([descriptor], descriptor.id,
             unattended?: true,
             required_capabilities: [:structured_protocol, :exact_resume, :native_subagents]
           ),
         {:ok, workspace} <- resolve_workspace(child, opts),
         {:ok, auth_context} <- resolve_auth_context(child, opts) do
      result = safe_execute_with_auth(child, workspace, descriptor, auth_context, opts)
      finish_auth_context(result, auth_context, opts)
    end
  end

  def run(%ChildRecord{task: %{agent: agent}}, _opts),
    do: {:error, {:manager_executor_agent_mismatch, "codex", agent}}

  defp build_session(child, workspace, auth, sandbox_digest, descriptor, opts) do
    DelegatedSession.new(%{
      id: child.delegated_session_id,
      round_id: child.round_id,
      shot_id: child.shot_id,
      attempt: child.attempt,
      runtime: :codex,
      driver: descriptor.adapter,
      runtime_version: descriptor.artifact_version,
      integration_descriptor_id: descriptor.id,
      workspace_id: child.workspace_id,
      base_commit: workspace.base_commit,
      auth_profile_id: auth.id,
      auth_revision: auth.revision,
      principal: Keyword.get(opts, :principal, "codex:#{auth.id}:#{child.delegated_session_id}"),
      sandbox_profile: child.task.sandbox_profile,
      sandbox_manifest_digest: sandbox_digest,
      policy_revision: Keyword.fetch!(opts, :policy_revision),
      budgets: Map.from_struct(child.budget),
      deadline: child.deadline,
      created_at: DateTime.utc_now(),
      capabilities: descriptor.capabilities,
      effective_capabilities: child.task.capabilities
    })
  end

  defp resolve_workspace(child, opts) do
    resolver = Keyword.fetch!(opts, :workspace_resolver)

    case resolver.(child.workspace_id) do
      {:ok, %{id: id} = workspace} when id == child.workspace_id -> {:ok, workspace}
      {:ok, _workspace} -> {:error, :manager_workspace_identity_mismatch}
      {:error, reason} -> {:error, reason}
    end
  end

  defp execute_with_auth(child, workspace, descriptor, auth_context, opts) do
    auth = auth_context.profile

    with :ok <- AuthProfile.validate(auth, %{mode: :unattended}),
         {:ok, sandbox} <- resolve_sandbox(child, workspace, auth_context, opts),
         session <-
           build_session(child, workspace, auth, sandbox.manifest_digest, descriptor, opts),
         {:ok, result} <- run_session(session, child, descriptor, sandbox, workspace, auth, opts) do
      validate_result(result, session)
    end
  end

  defp safe_execute_with_auth(child, workspace, descriptor, auth_context, opts) do
    execute_with_auth(child, workspace, descriptor, auth_context, opts)
  rescue
    _error -> {:error, :manager_codex_execution_crashed}
  catch
    :exit, _reason -> {:error, :manager_codex_execution_exited}
    :throw, _reason -> {:error, :manager_codex_execution_threw}
  end

  defp resolve_auth_context(child, opts) do
    case Keyword.get(opts, :auth_context_resolver) do
      resolver when is_function(resolver, 1) ->
        child |> resolver.() |> normalize_auth_context()

      nil ->
        with {:ok, profile} <- resolve_static_auth(child, opts) do
          {:ok, %{profile: profile, environment: %{}, credential_mount: nil}}
        end
    end
  end

  defp resolve_static_auth(child, opts) do
    profiles = Keyword.fetch!(opts, :auth_profiles)

    case Map.get(profiles, child.task.auth_profile_id) do
      %AuthProfile{} = profile -> {:ok, profile}
      nil -> {:error, :manager_auth_profile_not_found}
      attrs when is_map(attrs) -> new_auth_profile(attrs)
    end
  end

  defp normalize_auth_context({:ok, context}), do: normalize_auth_context(context)
  defp normalize_auth_context({:error, _reason} = error), do: error

  defp normalize_auth_context(%AuthProfile{} = profile),
    do: {:ok, %{profile: profile, environment: %{}, credential_mount: nil}}

  defp normalize_auth_context(context) when is_map(context) do
    profile = Map.get(context, :profile, Map.get(context, "profile"))

    with {:ok, profile} <- normalize_auth_profile(profile) do
      environment = Map.get(context, :environment, Map.get(context, "environment", %{}))

      credential_mount =
        Map.get(context, :credential_mount, Map.get(context, "credential_mount"))

      cond do
        not is_map(environment) ->
          {:error, :manager_auth_context_environment_invalid}

        not is_nil(credential_mount) and not is_map(credential_mount) ->
          {:error, :manager_auth_context_mount_invalid}

        true ->
          {:ok,
           context
           |> Map.put(:profile, profile)
           |> Map.put(:environment, environment)
           |> Map.put(:credential_mount, credential_mount)}
      end
    end
  end

  defp normalize_auth_context(_invalid), do: {:error, :manager_auth_context_invalid}

  defp normalize_auth_profile(%AuthProfile{} = profile), do: {:ok, profile}
  defp normalize_auth_profile(profile) when is_map(profile), do: new_auth_profile(profile)
  defp normalize_auth_profile(_profile), do: {:error, :manager_auth_context_profile_invalid}

  defp new_auth_profile(attrs) do
    {:ok, AuthProfile.new(attrs)}
  rescue
    _error -> {:error, :manager_auth_context_profile_invalid}
  end

  defp resolve_sandbox(child, workspace, auth_context, opts) do
    case Keyword.get(opts, :sandbox_context_resolver) do
      resolver when is_function(resolver, 3) ->
        resolver.(child, workspace, auth_context) |> validate_sandbox_context()

      resolver when is_function(resolver, 2) ->
        resolver.(child, workspace) |> validate_sandbox_context()

      nil ->
        resolver = Keyword.fetch!(opts, :sandbox_manifest_resolver)

        case resolver.(child) do
          {:ok, digest} -> validate_sandbox_context(%{manifest_digest: digest, launch_spec: nil})
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp validate_sandbox_context({:ok, context}), do: validate_sandbox_context(context)
  defp validate_sandbox_context({:error, _reason} = error), do: error

  defp validate_sandbox_context(%{manifest_digest: digest} = context) do
    valid_digest? =
      case digest do
        "sha256:" <> value -> byte_size(value) == 64
        value when is_binary(value) -> byte_size(value) == 64
        _other -> false
      end

    launch_spec = Map.get(context, :launch_spec)

    cond do
      not valid_digest? ->
        {:error, :manager_sandbox_manifest_digest_invalid}

      not is_nil(launch_spec) and not is_map(launch_spec) ->
        {:error, :manager_sandbox_launch_spec_invalid}

      true ->
        {:ok, context}
    end
  end

  defp validate_sandbox_context(_invalid), do: {:error, :manager_sandbox_context_invalid}

  defp run_session(session, child, descriptor, sandbox, workspace, auth, opts) do
    opts =
      opts
      |> Keyword.merge(Map.get(sandbox, :runner_opts, []))
      |> Keyword.update(:adapter_config, %{auth_profile: auth}, fn config ->
        config |> Map.new() |> Map.put(:auth_profile, auth)
      end)

    opts =
      if is_map(sandbox.launch_spec) do
        opts
        |> Keyword.put(:sandbox_spec_resolver, fn _session, _child -> sandbox.launch_spec end)
        |> Keyword.put_new(:result_destination, workspace.path)
      else
        opts
      end

    case Keyword.get(opts, :session_runner) do
      runner when is_function(runner, 3) ->
        runner.(session, child, descriptor)

      nil ->
        opts
        |> Keyword.get(:session_runner_module, SessionRunner)
        |> apply(:run, [session, child, descriptor, opts])
    end
  end

  defp validate_result(%{handoff: %Twelvgaige.Handoff{} = handoff} = result, session) do
    if handoff.workspace_id == session.workspace_id,
      do: {:ok, Map.put_new(result, :principal, session.principal)},
      else: {:error, :manager_handoff_workspace_identity_mismatch}
  end

  defp validate_result(_result, _session), do: {:error, :manager_codex_result_invalid}

  defp finish_auth_context(result, auth_context, opts) do
    cleanup =
      case Keyword.get(opts, :auth_cleanup_fun) do
        cleanup_fun when is_function(cleanup_fun, 1) -> cleanup_fun.(auth_context)
        nil -> :ok
      end

    case cleanup do
      status when status in [:ok, :already_revoked, :already_removed] -> result
      {:error, reason} -> {:error, {:manager_auth_cleanup_failed, reason, result}}
      other -> {:error, {:manager_auth_cleanup_invalid, other, result}}
    end
  rescue
    error -> {:error, {:manager_auth_cleanup_crashed, Exception.message(error), result}}
  end
end
