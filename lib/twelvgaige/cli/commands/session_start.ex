defmodule Twelvgaige.CLI.Commands.SessionStart do
  @moduledoc false

  alias Twelvgaige.Breech.IPC.{Client, Endpoint}
  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}
  alias Twelvgaige.CLI.Commands.SessionFollow
  alias Twelvgaige.CLI.SessionTaskFile
  alias Twelvgaige.Developer.Config
  alias Twelvgaige.Manager.SavedPlan

  @default_budget %{
    tokens: 80_000,
    cost_micros: 25_000_000,
    time_ms: 2_700_000,
    tool_calls: 1_000
  }

  @provenance_keys [
    :runtime,
    :repository,
    :base_ref,
    :task,
    :auth_profile,
    :sandbox,
    :network,
    :allow_unrestricted_network?,
    :allowed_paths,
    :source_mode,
    :include_untracked?,
    :include_ignored?,
    :write?,
    :timeout_ms,
    :budget_time_ms,
    :budget_tokens,
    :budget_cost_micros,
    :budget_tool_calls
  ]

  def run(args, deps \\ []) do
    with {:ok, opts} <- resolve(args, deps),
         {:ok, endpoint} <- discover(opts),
         {:ok, result} <- start(endpoint, opts, deps),
         {:ok, result} <- maybe_follow(endpoint, result, opts, deps) do
      {:ok, format(result, opts[:format]), 0}
    else
      :none -> error(:daemon_unavailable, error_format(args))
      {:error, reason} -> error(reason, error_format(args))
    end
  end

  @doc "Resolves defaults, a developer profile, a task file, and explicit CLI overrides."
  def resolve(args, deps \\ []) when is_list(args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, opts} <- resolve_inputs(opts, deps) do
      validate(opts)
    end
  end

  defp start(endpoint, opts, deps) do
    client = Keyword.get(deps, :client, &Client.start_session/3)

    client.(endpoint.address, request(opts),
      token: endpoint.token,
      request_id: opts[:request_id],
      timeout_ms: opts[:ipc_timeout_ms]
    )
  end

  @doc false
  def request(opts) do
    request =
      %{
        "request_id" => opts[:request_id],
        "runtime" => opts[:runtime],
        "repository" => Path.expand(opts[:repository]),
        "base_ref" => opts[:base_ref],
        "task" => opts[:task],
        "auth_profile" => opts[:auth_profile],
        "sandbox" => opts[:sandbox],
        "network" => opts[:network],
        "allow_unrestricted_network" => opts[:allow_unrestricted_network?],
        "allowed_paths" => opts[:allowed_paths],
        "source_mode" => opts[:source_mode],
        "include_untracked" => opts[:include_untracked?],
        "include_ignored" => opts[:include_ignored?],
        "write" => opts[:write?],
        "timeout_ms" => opts[:timeout_ms],
        "profile" => opts[:resolved_profile],
        "budget" => %{
          "tokens" => opts[:budget_tokens],
          "cost_micros" => opts[:budget_cost_micros],
          "time_ms" => opts[:budget_time_ms],
          "tool_calls" => opts[:budget_tool_calls]
        },
        "provenance" => encode_provenance(opts[:provenance])
      }

    case opts[:saved_plan] do
      %{} = saved_plan -> Map.put(request, "saved_plan", saved_plan)
      nil -> request
    end
  end

  defp parse_opts(args) do
    auth_profile = System.get_env("TWELVGAIGE_CODEX_AUTH_PROFILE")

    defaults =
      [
        format: :human,
        runtime: "codex",
        repository: ".",
        base_ref: "HEAD",
        task: nil,
        task_file: nil,
        plan_file: nil,
        saved_plan: nil,
        profile: nil,
        resolved_profile: nil,
        request_id: Twelvgaige.ID.new(:event),
        auth_profile: auth_profile,
        sandbox: "podman",
        network: "broker-only",
        allow_unrestricted_network?: false,
        allowed_paths: [],
        source_mode: "committed",
        include_untracked?: false,
        include_ignored?: false,
        write?: true,
        timeout_ms: @default_budget.time_ms,
        budget_time_ms: @default_budget.time_ms,
        budget_tokens: @default_budget.tokens,
        budget_cost_micros: @default_budget.cost_micros,
        budget_tool_calls: @default_budget.tool_calls,
        ipc_timeout_ms: 30_000,
        follow?: false,
        follow_timeout_ms: 3_600_000,
        poll_ms: 1_000,
        explicit: MapSet.new()
      ]

    provenance =
      Map.new(@provenance_keys, fn key ->
        source =
          if key == :auth_profile and is_binary(auth_profile),
            do: :environment,
            else: :built_in_default

        {key, source}
      end)

    parse_opts(args, Keyword.put(defaults, :provenance, provenance))
  end

  defp parse_opts([], opts), do: {:ok, opts}

  defp parse_opts(["--profile", value | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :profile, value))

  defp parse_opts(["--request-id", value | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :request_id, value))

  defp parse_opts(["--plan", value | rest], opts) do
    if opts[:plan_file],
      do: {:error, :session_saved_plan_duplicate},
      else: parse_opts(rest, Keyword.put(opts, :plan_file, value))
  end

  defp parse_opts(["--follow" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :follow?, true))

  defp parse_opts(["--follow-timeout-ms", value | rest], opts),
    do: parse_positive(rest, opts, :follow_timeout_ms, value)

  defp parse_opts(["--poll-ms", value | rest], opts),
    do: parse_positive(rest, opts, :poll_ms, value)

  defp parse_opts(["--format", value | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :format, CommandHelpers.parse_format(value)))

  defp parse_opts(["--runtime", value | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :runtime, value))

  defp parse_opts(["--repo", value | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :repository, value))

  defp parse_opts(["--base-ref", value | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :base_ref, value))

  defp parse_opts(["--task", value | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :task, value))

  defp parse_opts(["--task-file", value | rest], opts) do
    if opts[:task_file],
      do: {:error, :session_task_file_duplicate},
      else: parse_opts(rest, put_explicit(opts, :task_file, value))
  end

  defp parse_opts(["--auth-profile", value | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :auth_profile, value))

  defp parse_opts(["--sandbox", value | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :sandbox, value))

  defp parse_opts(["--network", value | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :network, value))

  defp parse_opts(["--unrestricted-network" | rest], opts) do
    opts =
      opts
      |> put_explicit(:network, "unrestricted")
      |> put_explicit(:allow_unrestricted_network?, true)

    parse_opts(rest, opts)
  end

  defp parse_opts(["--allow-path", value | rest], opts),
    do:
      parse_opts(
        rest,
        put_explicit(opts, :allowed_paths, Keyword.fetch!(opts, :allowed_paths) ++ [value])
      )

  defp parse_opts(["--source", value | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :source_mode, value))

  defp parse_opts(["--include-untracked" | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :include_untracked?, true))

  defp parse_opts(["--include-ignored" | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :include_ignored?, true))

  defp parse_opts(["--read-only" | rest], opts),
    do: parse_opts(rest, put_explicit(opts, :write?, false))

  defp parse_opts(["--timeout", value | rest], opts) do
    with {:ok, timeout_ms} <- parse_duration(value) do
      opts =
        opts |> put_explicit(:timeout_ms, timeout_ms) |> put_explicit(:budget_time_ms, timeout_ms)

      parse_opts(rest, opts)
    end
  end

  defp parse_opts(["--budget-tokens", value | rest], opts),
    do: parse_integer(rest, opts, :budget_tokens, value)

  defp parse_opts(["--budget-cost-micros", value | rest], opts),
    do: parse_integer(rest, opts, :budget_cost_micros, value)

  defp parse_opts(["--budget-tool-calls", value | rest], opts),
    do: parse_integer(rest, opts, :budget_tool_calls, value)

  defp parse_opts(["--runtime-dir", value | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :runtime_dir, value))

  defp parse_opts(["--endpoint", value | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :endpoint_path, value))

  defp parse_opts([path | rest], opts) when is_binary(path) do
    cond do
      String.starts_with?(path, "-") ->
        {:error, {:unknown_option, path}}

      opts[:task_file] ->
        {:error, :session_task_file_duplicate}

      true ->
        parse_opts(rest, put_explicit(opts, :task_file, path))
    end
  end

  defp resolve_inputs(opts, deps) do
    case opts[:plan_file] do
      nil ->
        with {:ok, opts} <- apply_profile(opts, deps), do: apply_task_file(opts)

      path ->
        resolve_saved_plan(path, opts, deps)
    end
  end

  defp resolve_saved_plan(path, opts, deps) do
    loader = Keyword.get(deps, :saved_plan_loader, &SavedPlan.load/1)

    with :ok <- reject_saved_plan_overrides(opts),
         {:ok, plan} <- load_saved_plan(loader, path),
         request = value(plan, "request", %{}),
         {:ok, provenance} <- decode_provenance(value(request, "provenance", %{})),
         {:ok, resolved} <- opts_from_saved_plan(opts, plan, provenance) do
      {:ok, resolved}
    end
  end

  defp reject_saved_plan_overrides(opts) do
    overrides = opts[:explicit] |> MapSet.to_list() |> Enum.sort()

    if overrides == [],
      do: :ok,
      else:
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :session_saved_plan_invalid,
           "saved session plan cannot be combined with request overrides",
           details: %{options: Enum.map(overrides, &cli_option_name/1)}
         )}
  end

  defp load_saved_plan(loader, path) do
    case loader.(path) do
      {:ok, plan} -> {:ok, plan}
      {:error, reason} -> {:error, saved_plan_error(reason)}
    end
  end

  defp opts_from_saved_plan(opts, %{"request" => request} = plan, provenance)
       when is_map(request) do
    budget = value(request, "budget", %{})

    resolved = [
      runtime: value(request, "runtime"),
      repository: value(request, "repository"),
      base_ref: value(request, "base_ref"),
      task: value(request, "task"),
      task_file: nil,
      plan_file: opts[:plan_file],
      saved_plan: plan,
      profile: value(request, "profile"),
      resolved_profile: value(request, "profile"),
      request_id: value(request, "request_id"),
      auth_profile: value(request, "auth_profile"),
      sandbox: value(request, "sandbox"),
      network: value(request, "network"),
      allow_unrestricted_network?: value(request, "allow_unrestricted_network"),
      allowed_paths: value(request, "allowed_paths"),
      source_mode: value(request, "source_mode"),
      include_untracked?: value(request, "include_untracked"),
      include_ignored?: value(request, "include_ignored"),
      write?: value(request, "write"),
      timeout_ms: value(request, "timeout_ms"),
      budget_time_ms: value(budget, "time_ms"),
      budget_tokens: value(budget, "tokens"),
      budget_cost_micros: value(budget, "cost_micros"),
      budget_tool_calls: value(budget, "tool_calls"),
      provenance: provenance,
      explicit: MapSet.new()
    ]

    client_options =
      Keyword.take(opts, [
        :format,
        :ipc_timeout_ms,
        :follow?,
        :follow_timeout_ms,
        :poll_ms,
        :runtime_dir,
        :endpoint_path
      ])

    {:ok, Keyword.merge(resolved, client_options)}
  end

  defp opts_from_saved_plan(_opts, _plan, _provenance),
    do: {:error, saved_plan_error(:session_saved_plan_invalid)}

  defp decode_provenance(provenance) when is_map(provenance) do
    Enum.reduce_while(provenance, {:ok, %{}}, fn {key, source}, {:ok, acc} ->
      with {:ok, internal_key} <- provenance_internal_key(key),
           {:ok, internal_source} <- provenance_internal_source(source) do
        {:cont, {:ok, Map.put(acc, internal_key, internal_source)}}
      else
        :error -> {:halt, {:error, saved_plan_error(:session_saved_plan_invalid)}}
      end
    end)
  end

  defp decode_provenance(_provenance),
    do: {:error, saved_plan_error(:session_saved_plan_invalid)}

  defp provenance_internal_key(key) do
    case Enum.find(@provenance_keys, &(provenance_key(&1) == key)) do
      nil -> :error
      internal_key -> {:ok, internal_key}
    end
  end

  defp provenance_internal_source("built_in_default"), do: {:ok, :built_in_default}
  defp provenance_internal_source("environment"), do: {:ok, :environment}
  defp provenance_internal_source("user_profile"), do: {:ok, :user_profile}
  defp provenance_internal_source("repository_profile"), do: {:ok, :repository_profile}
  defp provenance_internal_source("task_document"), do: {:ok, :task_document}
  defp provenance_internal_source("cli"), do: {:ok, :cli}
  defp provenance_internal_source(_source), do: :error

  defp saved_plan_error(reason) do
    message =
      case reason do
        :session_saved_plan_not_found -> "saved session plan was not found"
        :session_saved_plan_permissions_invalid -> "saved session plan is not owner-only"
        _reason -> "saved session plan is invalid"
      end

    cause =
      case reason do
        atom when is_atom(atom) -> Atom.to_string(atom)
        {atom, _details} when is_atom(atom) -> Atom.to_string(atom)
        _reason -> "unknown"
      end

    Twelvgaige.Error.new(:input_error, :session_saved_plan_invalid, message,
      details: %{cause: cause}
    )
  end

  defp cli_option_name(:profile), do: "--profile"
  defp cli_option_name(:request_id), do: "--request-id"
  defp cli_option_name(:task_file), do: "task file"

  defp cli_option_name(key),
    do: "--" <> (key |> Atom.to_string() |> String.trim_trailing("?") |> String.replace("_", "-"))

  defp validate(opts) do
    cond do
      opts[:runtime] != "codex" ->
        {:error, {:unsupported_session_runtime, opts[:runtime]}}

      blank?(opts[:request_id]) ->
        {:error, :session_request_id_invalid}

      blank?(opts[:task]) ->
        {:error, :session_task_required}

      blank?(opts[:auth_profile]) ->
        {:error, :session_auth_profile_required}

      opts[:sandbox] not in ["podman", "apple-container"] ->
        {:error, :session_sandbox_invalid}

      opts[:network] not in ["none", "broker-only", "unrestricted"] ->
        {:error, :session_network_invalid}

      opts[:network] == "unrestricted" and not opts[:allow_unrestricted_network?] ->
        {:error, :session_unrestricted_network_confirmation_required}

      opts[:source_mode] not in ["committed", "staged", "working-tree"] ->
        {:error, :session_source_mode_invalid}

      opts[:include_ignored?] and not opts[:include_untracked?] ->
        {:error, :include_ignored_requires_include_untracked}

      (opts[:include_untracked?] or opts[:include_ignored?]) and
          opts[:source_mode] != "working-tree" ->
        {:error, :source_include_requires_working_tree}

      true ->
        {:ok, opts}
    end
  end

  defp discover(opts) do
    path = opts[:endpoint_path] || Endpoint.default_path(runtime_dir: opts[:runtime_dir])
    Endpoint.discover(path: path)
  end

  defp parse_integer(rest, opts, key, value) do
    case Integer.parse(value) do
      {number, ""} when number >= 0 -> parse_opts(rest, put_explicit(opts, key, number))
      _other -> {:error, {:invalid_non_negative_integer, key}}
    end
  end

  defp parse_positive(rest, opts, key, value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> parse_opts(rest, Keyword.put(opts, key, number))
      _other -> {:error, {:invalid_positive_integer, key}}
    end
  end

  defp maybe_follow(endpoint, result, opts, deps) do
    if opts[:follow?] do
      follow_fun = Keyword.get(deps, :follow_fun, &SessionFollow.follow/4)

      with {:ok, follow} <- follow_fun.(endpoint, value(result, "session_id"), opts, deps) do
        {:ok, Map.put(result, "follow", follow)}
      end
    else
      {:ok, result}
    end
  end

  defp apply_task_file(opts) do
    case opts[:task_file] do
      nil ->
        {:ok, opts}

      path ->
        with {:ok, values} <- SessionTaskFile.load(path) do
          explicit = opts[:explicit]

          merged =
            Enum.reduce(values, opts, fn {key, value}, acc ->
              if MapSet.member?(explicit, key),
                do: acc,
                else: put_with_provenance(acc, key, value, :task_document)
            end)

          {:ok, merged}
        end
    end
  end

  defp apply_profile(opts, deps) do
    config_opts = Keyword.get(deps, :config_opts, [])
    resolver = Keyword.get(deps, :profile_resolver, &Config.resolve_profile/2)

    with {:ok, profile} <- resolver.(opts[:profile], config_opts) do
      explicit = opts[:explicit]

      merged =
        Enum.reduce(profile.values, opts, fn {key, value}, acc ->
          if MapSet.member?(explicit, key),
            do: acc,
            else:
              put_with_provenance(
                acc,
                key,
                value,
                Map.get(Map.get(profile, :provenance, %{}), key, :repository_profile)
              )
        end)

      {:ok, Keyword.put(merged, :resolved_profile, profile.name)}
    end
  end

  defp put_explicit(opts, key, value) do
    opts
    |> Keyword.put(key, value)
    |> put_provenance(key, :cli)
    |> Keyword.update!(:explicit, &MapSet.put(&1, key))
  end

  defp put_with_provenance(opts, key, value, source) do
    opts
    |> Keyword.put(key, value)
    |> put_provenance(key, source)
  end

  defp put_provenance(opts, key, source) do
    if key in @provenance_keys,
      do: Keyword.update!(opts, :provenance, &Map.put(&1, key, source)),
      else: opts
  end

  defp encode_provenance(provenance) when is_map(provenance) do
    Map.new(provenance, fn {key, source} -> {provenance_key(key), Atom.to_string(source)} end)
  end

  defp encode_provenance(_provenance), do: %{}

  defp provenance_key(key), do: key |> Atom.to_string() |> String.trim_trailing("?")

  defp parse_duration(value) do
    case Regex.run(~r/^(\d+)(ms|s|m|h)$/, value, capture: :all_but_first) do
      [amount, unit] ->
        multiplier = %{"ms" => 1, "s" => 1_000, "m" => 60_000, "h" => 3_600_000}[unit]
        {:ok, String.to_integer(amount) * multiplier}

      _other ->
        {:error, :session_timeout_invalid}
    end
  end

  defp format(result, :json), do: CommandHelpers.encode_line(result)

  defp format(result, :human) do
    follow = value(result, "follow", nil)

    """
    Session accepted: #{value(result, "session_id")}
    Request: #{value(result, "request_id")}
    Plan: #{value(result, "plan_id")}
    Child: #{value(result, "child_id")}
    Status: #{value(result, "status")}
    Replay: #{value(result, "replayed", false)}
    Profile: #{value(result, "profile") || "none"}
    Saved plan: #{value(result, "plan_digest") || "none"}
    Sandbox: #{value(result, "sandbox")}
    Repository: #{value(result, "repository")}
    Source: #{value(result, "source_mode")}@#{value(result, "base_commit")}
    Configuration: #{CommandHelpers.format_provenance(value(result, "configuration_provenance", %{}))}
    #{if(follow, do: "Final status: #{value(follow, "status")} (#{length(value(follow, "events", []))} events)", else: "")}
    """
  end

  defp error(reason, format),
    do: {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}

  defp error_format(args), do: if("json" in args, do: :json, else: :human)
  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
  rescue
    ArgumentError -> Map.get(map, key, default)
  end
end
