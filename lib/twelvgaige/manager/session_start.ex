defmodule Twelvgaige.Manager.SessionStart do
  @moduledoc """
  Compiles and submits one explicitly bounded delegated session.

  This is the local-user entry point into the manager control plane. It grants
  exactly the authority named by the request, so normal starts need no manager
  expansion approval. Execution still fails closed when the configured manager
  executor cannot satisfy the selected auth, sandbox, or integration profile.
  """

  alias Twelvgaige.Error

  alias Twelvgaige.Manager.{
    ChildFactory,
    ChildRecord,
    Compiler,
    Envelope,
    Plan,
    SavedPlan,
    Scheduler
  }

  alias Twelvgaige.Operations.{LocalIdentity, SessionControl}
  alias Twelvgaige.Workspace.{Canonical, RepositoryInspection}

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
  @provenance_keys ~w(
    runtime repository base_ref task auth_profile sandbox network
    allow_unrestricted_network allowed_paths source_mode include_untracked include_ignored write
    timeout_ms budget_time_ms budget_tokens budget_cost_micros budget_tool_calls
  )
  @provenance_sources ~w(
    built_in_default environment user_profile repository_profile task_document cli
  )

  @spec start(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def start(attrs, opts \\ [])

  def start(attrs, opts) when is_map(attrs) do
    case replay_existing(attrs, opts) do
      {:ok, result} -> {:ok, result}
      {:error, %Error{} = error} -> {:error, error}
      :none -> start_new(attrs, opts)
    end
  end

  def start(_attrs, _opts), do: {:error, input_error(:session_start_request_invalid)}

  defp start_new(attrs, opts) do
    with {:ok, prepared} <- prepare(attrs, opts) do
      request = prepared.request
      compiled = prepared.compiled
      identities = prepared.identities

      case reserve_inventory(compiled, request, identities, opts) do
        :ok ->
          with {:ok, plan_id, submission} <- submit_or_fail_inventory(compiled, identities, opts) do
            {:ok,
             %{
               plan_id: plan_id,
               child_id: identities.child_id,
               session_id: identities.session_id,
               status: submission,
               request_id: request.request_id,
               replayed: false,
               runtime: request.runtime,
               repository: request.repository,
               base_ref: request.base_ref,
               base_commit: prepared.inspection.base_commit,
               source_mode: source_mode_name(request.source_mode),
               source_state_token: prepared.inspection.source_state_token,
               sandbox: request.sandbox,
               sandbox_profile: request.sandbox_profile,
               network: Atom.to_string(request.network_mode),
               auth_profile: request.auth_profile,
               profile: request.profile,
               plan_digest: request.plan_digest,
               configuration_provenance: request.provenance,
               deadline: DateTime.to_iso8601(request.deadline),
               budget: request.budget
             }}
          else
            {:error, %Error{} = error} -> {:error, error}
            {:error, reason} -> {:error, internal_error(reason)}
          end

        {:replay, result} ->
          {:ok, result}

        {:error, %Error{} = error} ->
          {:error, error}
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, internal_error(reason)}
    end
  end

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
         request_id: request.request_id,
         plan_digest: request.plan_digest,
         plan_id: compiled.plan.id,
         child_id: prepared.identities.child_id,
         session_id: prepared.identities.session_id,
         approval_status: compiled.approval_status,
         runtime: request.runtime,
         repository: request.repository,
         base_ref: request.base_ref,
         base_commit: prepared.inspection.base_commit,
         source_mode: source_mode_name(request.source_mode),
         source_state_token: prepared.inspection.source_state_token,
         include_untracked: request.include_untracked?,
         include_ignored: request.include_ignored?,
         repository_state: %{
           dirtiness: prepared.inspection.dirtiness,
           warnings: prepared.inspection.warnings,
           unsupported_features: prepared.inspection.unsupported_features
         },
         auth_profile: request.auth_profile,
         profile: request.profile,
         configuration_provenance: request.provenance,
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
         {:ok, inspection} <- validate_repository(request, opts),
         request <-
           Map.merge(request, %{
             source_state_token: inspection.source_state_token,
             base_commit: inspection.base_commit
           }),
         :ok <- validate_saved_resolution(request, inspection),
         {:ok, computed_saved_plan} <-
           SavedPlan.build(attrs, saved_resolution(request, inspection)),
         request <- Map.put(request, :plan_digest, computed_saved_plan["plan_digest"]),
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
         inspection: inspection,
         compiled: compiled,
         identities: identities(compiled)
       }}
    end
  end

  defp normalize(attrs, opts) do
    with {:ok, saved_plan} <- normalize_saved_plan(attrs),
         {:ok, request} <- normalize_request(attrs, opts) do
      {:ok, Map.put(request, :saved_plan, saved_plan)}
    end
  end

  defp normalize_request(attrs, opts) do
    runtime = value(attrs, "runtime", @runtime)
    repository = attrs |> value("repository", ".") |> Path.expand()
    base_ref = value(attrs, "base_ref", "HEAD")
    objective = value(attrs, "task")
    auth_profile = value(attrs, "auth_profile")
    profile = value(attrs, "profile")
    sandbox = value(attrs, "sandbox", "podman")
    network = value(attrs, "network", "broker-only")
    allowed_paths = value(attrs, "allowed_paths", [])
    request_id = value(attrs, "request_id")
    source_mode = value(attrs, "source_mode", "committed")
    include_untracked? = value(attrs, "include_untracked", false)
    include_ignored? = value(attrs, "include_ignored", false)
    write? = value(attrs, "write", true)
    timeout_ms = value(attrs, "timeout_ms", 2_700_000)
    budget = value(attrs, "budget", %{})
    provenance = value(attrs, "provenance", %{})
    now = Keyword.get(opts, :now, DateTime.utc_now())

    cond do
      runtime != @runtime ->
        {:error, input_error({:session_runtime_not_supported, runtime})}

      not is_nil(request_id) and (not is_binary(request_id) or String.trim(request_id) == "") ->
        {:error, input_error(:session_request_id_invalid)}

      not present?(objective) ->
        {:error, input_error(:session_task_required)}

      not present?(auth_profile) ->
        {:error, input_error(:session_auth_profile_required)}

      not is_nil(profile) and not present?(profile) ->
        {:error, input_error(:session_profile_invalid)}

      not Map.has_key?(@sandbox_profiles, sandbox) ->
        {:error, input_error({:session_sandbox_invalid, sandbox})}

      not Map.has_key?(@network_modes, network) ->
        {:error, input_error({:session_network_invalid, network})}

      network == "unrestricted" and value(attrs, "allow_unrestricted_network", false) != true ->
        {:error, input_error(:session_unrestricted_network_confirmation_required)}

      not is_list(allowed_paths) or not Enum.all?(allowed_paths, &is_binary/1) ->
        {:error, input_error(:session_allowed_paths_invalid)}

      source_mode not in ["committed", "staged", "working-tree", "working_tree"] ->
        {:error, input_error({:session_source_mode_invalid, source_mode})}

      not is_boolean(include_untracked?) or not is_boolean(include_ignored?) ->
        {:error, input_error(:session_source_include_invalid)}

      include_ignored? and not include_untracked? ->
        {:error, input_error(:include_ignored_requires_include_untracked)}

      (include_untracked? or include_ignored?) and
          source_mode not in ["working-tree", "working_tree"] ->
        {:error, input_error(:source_include_requires_working_tree)}

      not is_boolean(write?) ->
        {:error, input_error(:session_write_mode_invalid)}

      not is_integer(timeout_ms) or timeout_ms <= 0 ->
        {:error, input_error(:session_timeout_invalid)}

      true ->
        with {:ok, budget} <- normalize_budget(budget, timeout_ms),
             {:ok, provenance} <- normalize_provenance(provenance) do
          {:ok,
           %{
             runtime: runtime,
             request_id: request_id,
             repository: repository,
             base_ref: base_ref,
             objective: objective,
             auth_profile: auth_profile,
             profile: profile,
             sandbox: sandbox,
             sandbox_profile: Map.fetch!(@sandbox_profiles, sandbox),
             network_mode: Map.fetch!(@network_modes, network),
             allowed_paths: allowed_paths,
             source_mode: normalize_source_mode(source_mode),
             include_untracked?: include_untracked?,
             include_ignored?: include_ignored?,
             write?: write?,
             timeout_ms: timeout_ms,
             provenance: provenance,
             deadline: DateTime.add(now, timeout_ms, :millisecond),
             budget: budget
           }}
        end
    end
  end

  defp normalize_saved_plan(attrs) do
    with {:ok, saved_plan} <- SavedPlan.optional(value(attrs, "saved_plan")),
         :ok <- SavedPlan.validate_request(saved_plan, attrs) do
      {:ok, saved_plan}
    else
      {:error, reason} -> {:error, input_error(reason)}
    end
  end

  defp validate_saved_resolution(request, inspection) do
    resolution = saved_resolution(request, inspection)

    case SavedPlan.validate_resolution(request.saved_plan, resolution) do
      :ok -> :ok
      {:error, reason} -> {:error, input_error(reason)}
    end
  end

  defp saved_resolution(request, inspection) do
    %{
      repository: request.repository,
      base_ref: request.base_ref,
      base_commit: inspection.base_commit,
      source_mode: source_mode_name(request.source_mode),
      source_state_token: inspection.source_state_token,
      sandbox: request.sandbox,
      sandbox_profile: request.sandbox_profile,
      network: Atom.to_string(request.network_mode),
      allowed_paths: request.allowed_paths,
      write: request.write?,
      capabilities: capabilities(request),
      configuration_provenance: request.provenance
    }
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

  defp normalize_provenance(provenance) when is_map(provenance) do
    unknown = Map.keys(provenance) -- @provenance_keys

    invalid =
      Enum.reject(provenance, fn {key, source} ->
        key in @provenance_keys and source in @provenance_sources and
          (source != "environment" or key == "auth_profile")
      end)

    cond do
      unknown != [] ->
        {:error, input_error({:session_provenance_keys_unknown, Enum.sort(unknown)})}

      invalid != [] ->
        {:error, input_error(:session_provenance_invalid)}

      true ->
        {:ok, provenance}
    end
  end

  defp normalize_provenance(_provenance),
    do: {:error, input_error(:session_provenance_invalid)}

  defp validate_repository(request, opts) do
    cond do
      not File.dir?(request.repository) ->
        {:error, input_error(:session_repository_not_found)}

      true ->
        with {:ok, inspection} <- inspect_repository(request, opts),
             :ok <- admit_inspection(inspection, request.source_mode) do
          {:ok, inspection}
        else
          {:error, %Error{} = error} -> {:error, error}
          {:error, reason} -> {:error, input_error({:session_repository_invalid, reason})}
        end
    end
  end

  defp replay_existing(attrs, opts) do
    with {:ok, request} <- normalize(attrs, opts),
         request_id when is_binary(request_id) <- request.request_id,
         server when not is_nil(server) <- Keyword.get(opts, :session_control),
         identities <- request_identities(request_id, opts),
         get <- Keyword.get(opts, :session_get_fun, &SessionControl.get/2) do
      case get.(identities.session_id, server: server) do
        {:ok, existing} -> replay_result(existing, request, identities)
        {:error, reason} when reason in [:not_found, :session_not_found] -> :none
        {:error, reason} -> {:error, internal_error({:session_request_lookup_failed, reason})}
      end
    else
      {:error, %Error{} = error} -> {:error, error}
      nil -> :none
      _missing -> :none
    end
  end

  defp replay_result(existing, request, identities) do
    with {:ok, digest} <- request_intent_digest(request),
         true <- value(existing, "request_intent_digest") == digest do
      start_request = value(existing, "start_request", %{})

      {:ok,
       %{
         plan_id: value(existing, "plan_id", identities.plan_id),
         child_id: value(existing, "child_id", identities.child_id),
         session_id: value(existing, "id", identities.session_id),
         status: value(existing, "status"),
         request_id: request.request_id,
         replayed: true,
         runtime: value(start_request, "runtime", request.runtime),
         repository: value(start_request, "repository", request.repository),
         base_ref: value(start_request, "base_ref", request.base_ref),
         base_commit: value(existing, "base_commit"),
         source_mode: value(start_request, "source_mode", source_mode_name(request.source_mode)),
         source_state_token: value(existing, "source_state_token"),
         sandbox: value(start_request, "sandbox", request.sandbox),
         sandbox_profile: value(existing, "sandbox_profile", request.sandbox_profile),
         network: value(start_request, "network", Atom.to_string(request.network_mode)),
         auth_profile: value(start_request, "auth_profile", request.auth_profile),
         profile: value(start_request, "profile", request.profile),
         plan_digest: value(start_request, "plan_digest", saved_plan_digest(request)),
         configuration_provenance: value(start_request, "provenance", request.provenance),
         deadline: existing |> value("deadline", request.deadline) |> iso8601(),
         budget: value(start_request, "budget", request.budget)
       }}
    else
      false -> {:error, input_error(:session_request_id_conflict)}
      {:error, reason} -> {:error, internal_error(reason)}
    end
  end

  defp request_identities(request_id, opts) do
    plan_id = Keyword.get(opts, :plan_id) || deterministic_request_id(:manager_plan, request_id)
    child_id = ChildRecord.deterministic_id(plan_id, "primary", 0)

    %{
      plan_id: plan_id,
      child_id: child_id,
      session_id: ChildFactory.delegated_session_id(child_id)
    }
  end

  defp deterministic_request_id(_kind, nil), do: nil

  defp deterministic_request_id(kind, request_id) do
    suffix =
      :crypto.hash(:sha256, "#{kind}\0#{request_id}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 20)

    Twelvgaige.ID.prefix_slug(kind) <> "_" <> suffix
  end

  defp request_intent_digest(request) do
    Canonical.digest("session-start-request", 1, %{
      "runtime" => request.runtime,
      "repository" => request.repository,
      "base_ref" => request.base_ref,
      "task" => request.objective,
      "auth_profile" => request.auth_profile,
      "profile" => request.profile,
      "sandbox" => request.sandbox,
      "network" => request.network_mode,
      "allowed_paths" => request.allowed_paths,
      "source_mode" => request.source_mode,
      "include_untracked" => request.include_untracked?,
      "include_ignored" => request.include_ignored?,
      "write" => request.write?,
      "timeout_ms" => request.timeout_ms,
      "budget" => request.budget
    })
  end

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(value), do: value

  defp inspect_repository(request, opts) do
    case Keyword.get(opts, :repository_inspector) do
      inspector when is_function(inspector, 2) ->
        inspector.(request.repository, base_ref: request.base_ref)

      nil ->
        case Keyword.get(opts, :git_resolver) do
          resolver when is_function(resolver, 3) -> legacy_inspection(request, resolver)
          nil -> RepositoryInspection.inspect(request.repository, base_ref: request.base_ref)
        end
    end
  end

  defp legacy_inspection(request, resolver) do
    with {:ok, commit} <- resolver.(request.repository, request.base_ref, []),
         {:ok, token} <-
           Canonical.digest("legacy-source-state", 1, %{
             repository: request.repository,
             base_ref: request.base_ref,
             base_commit: commit
           }) do
      {:ok,
       %{
         base_commit: commit,
         source_state_token: token,
         source_modes: [:committed, :staged, :working_tree],
         unsupported_features: [],
         warnings: [],
         dirtiness: %{
           clean: true,
           staged: 0,
           unstaged: 0,
           untracked: 0,
           ignored: 0,
           unmerged: 0
         }
       }}
    end
  end

  defp admit_inspection(%{unsupported_features: [_ | _] = features}, _mode),
    do: {:error, {:repository_features_unsupported, features}}

  defp admit_inspection(%{dirtiness: %{unmerged: count}}, _mode) when count > 0,
    do: {:error, :repository_has_unmerged_paths}

  defp admit_inspection(%{dirtiness: %{clean: false}}, :committed),
    do: {:error, :committed_source_requires_clean_repository}

  defp admit_inspection(%{source_modes: modes}, mode) do
    if mode in modes, do: :ok, else: {:error, {:repository_source_mode_unsupported, mode}}
  end

  defp local_identity(opts) do
    identity_fun = Keyword.get(opts, :identity_fun, &LocalIdentity.current/1)

    case identity_fun.([]) do
      {:ok, identity} -> {:ok, identity}
      {:error, reason} -> {:error, internal_error({:local_identity_unavailable, reason})}
    end
  end

  defp build_plan(request, identity, opts) do
    plan_id =
      Keyword.get(opts, :plan_id) ||
        deterministic_request_id(:manager_plan, request.request_id) ||
        Twelvgaige.ID.new(:manager_plan)

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
      source_state_token: request.source_state_token,
      source_mode: request.source_mode,
      include_untracked: request.include_untracked?,
      include_ignored: request.include_ignored?,
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
          source_state_token: request.source_state_token,
          source_mode: request.source_mode,
          include_untracked: request.include_untracked?,
          include_ignored: request.include_ignored?,
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
      plan_id: compiled.plan.id,
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

        {:ok, request_intent_digest} = request_intent_digest(request)

        record = %{
          id: identities.session_id,
          request_id: request.request_id,
          request_intent_digest: request_intent_digest,
          plan_id: compiled.plan.id,
          child_id: identities.child_id,
          status: :preparing,
          runtime: :codex,
          driver: :codex_app_server,
          workspace_id: identities.workspace_id,
          repository: request.repository,
          base_commit: request.base_commit,
          source_state_token: request.source_state_token,
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

          {:error, :session_exists} when is_binary(request.request_id) ->
            get = Keyword.get(opts, :session_get_fun, &SessionControl.get/2)

            case get.(identities.session_id, server: server) do
              {:ok, existing} ->
                case replay_result(existing, request, identities) do
                  {:ok, result} -> {:replay, result}
                  {:error, _reason} = error -> error
                end

              {:error, reason} ->
                {:error, internal_error({:session_inventory_race_lookup_failed, reason})}
            end

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
      "request_id" => request.request_id,
      "runtime" => request.runtime,
      "repository" => request.repository,
      "base_ref" => request.base_ref,
      "task" => request.objective,
      "auth_profile" => request.auth_profile,
      "profile" => request.profile,
      "sandbox" => request.sandbox,
      "network" => request.network_mode |> Atom.to_string() |> String.replace("_", "-"),
      "allow_unrestricted_network" => request.network_mode == :unrestricted,
      "allowed_paths" => request.allowed_paths,
      "source_mode" => source_mode_name(request.source_mode),
      "source_state_token" => request.source_state_token,
      "plan_digest" => saved_plan_digest(request),
      "include_untracked" => request.include_untracked?,
      "include_ignored" => request.include_ignored?,
      "write" => request.write?,
      "timeout_ms" => request.timeout_ms,
      "budget" => request.budget,
      "provenance" => request.provenance
    }
  end

  defp input_error({:session_saved_plan_drift, field}) do
    Error.new(
      :input_error,
      :session_saved_plan_drift,
      "saved session plan drifted at #{field}",
      details: %{field: field}
    )
  end

  defp input_error(reason)
       when reason in [
              :session_saved_plan_digest_mismatch,
              :session_saved_plan_invalid
            ] do
    Error.new(:input_error, :session_saved_plan_invalid, "saved session plan is invalid",
      details: %{cause: Atom.to_string(reason)}
    )
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

  defp normalize_source_mode("working-tree"), do: :working_tree
  defp normalize_source_mode("working_tree"), do: :working_tree
  defp normalize_source_mode("staged"), do: :staged
  defp normalize_source_mode("committed"), do: :committed

  defp source_mode_name(:working_tree), do: "working-tree"
  defp source_mode_name(mode), do: Atom.to_string(mode)

  defp saved_plan_digest(%{plan_digest: digest}) when is_binary(digest), do: digest
  defp saved_plan_digest(%{saved_plan: %{} = plan}), do: plan["plan_digest"]
  defp saved_plan_digest(_request), do: nil

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end
end
