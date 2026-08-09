defmodule Twelvgaige.Manager.Executor.Codex do
  @moduledoc "Typed bridge from a governed manager child to the qualified Codex delegated-session driver."

  alias Twelvgaige.DelegatedSession
  alias Twelvgaige.DelegatedSession.Codex.AuthProfile
  alias Twelvgaige.Integration.{Catalog, Codex}
  alias Twelvgaige.Manager.ChildRecord

  def run(%ChildRecord{task: %{agent: "codex"}} = child, opts) do
    descriptor = Keyword.get(opts, :descriptor, Codex.descriptor())

    with {:ok, descriptor} <-
           Catalog.resolve([descriptor], descriptor.id,
             unattended?: true,
             required_capabilities: [:structured_protocol, :exact_resume, :native_subagents]
           ),
         {:ok, workspace} <- resolve_workspace(child, opts),
         {:ok, auth} <- resolve_auth(child, opts),
         :ok <- AuthProfile.validate(auth, %{mode: :unattended}),
         {:ok, sandbox_digest} <- sandbox_digest(child, opts),
         session <- build_session(child, workspace, auth, sandbox_digest, descriptor, opts),
         {:ok, result} <- run_session(session, child, descriptor, opts) do
      validate_result(result, session)
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

  defp resolve_auth(child, opts) do
    profiles = Keyword.fetch!(opts, :auth_profiles)

    case Map.get(profiles, child.task.auth_profile_id) do
      %AuthProfile{} = profile -> {:ok, profile}
      nil -> {:error, :manager_auth_profile_not_found}
      attrs when is_map(attrs) -> {:ok, AuthProfile.new(attrs)}
    end
  end

  defp sandbox_digest(child, opts) do
    resolver = Keyword.fetch!(opts, :sandbox_manifest_resolver)

    case resolver.(child) do
      {:ok, "sha256:" <> digest = value} when byte_size(digest) == 64 -> {:ok, value}
      {:ok, digest} when is_binary(digest) and byte_size(digest) == 64 -> {:ok, digest}
      {:ok, _invalid} -> {:error, :manager_sandbox_manifest_digest_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_session(session, child, descriptor, opts) do
    runner = Keyword.fetch!(opts, :session_runner)
    runner.(session, child, descriptor)
  end

  defp validate_result(%{handoff: %Twelvgaige.Handoff{} = handoff} = result, session) do
    if handoff.workspace_id == session.workspace_id,
      do: {:ok, Map.put_new(result, :principal, session.principal)},
      else: {:error, :manager_handoff_workspace_identity_mismatch}
  end

  defp validate_result(_result, _session), do: {:error, :manager_codex_result_invalid}
end
