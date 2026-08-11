defmodule Twelvgaige.Manager.AuthContext do
  @moduledoc "Issues an unattended credential lease and materializes an isolated Codex home."

  alias Twelvgaige.Credential.{Broker, CodexHome}
  alias Twelvgaige.DelegatedSession.Codex.AuthProfile
  alias Twelvgaige.Operations.Paths

  @default_models ["codex"]
  @default_destinations ["api.openai.com"]

  @doc "Builds one credential context for a manager child from a named profile."
  def resolve(child, profiles, opts \\ [])

  def resolve(child, profiles, opts) when is_map(profiles) do
    profile_id = child.task.auth_profile_id

    with {:ok, profile} <- fetch_profile(profiles, profile_id),
         {:ok, secret} <- resolve_secret(child, profile, opts),
         {:ok, lease} <- issue_lease(child, profile_id, profile, secret, opts),
         {:ok, upstream_secret} <- authorize_materialization(child, profile, lease, opts),
         {:ok, context} <-
           materialize_context(child, profile_id, profile, lease, upstream_secret, opts) do
      {:ok, context}
    else
      {:error, {:issued_lease, lease, reason}} ->
        _ = revoke(lease.id, opts)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def resolve(_child, _profiles, _opts), do: {:error, :manager_credential_profiles_invalid}

  @doc "Revokes the lease and removes the exact private credential home."
  def cleanup(context, opts \\ [])

  def cleanup(context, opts) when is_map(context) do
    lease_id = value(context, :credential_lease_id)
    home = value(context, :credential_home)
    root = value(context, :credential_root, credentials_root(opts))

    revoke_result = if is_binary(lease_id), do: revoke(lease_id, opts), else: :already_revoked

    home_result =
      if is_binary(home),
        do: CodexHome.cleanup(home, allowed_root: root),
        else: :already_removed

    case {normalize_cleanup(revoke_result), normalize_cleanup(home_result)} do
      {:ok, :ok} -> :ok
      {{:error, reason}, :ok} -> {:error, reason}
      {:ok, {:error, reason}} -> {:error, reason}
      {{:error, left}, {:error, right}} -> {:error, {:credential_cleanup_failed, left, right}}
    end
  end

  def cleanup(_context, _opts), do: {:error, :manager_auth_context_invalid}

  defp fetch_profile(profiles, id) when is_binary(id) do
    case Map.get(profiles, id) do
      profile when is_map(profile) or is_list(profile) -> {:ok, profile}
      nil -> {:error, :manager_credential_profile_not_found}
      _invalid -> {:error, :manager_credential_profile_invalid}
    end
  end

  defp fetch_profile(_profiles, _id), do: {:error, :manager_credential_profile_id_invalid}

  defp resolve_secret(child, profile, opts) do
    resolver = value(profile, :secret_resolver, Keyword.get(opts, :secret_resolver))

    result =
      cond do
        is_function(resolver, 2) -> resolver.(child, profile)
        is_function(resolver, 1) -> resolver.(profile)
        is_binary(value(profile, :secret_env)) -> System.fetch_env(value(profile, :secret_env))
        true -> {:error, :manager_credential_secret_resolver_required}
      end

    case result do
      {:ok, secret} when is_binary(secret) and secret != "" -> {:ok, secret}
      :error -> {:error, :manager_credential_secret_not_found}
      {:error, reason} -> {:error, {:manager_credential_secret_unavailable, safe_reason(reason)}}
      _invalid -> {:error, :manager_credential_secret_invalid}
    end
  rescue
    _error -> {:error, :manager_credential_secret_resolver_crashed}
  end

  defp issue_lease(child, profile_id, profile, secret, opts) do
    models = value(profile, :models, @default_models)
    destinations = value(profile, :destinations, @default_destinations)

    attrs = %{
      session_id: child.delegated_session_id || child.id,
      round_id: child.round_id,
      shot_id: child.shot_id,
      attempt: child.attempt,
      runtime: :codex,
      principal:
        child.principal || "codex:#{profile_id}:#{child.delegated_session_id || child.id}",
      provider_account: value(profile, :provider_account, profile_id),
      models: models,
      destinations: destinations,
      budget: child.budget.tokens,
      expires_at: child.deadline || DateTime.add(DateTime.utc_now(), 900, :second),
      upstream_secret: secret
    }

    case Broker.issue(attrs, server: Keyword.fetch!(opts, :credential_broker)) do
      {:ok, lease} -> {:ok, lease}
      {:error, reason} -> {:error, {:manager_credential_lease_failed, safe_reason(reason)}}
      _invalid -> {:error, :manager_credential_lease_result_invalid}
    end
  rescue
    _error -> {:error, :manager_credential_lease_crashed}
  end

  defp authorize_materialization(child, profile, lease, opts) do
    request = %{
      session_id: child.delegated_session_id || child.id,
      model: profile |> value(:models, @default_models) |> List.first(),
      destination: profile |> value(:destinations, @default_destinations) |> List.first(),
      amount: 0
    }

    case Broker.authorize(lease.access_token, request,
           server: Keyword.fetch!(opts, :credential_broker)
         ) do
      {:ok, %{upstream_secret: secret}} when is_binary(secret) and secret != "" ->
        {:ok, secret}

      {:error, reason} ->
        {:error, {:issued_lease, lease, {:manager_credential_authorization_failed, reason}}}

      _invalid ->
        {:error, {:issued_lease, lease, :manager_credential_authorization_result_invalid}}
    end
  rescue
    _error ->
      {:error, {:issued_lease, lease, :manager_credential_authorization_crashed}}
  end

  defp materialize_context(child, profile_id, profile, lease, secret, opts) do
    root = credentials_root(opts)
    home = Path.join(root, home_name(child))
    codex_home_opts = Keyword.get(opts, :codex_home_opts, []) |> Keyword.put(:allowed_root, root)

    case CodexHome.materialize(secret, home, codex_home_opts) do
      {:ok, mount} ->
        auth =
          AuthProfile.new(%{
            id: profile_id,
            type: :brokered_service,
            revision: value(profile, :revision, "1"),
            credential_lease_id: lease.id,
            broker_endpoint: value(profile, :broker_endpoint, "credential-broker://local")
          })

        {:ok,
         %{
           profile: auth,
           environment: %{},
           credential_mount: mount,
           credential_home: home,
           credential_root: root,
           credential_lease_id: lease.id
         }}

      {:error, reason} ->
        {:error, {:issued_lease, lease, reason}}
    end
  rescue
    _error ->
      {:error, {:issued_lease, lease, :manager_credential_materialization_crashed}}
  end

  defp credentials_root(opts) do
    opts
    |> Keyword.get(:credentials_root, Paths.credentials(opts))
    |> Path.expand()
  end

  defp home_name(child) do
    suffix =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({child.id, child.attempt, System.unique_integer([:positive])})
      )
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 24)

    "codex-home-" <> suffix
  end

  defp revoke(lease_id, opts) do
    Broker.revoke(lease_id, server: Keyword.fetch!(opts, :credential_broker))
  rescue
    _error -> {:error, :credential_revoke_crashed}
  end

  defp normalize_cleanup(result) when result in [:ok, :already_revoked, :already_removed], do: :ok
  defp normalize_cleanup({:error, reason}), do: {:error, reason}
  defp normalize_cleanup(other), do: {:error, {:credential_cleanup_result_invalid, other}}

  defp safe_reason(reason) when is_atom(reason) or is_integer(reason), do: reason
  defp safe_reason(_reason), do: :redacted

  defp value(attrs, key, default \\ nil)
  defp value(attrs, key, default) when is_list(attrs), do: Keyword.get(attrs, key, default)

  defp value(attrs, key, default) when is_map(attrs),
    do: Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
end
