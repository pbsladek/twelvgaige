defmodule Twelvgaige.Manager.SessionStart do
  @moduledoc """
  Compiles and submits one explicitly bounded delegated session.

  This is the local-user entry point into the manager control plane. It grants
  exactly the authority named by the request, so normal starts need no manager
  expansion approval. Execution still fails closed when the configured manager
  executor cannot satisfy the selected auth, sandbox, or integration profile.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Manager.{ChildFactory, ChildRecord, Compiler, Envelope, Plan, Scheduler}
  alias Twelvgaige.Operations.{LocalIdentity, SessionControl}
  alias Twelvgaige.Workspace.Git

  @runtime "codex"
  @workflow "coding.change.v1"
  @sandbox_profiles %{
    "podman" => "coding_restricted:podman",
    "apple-container" => "coding_restricted:apple_container"
  }
  @network_modes %{
    "none" => :none,
    "broker-only" => :broker_only,
    "unrestricted" => :unrestricted
  }

  @spec start(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def start(attrs, opts \\ [])

  def start(attrs, opts) when is_map(attrs) do
    with {:ok, prepared} <- prepare(attrs, opts),
         request = prepared.request,
         compiled = prepared.compiled,
         identities = prepared.identities,
         :ok <- reserve_inventory(compiled, request, identities, opts),
         {:ok, plan_id, submission} <- submit_or_fail_inventory(compiled, identities, opts) do
      {:ok,
       %{
         plan_id: plan_id,
         child_id: identities.child_id,
         session_id: identities.session_id,
         status: submission,
         runtime: request.runtime,
         repository: request.repository,
         base_ref: request.base_ref,
         sandbox: request.sandbox,
         sandbox_profile: request.sandbox_profile,
         network: Atom.to_string(request.network_mode),
         auth_profile: request.auth_profile,
         deadline: DateTime.to_iso8601(request.deadline),
         budget: request.budget
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, internal_error(reason)}
    end
  end

  def start(_attrs, _opts), do: {:error, input_error(:session_start_request_invalid)}

  @doc "Compiles an exact-authority plan without reserving inventory or submitting work."
  @spec plan(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def plan(attrs, opts \\ [])

  def plan(attrs, opts) when is_map(attrs) do
    with {:ok, prepared} <- prepare(attrs, opts) do
      request = prepared.request
      compiled = prepared.compiled

      {:ok,
       %{
         status: :planned,
         mutates_state: false,
         plan_id: compiled.plan.id,
         child_id: prepared.identities.child_id,
         session_id: prepared.identities.session_id,
         approval_status: compiled.approval_status,
         runtime: request.runtime,
         objective: request.objective,
         repository: request.repository,
         base_ref: request.base_ref,
         base_commit: prepared.base_commit,
         auth_profile: request.auth_profile,
         sandbox: request.sandbox,
         sandbox_profile: request.sandbox_profile,
         network: Atom.to_string(request.network_mode),
         allowed_paths: request.allowed_paths,
         write: request.write?,
         capabilities: capabilities(request),
         deadline: DateTime.to_iso8601(request.deadline),
         budget: request.budget,
         warnings: [
           "runtime authentication and sandbox health are checked when the session starts"
         ]
       }}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, internal_error(reason)}
    end
  end

  def plan(_attrs, _opts), do: {:error, input_error(:session_start_request_invalid)}

  defp prepare(attrs, opts) do
    with {:ok, request} <- normalize(attrs, opts),
         {:ok, identity} <- local_identity(opts),
         {:ok, base_commit} <- validate_repository(request, opts),
         {:ok, plan} <- build_plan(request, identity, opts),
         {:ok, envelope} <- exact_envelope(plan),
         {:ok, compiled} <-
           Compiler.compile(plan,
             parent_envelope: envelope,
             catalog: exact_catalog(plan)
           ) do
      {:ok,
       %{
         request: request,
         base_commit: base_commit,
         compiled: compiled,
         identities: identities(compiled)
       }}
    end
  end

  defp normalize(attrs, opts) do
    runtime = value(attrs, "runtime", @runtime)
    repository = attrs |> value("repository", ".") |> Path.expand()
    base_ref = value(attrs, "base_ref", "HEAD")
    objective = value(attrs, "task")
    auth_profile = value(attrs, "auth_profile")
    sandbox = value(attrs, "sandbox", "podman")
    network = value(attrs, "network", "broker-only")
    allowed_paths = value(attrs, "allowed_paths", [])
    write? = value(attrs, "write", true)
    timeout_ms = value(attrs, "timeout_ms", 2_700_000)
    budget = value(attrs, "budget", %{})
    now = Keyword.get(opts, :now, DateTime.utc_now())

    cond do
      runtime != @runtime ->
        {:error, input_error({:session_runtime_not_supported, runtime})}

      not present?(objective) ->
        {:error, input_error(:session_task_required)}

      not present?(auth_profile) ->
        {:error, input_error(:session_auth_profile_required)}

      not Map.has_key?(@sandbox_profiles, sandbox) ->
        {:error, input_error({:session_sandbox_invalid, sandbox})}

      not Map.has_key?(@network_modes, network) ->
        {:error, input_error({:session_network_invalid, network})}

      network == "unrestricted" and value(attrs, "allow_unrestricted_network", false) != true ->
        {:error, input_error(:session_unrestricted_network_confirmation_required)}

      not is_list(allowed_paths) or not Enum.all?(allowed_paths, &is_binary/1) ->
        {:error, input_error(:session_allowed_paths_invalid)}

      not is_boolean(write?) ->
        {:error, input_error(:session_write_mode_invalid)}

      not is_integer(timeout_ms) or timeout_ms <= 0 ->
        {:error, input_error(:session_timeout_invalid)}

      true ->
        with {:ok, budget} <- normalize_budget(budget, timeout_ms) do
          {:ok,
           %{
             runtime: runtime,
             repository: repository,
             base_ref: base_ref,
             objective: objective,
             auth_profile: auth_profile,
             sandbox: sandbox,
             sandbox_profile: Map.fetch!(@sandbox_profiles, sandbox),
             network_mode: Map.fetch!(@network_modes, network),
             allowed_paths: allowed_paths,
             write?: write?,
             timeout_ms: timeout_ms,
             deadline: DateTime.add(now, timeout_ms, :millisecond),
             budget: budget
           }}
        end
    end
  end

  defp normalize_budget(budget, timeout_ms) when is_map(budget) do
    values = %{
      tokens: value(budget, "tokens", 80_000),
      cost_micros: value(budget, "cost_micros", 25_000_000),
      time_ms: value(budget, "time_ms", timeout_ms),
      tool_calls: value(budget, "tool_calls", 1_000)
    }

    if Enum.all?(values, fn {_key, number} -> is_integer(number) and number >= 0 end) do
      {:ok, %{values | time_ms: min(values.time_ms, timeout_ms)}}
    else
      {:error, input_error(:session_budget_invalid)}
    end
  end

  defp normalize_budget(_budget, _timeout_ms), do: {:error, input_error(:session_budget_invalid)}

  defp validate_repository(request, opts) do
    resolver = Keyword.get(opts, :git_resolver, &Git.resolve_commit/3)

    cond do
      not File.dir?(request.repository) ->
        {:error, input_error(:session_repository_not_found)}

      true ->
        case resolver.(request.repository, request.base_ref, []) do
          {:ok, commit} -> {:ok, commit}
          {:error, reason} -> {:error, input_error({:session_base_ref_invalid, reason})}
        end
    end
  end

  defp local_identity(opts) do
    identity_fun = Keyword.get(opts, :identity_fun, &LocalIdentity.current/1)

    case identity_fun.([]) do
      {:ok, identity} -> {:ok, identity}
      {:error, reason} -> {:error, internal_error({:local_identity_unavailable, reason})}
    end
  end

  defp build_plan(request, identity, opts) do
    plan_id = Keyword.get(opts, :plan_id, Twelvgaige.ID.new(:manager_plan))
    principal = "local-user:#{identity.uid}:#{identity.username}"

    Plan.new(%{
      id: plan_id,
      manager_principal: principal,
      manager_session_id: Keyword.get(opts, :manager_session_id, Twelvgaige.ID.new(:session)),
      round_id: Keyword.get(opts, :round_id, Twelvgaige.ID.new(:round)),
      shot_id: Keyword.get(opts, :shot_id, Twelvgaige.ID.new(:shot)),
      repository: request.repository,
      base_ref: request.base_ref,
      auth_profile_id: request.auth_profile,
      sandbox_profile: request.sandbox_profile,
      network_mode: request.network_mode,
      capabilities: capabilities(request),
      allowed_paths: request.allowed_paths,
      budget: request.budget,
      deadline: request.deadline,
      max_depth: 1,
      max_children: 1,
      max_fanout: 1,
      policy_revision: "session-start-v1",
      tasks: [
        %{
          id: "primary",
          agent: request.runtime,
          workflow: @workflow,
          objective: request.objective,
          budget: request.budget,
          capabilities: capabilities(request),
          allowed_paths: request.allowed_paths,
          mounts: [],
          write: request.write?,
          external_effects: [],
          destructive: false
        }
      ]
    })
  end

  defp exact_envelope(plan) do
    Envelope.new(%{
      repositories: [plan.repository],
      agents: [@runtime],
      workflows: [@workflow],
      auth_profiles: [plan.auth_profile_id],
      sandbox_profiles: [plan.sandbox_profile],
      network_modes: [plan.network_mode],
      capabilities: plan.capabilities,
      mounts: [],
      allowed_paths: plan.allowed_paths,
      budget: Map.from_struct(plan.budget),
      deadline: plan.deadline,
      max_depth: 1,
      max_children: 1,
      max_fanout: 1
    })
  end

  defp exact_catalog(plan) do
    %{
      repositories: [plan.repository],
      agents: [@runtime],
      workflows: [@workflow],
      auth_profiles: [plan.auth_profile_id],
      sandbox_profiles: [plan.sandbox_profile],
      network_modes: [plan.network_mode],
      capabilities: plan.capabilities,
      mounts: []
    }
  end

  defp submit(compiled, opts) do
    case Keyword.get(opts, :submit_fun) do
      fun when is_function(fun, 2) ->
        fun.(compiled, opts)

      nil ->
        case Keyword.get(opts, :server) do
          nil -> {:error, internal_error(:manager_control_plane_unavailable)}
          server -> Scheduler.submit(compiled, server: server)
        end
    end
  end

  defp identities(compiled) do
    task = hd(compiled.tasks)
    child_id = ChildRecord.deterministic_id(compiled.plan.id, task.id, task.attempt)

    %{
      child_id: child_id,
      session_id: ChildFactory.delegated_session_id(child_id),
      workspace_id: ChildFactory.workspace_id(child_id)
    }
  end

  defp reserve_inventory(compiled, request, identities, opts) do
    case Keyword.get(opts, :session_control) do
      nil ->
        if Keyword.get(opts, :require_inventory?, false),
          do: {:error, internal_error(:operations_control_plane_unavailable)},
          else: :ok

      server ->
        register = Keyword.get(opts, :session_register_fun, &SessionControl.register/2)

        record = %{
          id: identities.session_id,
          plan_id: compiled.plan.id,
          child_id: identities.child_id,
          status: :preparing,
          runtime: :codex,
          driver: :codex_app_server,
          workspace_id: identities.workspace_id,
          repository: request.repository,
          sandbox_backend: sandbox_backend(request.sandbox),
          sandbox_profile: request.sandbox_profile,
          auth_profile_id: request.auth_profile,
          capabilities: capabilities(request),
          budgets: request.budget,
          deadline: request.deadline,
          created_at: compiled.plan.created_at,
          start_request: request_to_map(request),
          retry_of_session_id: Keyword.get(opts, :retry_of_session_id),
          retry_mode: Keyword.get(opts, :retry_mode)
        }

        case register.(record, server: server) do
          {:ok, _session} ->
            :ok

          {:error, reason} ->
            {:error, internal_error({:session_inventory_reservation_failed, reason})}
        end
    end
  end

  defp submit_or_fail_inventory(compiled, identities, opts) do
    case submit(compiled, opts) do
      {:ok, _plan_id, _status} = accepted ->
        accepted

      {:error, reason} = error ->
        fail_inventory(identities.session_id, reason, opts)
        error
    end
  end

  defp fail_inventory(session_id, reason, opts) do
    case Keyword.get(opts, :session_control) do
      nil ->
        :ok

      server ->
        update = Keyword.get(opts, :session_update_fun, &SessionControl.update/3)
        _ = update.(session_id, %{status: :failed, error: inspect(reason)}, server: server)
        :ok
    end
  end

  defp sandbox_backend("podman"), do: :podman
  defp sandbox_backend("apple-container"), do: :apple_container

  defp capabilities(%{write?: true}), do: ["filesystem.write"]
  defp capabilities(_request), do: []

  defp request_to_map(request) do
    %{
      "runtime" => request.runtime,
      "repository" => request.repository,
      "base_ref" => request.base_ref,
      "task" => request.objective,
      "auth_profile" => request.auth_profile,
      "sandbox" => request.sandbox,
      "network" => request.network_mode |> Atom.to_string() |> String.replace("_", "-"),
      "allow_unrestricted_network" => request.network_mode == :unrestricted,
      "allowed_paths" => request.allowed_paths,
      "write" => request.write?,
      "timeout_ms" => request.timeout_ms,
      "budget" => request.budget
    }
  end

  defp input_error(reason) do
    Error.new(:input_error, :invalid_shell, "invalid session start request",
      details: %{reason: inspect(reason)}
    )
  end

  defp internal_error(reason) do
    Error.new(:internal_error, :store_unavailable, "session start could not be submitted",
      details: %{reason: inspect(reason)}
    )
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end
end
