defmodule Twelvgaige.CLI.Commands.SessionStart do
  @moduledoc false

  alias Twelvgaige.Breech.IPC.{Client, Endpoint}
  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}
  alias Twelvgaige.CLI.Commands.SessionFollow
  alias Twelvgaige.CLI.SessionTaskFile
  alias Twelvgaige.Developer.Config

  @default_budget %{
    tokens: 80_000,
    cost_micros: 25_000_000,
    time_ms: 2_700_000,
    tool_calls: 1_000
  }

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
         {:ok, opts} <- apply_profile(opts, deps),
         {:ok, opts} <- apply_task_file(opts) do
      validate(opts)
    end
  end

  defp start(endpoint, opts, deps) do
    client = Keyword.get(deps, :client, &Client.start_session/3)

    client.(endpoint.address, request(opts),
      token: endpoint.token,
      timeout_ms: opts[:ipc_timeout_ms]
    )
  end

  @doc false
  def request(opts) do
    %{
      "runtime" => opts[:runtime],
      "repository" => Path.expand(opts[:repository]),
      "base_ref" => opts[:base_ref],
      "task" => opts[:task],
      "auth_profile" => opts[:auth_profile],
      "sandbox" => opts[:sandbox],
      "network" => opts[:network],
      "allow_unrestricted_network" => opts[:allow_unrestricted_network?],
      "allowed_paths" => opts[:allowed_paths],
      "write" => opts[:write?],
      "timeout_ms" => opts[:timeout_ms],
      "profile" => opts[:resolved_profile],
      "budget" => %{
        "tokens" => opts[:budget_tokens],
        "cost_micros" => opts[:budget_cost_micros],
        "time_ms" => opts[:budget_time_ms],
        "tool_calls" => opts[:budget_tool_calls]
      }
    }
  end

  defp parse_opts(args) do
    parse_opts(args,
      format: :human,
      runtime: "codex",
      repository: ".",
      base_ref: "HEAD",
      task: nil,
      task_file: nil,
      profile: nil,
      resolved_profile: nil,
      auth_profile: System.get_env("TWELVGAIGE_CODEX_AUTH_PROFILE"),
      sandbox: "podman",
      network: "broker-only",
      allow_unrestricted_network?: false,
      allowed_paths: [],
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
    )
  end

  defp parse_opts([], opts), do: {:ok, opts}

  defp parse_opts(["--profile", value | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :profile, value))

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
      else: parse_opts(rest, Keyword.put(opts, :task_file, value))
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

  defp parse_opts([unknown | _rest], _opts), do: {:error, {:unknown_option, unknown}}

  defp validate(opts) do
    cond do
      opts[:runtime] != "codex" ->
        {:error, {:unsupported_session_runtime, opts[:runtime]}}

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
              if MapSet.member?(explicit, key), do: acc, else: Keyword.put(acc, key, value)
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
          if MapSet.member?(explicit, key), do: acc, else: Keyword.put(acc, key, value)
        end)

      {:ok, Keyword.put(merged, :resolved_profile, profile.name)}
    end
  end

  defp put_explicit(opts, key, value) do
    opts
    |> Keyword.put(key, value)
    |> Keyword.update!(:explicit, &MapSet.put(&1, key))
  end

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
    Plan: #{value(result, "plan_id")}
    Child: #{value(result, "child_id")}
    Status: #{value(result, "status")}
    Sandbox: #{value(result, "sandbox")}
    Repository: #{value(result, "repository")}
    #{if(follow, do: "Final status: #{value(follow, "status")} (#{length(value(follow, "events", []))} events)", else: "")}
    """
  end

  defp error(reason, format),
    do: {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}

  defp error_format(args), do: if("json" in args, do: :json, else: :human)
  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))
end
