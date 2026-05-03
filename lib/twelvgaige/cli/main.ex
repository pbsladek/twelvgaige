defmodule Twelvgaige.CLI.Main do
  @moduledoc """
  Command-line entrypoint for Twelvgaige.
  """

  alias Twelvgaige.Breech.Daemon
  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.Breech.IPC.Server
  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Round.Watch
  alias Twelvgaige.Shell
  alias Twelvgaige.Shell.Document, as: ShellDocument
  alias Twelvgaige.Shot

  @usage """
  twelvgaige - deterministic agent orchestration

  Usage:
    twelvgaige --help
    twelvgaige version
    twelvgaige status [--format human|json]
    twelvgaige daemon serve [--transport unix|tcp|npipe] [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige daemon stop [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige daemon paths [--transport unix|tcp|npipe] [--runtime-dir <path>] [--endpoint <path>] [--format human|json]
    twelvgaige shell validate <path> [--format human|json]
    twelvgaige shell normalize <path> [--format json|yaml|toml]
    twelvgaige shell convert <path> --to json|yaml|toml [--output <path>]
    twelvgaige shell reload [path ...] [--format human|json]
    twelvgaige shell list [--kind workflow|agent|all] [--format human|json]
    twelvgaige shell show <shell-id> [--kind workflow|agent] [--format human|json]
    twelvgaige round run <workflow-shell-path-or-id> --input <json-or-path> [--agent-shell <path>] [--no-agent-discovery] [--untrusted-root] [--format human|json] [--approve-safety] [--detach]
    twelvgaige round list [--format human|json] [--status <status>]
    twelvgaige round show <round-id> [--format human|json]
    twelvgaige round watch <round-id> [--format human|ndjson] [--after-seq <seq>] [--limit <count>] [--follow] [--until-terminal] [--timeout-ms <ms>]
    twelvgaige round audit <round-id> [--format human|json|ndjson|checkpoint] [--after-seq <seq>] [--limit <count>]
    twelvgaige round approve <round-id> --shot <safety-shot-id> [--reason <text>] [--format human|json]
    twelvgaige round reject <round-id> --shot <safety-shot-id> [--reason <text>] [--format human|json]
    twelvgaige round cancel <round-id> [--reason <text>] [--format human|json]
  """

  @spec main([String.t()]) :: :ok
  def main(args) do
    start_runtime!()
    main_started(args)
  end

  @spec main_started([String.t()]) :: :ok
  def main_started(args) do
    dispatch(args)
  end

  defp dispatch(["daemon", "serve" | args]), do: serve_daemon(args)

  defp dispatch(["round", "watch", round_id | args]),
    do: stream_watch_round(round_id, args, &IO.write/1)

  defp dispatch(args) do
    args
    |> run()
    |> emit()
  end

  defp start_runtime! do
    with :ok <- prepare_escript_priv(),
         {:ok, _apps} <- Application.ensure_all_started(:twelvgaige) do
      :ok
    else
      {:error, reason} ->
        IO.write(:stderr, "failed to start twelvgaige: #{inspect(reason)}\n")
        System.halt(8)
    end
  end

  @escript_priv_files [
    ~c"exqlite/ebin/exqlite.app",
    ~c"exqlite/priv/sqlite3_nif.so",
    ~c"exqlite/priv/sqlite3_nif.dll",
    ~c"exqlite/priv/sqlite3_nif.dylib"
  ]

  defp prepare_escript_priv do
    script = :escript.script_name() |> List.to_string()

    if File.regular?(script) do
      extract_escript_priv(script)
    else
      :ok
    end
  end

  defp extract_escript_priv(script) do
    with {:ok, entries} <- :escript.extract(String.to_charlist(script), [:compile_source]),
         archive when is_binary(archive) <- Keyword.get(entries, :archive),
         {:ok, files} <- :zip.extract(archive, [:memory, {:file_list, @escript_priv_files}]) do
      root = Path.join(System.tmp_dir!(), "twelvgaige-escript-#{:os.getpid()}")
      Enum.each(files, &write_escript_priv_file(root, &1))
      :code.add_patha(root |> Path.join("exqlite/ebin") |> String.to_charlist())
      :ok
    else
      {:error, {:badarg, _}} -> :ok
      {:error, :bad_central_directory} -> :ok
      {:error, _reason} = error -> error
      nil -> :ok
      _other -> :ok
    end
  end

  defp write_escript_priv_file(root, {path, contents}) do
    path = List.to_string(path)
    destination = Path.join(root, path)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, contents)
  end

  @spec run([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def run(["--help"]), do: {:ok, @usage, 0}
  def run(["-h"]), do: {:ok, @usage, 0}
  def run(["version"]), do: {:ok, Twelvgaige.version() <> "\n", 0}
  def run(["status"]), do: status(format: :human)
  def run(["status", "--format", format]), do: status(format: parse_format(format))
  def run(["daemon", "paths" | args]), do: daemon_paths(args)
  def run(["daemon", "stop" | args]), do: stop_daemon(args)
  def run(["shell", "validate", path]), do: validate_shell(path, format: :human)

  def run(["shell", "validate", path, "--format", format]),
    do: validate_shell(path, format: parse_format(format))

  def run(["shell", "normalize", path | args]), do: normalize_shell(path, args)
  def run(["shell", "convert", path | args]), do: convert_shell(path, args)
  def run(["shell", "reload" | args]), do: reload_shells(args)
  def run(["shell", "list" | args]), do: list_shells(args)
  def run(["shell", "show", shell_id | args]), do: show_shell(shell_id, args)
  def run(["round", "run", path | args]), do: run_round(path, args)
  def run(["round", "list" | args]), do: list_rounds(args)
  def run(["round", "show", round_id | args]), do: show_round(round_id, args)
  def run(["round", "watch", round_id | args]), do: watch_round(round_id, args)
  def run(["round", "audit", round_id | args]), do: audit_round(round_id, args)
  def run(["round", "approve", round_id | args]), do: safety_decision(:approve, round_id, args)
  def run(["round", "reject", round_id | args]), do: safety_decision(:reject, round_id, args)
  def run(["round", "cancel", round_id | args]), do: cancel_round(round_id, args)
  def run([]), do: {:ok, @usage, 0}

  def run([command | _]) do
    {:ok, "unknown command: #{command}\n\n" <> @usage, 4}
  end

  defp emit({:ok, output, 0}) do
    IO.write(output)
    :ok
  end

  defp emit({:ok, output, code}) do
    IO.write(:stderr, output)
    System.halt(code)
  end

  defp serve_daemon(args) do
    with {:ok, opts} <- parse_daemon_opts(args),
         {:ok, pid} <- Daemon.start_link(daemon_start_opts(opts)) do
      output =
        pid
        |> Server.address()
        |> format_daemon_started(opts[:format])

      IO.write(output)
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    else
      {:error, error} ->
        IO.write(:stderr, format_command_error(error, :human))
        System.halt(ExitCode.for_error(error))
    end
  end

  defp daemon_start_opts(opts) do
    opts
    |> Keyword.take([:runtime_dir, :transport, :endpoint_path])
  end

  defp daemon_paths(args) do
    with {:ok, opts} <- parse_daemon_opts(args) do
      {:ok, format_daemon_paths(Twelvgaige.daemon_paths(daemon_start_opts(opts)), opts[:format]),
       0}
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp stop_daemon(args) do
    with {:ok, opts} <- parse_daemon_opts(args) do
      case Twelvgaige.stop_daemon(daemon_stop_opts(opts)) do
        :ok ->
          {:ok, format_daemon_stop(opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp daemon_stop_opts(opts) do
    cond do
      endpoint_path = opts[:endpoint_path] ->
        [endpoint_path: endpoint_path]

      runtime_dir = opts[:runtime_dir] ->
        [endpoint_path: Endpoint.default_path(runtime_dir: runtime_dir)]

      true ->
        []
    end
  end

  defp parse_daemon_opts(args),
    do:
      parse_daemon_opts(args,
        format: :human,
        transport: nil,
        runtime_dir: nil,
        endpoint_path: nil
      )

  defp parse_daemon_opts([], opts) do
    opts =
      opts
      |> compact_nil(:transport)
      |> compact_nil(:runtime_dir)
      |> compact_nil(:endpoint_path)

    {:ok, opts}
  end

  defp parse_daemon_opts(["--format", format | rest], opts) do
    parse_daemon_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_daemon_opts(["--transport", transport | rest], opts)
       when transport in ["unix", "tcp", "npipe"] do
    parse_daemon_opts(rest, Keyword.put(opts, :transport, parse_transport(transport)))
  end

  defp parse_daemon_opts(["--transport", _transport | _rest], _opts) do
    {:error,
     Twelvgaige.Error.new(:input_error, :invalid_shell, "--transport must be unix, tcp, or npipe")}
  end

  defp parse_daemon_opts(["--runtime-dir", runtime_dir | rest], opts) do
    parse_daemon_opts(rest, Keyword.put(opts, :runtime_dir, runtime_dir))
  end

  defp parse_daemon_opts(["--endpoint", endpoint_path | rest], opts) do
    parse_daemon_opts(rest, Keyword.put(opts, :endpoint_path, endpoint_path))
  end

  defp parse_daemon_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_transport("unix"), do: :unix
  defp parse_transport("tcp"), do: :tcp
  defp parse_transport("npipe"), do: :npipe

  defp compact_nil(opts, key) do
    case Keyword.get(opts, key) do
      nil -> Keyword.delete(opts, key)
      _value -> opts
    end
  end

  defp validate_shell(path, opts) do
    format = Keyword.fetch!(opts, :format)

    case Twelvgaige.validate_shell(path) do
      {:ok, shell} -> {:ok, format_shell(shell, format), 0}
      {:error, error} -> {:ok, format_error(error, format), 4}
    end
  end

  defp normalize_shell(path, args) do
    with {:ok, opts} <- parse_shell_normalize_opts(args),
         {:ok, shell} <- Twelvgaige.validate_shell(path),
         {:ok, contents} <- ShellDocument.encode(shell, opts[:format]) do
      {:ok, contents, 0}
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp convert_shell(path, args) do
    with {:ok, opts} <- parse_shell_convert_opts(args),
         {:ok, shell} <- Twelvgaige.validate_shell(path),
         {:ok, contents} <- ShellDocument.encode(shell, opts[:to]) do
      case opts[:output] do
        nil ->
          {:ok, contents, 0}

        output_path ->
          write_converted_shell(output_path, contents)
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp write_converted_shell(output_path, contents) do
    with :ok <- File.mkdir_p(Path.dirname(output_path)),
         :ok <- File.write(output_path, contents) do
      {:ok, "converted shell: #{output_path}\n", 0}
    else
      {:error, reason} ->
        error =
          Twelvgaige.Error.new(:input_error, :invalid_shell, "unable to write converted shell",
            details: %{path: output_path, reason: inspect(reason)}
          )

        {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp reload_shells(args) do
    with {:ok, opts} <- parse_shell_reload_opts(args) do
      reload_opts =
        case Keyword.fetch!(opts, :paths) do
          [] -> []
          paths -> [paths: paths]
        end

      case Twelvgaige.reload_shells(reload_opts) do
        {:ok, summary} ->
          {:ok, format_shell_reload(summary, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp list_shells(args) do
    with {:ok, opts} <- parse_shell_list_opts(args),
         {:ok, shells} <- cached_shells(opts[:kind]) do
      {:ok, format_shell_list(shells, opts[:format]), 0}
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp show_shell(shell_id, args) do
    with {:ok, opts} <- parse_shell_show_opts(args) do
      case Twelvgaige.get_shell(shell_id, kind: opts[:kind]) do
        {:ok, shell} ->
          {:ok, format_shell_detail(shell, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_shell_reload_opts(args),
    do: parse_shell_reload_opts(args, format: :human, paths: [])

  defp parse_shell_normalize_opts(args), do: parse_shell_normalize_opts(args, format: :json)

  defp parse_shell_normalize_opts([], opts), do: {:ok, opts}

  defp parse_shell_normalize_opts(["--format", format | rest], opts) do
    case parse_shell_document_format(format) do
      {:ok, format} -> parse_shell_normalize_opts(rest, Keyword.put(opts, :format, format))
      {:error, _error} = error -> error
    end
  end

  defp parse_shell_normalize_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_convert_opts(args), do: parse_shell_convert_opts(args, to: nil, output: nil)

  defp parse_shell_convert_opts([], opts) do
    if is_nil(Keyword.get(opts, :to)) do
      {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--to is required")}
    else
      {:ok, opts}
    end
  end

  defp parse_shell_convert_opts(["--to", format | rest], opts) do
    case parse_shell_document_format(format) do
      {:ok, format} -> parse_shell_convert_opts(rest, Keyword.put(opts, :to, format))
      {:error, _error} = error -> error
    end
  end

  defp parse_shell_convert_opts(["--output", output | rest], opts) do
    parse_shell_convert_opts(rest, Keyword.put(opts, :output, output))
  end

  defp parse_shell_convert_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_reload_opts([], opts), do: {:ok, opts}

  defp parse_shell_reload_opts(["--format", format | rest], opts) do
    parse_shell_reload_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_shell_reload_opts([path | rest], opts) do
    if String.starts_with?(path, "--") do
      {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{path}")}
    else
      parse_shell_reload_opts(rest, Keyword.update!(opts, :paths, &(&1 ++ [path])))
    end
  end

  defp parse_shell_list_opts(args), do: parse_shell_list_opts(args, format: :human, kind: :all)

  defp parse_shell_list_opts([], opts), do: {:ok, opts}

  defp parse_shell_list_opts(["--format", format | rest], opts) do
    parse_shell_list_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_shell_list_opts(["--kind", kind | rest], opts) do
    case parse_shell_kind(kind, [:workflow, :agent, :all]) do
      {:ok, kind} -> parse_shell_list_opts(rest, Keyword.put(opts, :kind, kind))
      {:error, _error} = error -> error
    end
  end

  defp parse_shell_list_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_show_opts(args), do: parse_shell_show_opts(args, format: :human, kind: :any)

  defp parse_shell_show_opts([], opts), do: {:ok, opts}

  defp parse_shell_show_opts(["--format", format | rest], opts) do
    parse_shell_show_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_shell_show_opts(["--kind", kind | rest], opts) do
    case parse_shell_kind(kind, [:workflow, :agent]) do
      {:ok, kind} -> parse_shell_show_opts(rest, Keyword.put(opts, :kind, kind))
      {:error, _error} = error -> error
    end
  end

  defp parse_shell_show_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_shell_kind(kind, allowed) do
    parsed =
      case kind do
        "workflow" -> :workflow
        "agent" -> :agent
        "all" -> :all
        _other -> :invalid
      end

    if parsed in allowed do
      {:ok, parsed}
    else
      allowed = allowed |> Enum.map(&Atom.to_string/1) |> Enum.join(", ")

      {:error,
       Twelvgaige.Error.new(:input_error, :invalid_shell, "--kind must be one of #{allowed}")}
    end
  end

  defp cached_shells(:workflow), do: Twelvgaige.list_shells()
  defp cached_shells(:agent), do: Twelvgaige.list_agents()

  defp cached_shells(:all) do
    with {:ok, workflows} <- Twelvgaige.list_shells(),
         {:ok, agents} <- Twelvgaige.list_agents() do
      {:ok, Enum.sort_by(workflows ++ agents, &{shell_kind(&1), &1.id})}
    end
  end

  defp status(opts) do
    format = Keyword.fetch!(opts, :format)

    case Twelvgaige.status() do
      {:ok, status} -> {:ok, format_status(status, format), 0}
      {:error, :daemon_unavailable} -> {:ok, "daemon unavailable\n", 5}
      {:error, error} -> {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp run_round(path, args) do
    with {:ok, opts} <- parse_round_opts(args),
         {:ok, input} <- read_input(opts.input) do
      format = opts.format

      case run_round_mode(path, input, opts) do
        {:ok, %Snapshot{} = snapshot} ->
          {:ok, format_snapshot(snapshot, format), ExitCode.for_snapshot(snapshot)}

        {:ok, round_id} when is_binary(round_id) ->
          {:ok, format_detached_round(round_id, format), 0}

        {:error, error} ->
          {:ok, format_command_error(error, format), ExitCode.for_error(error)}
      end
    else
      {:error, error} ->
        {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_round_opts(args),
    do:
      parse_round_opts(args, %{
        input: nil,
        format: :human,
        profile: nil,
        approve_safety?: false,
        detach?: false,
        agent_shells: [],
        discover_agents?: true,
        trusted_root?: true
      })

  defp parse_round_opts([], %{input: nil}) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--input is required")}
  end

  defp parse_round_opts([], opts), do: {:ok, opts}

  defp parse_round_opts(["--input", input | rest], opts) do
    parse_round_opts(rest, %{opts | input: input})
  end

  defp parse_round_opts(["--format", format | rest], opts) do
    parse_round_opts(rest, %{opts | format: parse_format(format)})
  end

  defp parse_round_opts(["--profile", profile | rest], opts) do
    case Twelvgaige.RuntimeProfile.normalize(profile) do
      {:ok, profile} ->
        parse_round_opts(rest, %{opts | profile: profile})

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_round_opts(["--agent-shell", path | rest], opts) do
    parse_round_opts(rest, %{opts | agent_shells: opts.agent_shells ++ [path]})
  end

  defp parse_round_opts(["--no-agent-discovery" | rest], opts) do
    parse_round_opts(rest, %{opts | discover_agents?: false})
  end

  defp parse_round_opts(["--untrusted-root" | rest], opts) do
    parse_round_opts(rest, %{opts | trusted_root?: false})
  end

  defp parse_round_opts(["--approve-safety" | rest], opts) do
    parse_round_opts(rest, %{opts | approve_safety?: true})
  end

  defp parse_round_opts(["--detach" | rest], opts) do
    parse_round_opts(rest, %{opts | detach?: true})
  end

  defp parse_round_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_format("json"), do: :json
  defp parse_format("human"), do: :human
  defp parse_format(_other), do: :human

  defp parse_shell_document_format("json"), do: {:ok, :json}
  defp parse_shell_document_format("yaml"), do: {:ok, :yaml}
  defp parse_shell_document_format("toml"), do: {:ok, :toml}

  defp parse_shell_document_format(_format) do
    {:error,
     Twelvgaige.Error.new(:input_error, :invalid_shell, "format must be json, yaml, or toml")}
  end

  defp parse_watch_format("ndjson"), do: :ndjson
  defp parse_watch_format("human"), do: :human
  defp parse_watch_format(_other), do: :human

  defp parse_audit_format("json"), do: :json
  defp parse_audit_format("checkpoint"), do: :checkpoint
  defp parse_audit_format(format), do: parse_watch_format(format)

  defp round_run_opts(opts) do
    []
    |> maybe_put_profile(opts)
    |> maybe_put_approve_all_safety(opts)
    |> maybe_put_agent_shells(opts)
    |> maybe_put_agent_discovery(opts)
  end

  defp maybe_put_profile(run_opts, %{profile: nil}), do: run_opts

  defp maybe_put_profile(run_opts, %{profile: profile}) do
    Keyword.put(run_opts, :profile, profile)
  end

  defp maybe_put_approve_all_safety(run_opts, %{approve_safety?: true}) do
    Keyword.put(run_opts, :approve_all_safety?, true)
  end

  defp maybe_put_approve_all_safety(run_opts, _opts), do: run_opts

  defp maybe_put_agent_shells(run_opts, %{agent_shells: []}), do: run_opts

  defp maybe_put_agent_shells(run_opts, %{agent_shells: agent_shells}) do
    Keyword.put(run_opts, :agent_shells, agent_shells)
  end

  defp maybe_put_agent_discovery(run_opts, opts) do
    run_opts
    |> Keyword.put(:discover_agents?, opts.discover_agents?)
    |> Keyword.put(:trusted_root?, opts.trusted_root?)
  end

  defp run_round_mode(path, input, %{detach?: true} = opts) do
    Twelvgaige.run_round(path, input, round_run_opts(opts))
  end

  defp run_round_mode(path, input, opts) do
    Twelvgaige.run_round_sync(path, input, round_run_opts(opts))
  end

  defp list_rounds(args) do
    with {:ok, opts} <- parse_list_opts(args) do
      case Twelvgaige.list_rounds(Keyword.take(opts, [:status])) do
        {:ok, rounds} ->
          {:ok, format_round_list(rounds, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_list_opts(args), do: parse_list_opts(args, format: :human)

  defp parse_list_opts([], opts), do: {:ok, opts}

  defp parse_list_opts(["--format", format | rest], opts) do
    parse_list_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_list_opts(["--status", status | rest], opts) do
    parse_list_opts(rest, Keyword.put(opts, :status, status))
  end

  defp parse_list_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp show_round(round_id, args) do
    with {:ok, opts} <- parse_show_opts(args) do
      case Twelvgaige.get_round(round_id) do
        {:ok, snapshot} ->
          {:ok, format_snapshot(snapshot, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_show_opts(args), do: parse_show_opts(args, format: :human)

  defp parse_show_opts([], opts), do: {:ok, opts}

  defp parse_show_opts(["--format", format | rest], opts) do
    parse_show_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_show_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp watch_round(round_id, args) do
    with {:ok, opts} <- parse_watch_opts(args) do
      case Watch.collect(round_id, opts) do
        {:ok, events} ->
          {:ok, format_events(events, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp stream_watch_round(round_id, args, write) do
    with {:ok, opts} <- parse_watch_opts(args) do
      result =
        Watch.stream(
          round_id,
          fn events ->
            write.(format_events(events, opts[:format]))
            :ok
          end,
          opts
        )

      case result do
        {:ok, %{delivered: 0}} ->
          write.(format_events([], opts[:format]))
          :ok

        {:ok, _summary} ->
          :ok

        {:error, error} ->
          output = format_command_error(error, :human)
          IO.write(:stderr, output)
          System.halt(ExitCode.for_error(error))

        {:halt, reason} ->
          output = format_command_error(reason, :human)
          IO.write(:stderr, output)
          System.halt(ExitCode.for_error(reason))
      end
    else
      {:error, error} ->
        output = format_command_error(error, :human)
        IO.write(:stderr, output)
        System.halt(ExitCode.for_error(error))
    end
  end

  defp parse_watch_opts(args),
    do:
      parse_watch_opts(args,
        format: :human,
        after_seq: 0,
        limit: 100,
        follow?: false,
        until_terminal?: false,
        timeout_ms: 30_000
      )

  defp parse_watch_opts([], opts), do: {:ok, opts}

  defp parse_watch_opts(["--format", format | rest], opts) do
    parse_watch_opts(rest, Keyword.put(opts, :format, parse_watch_format(format)))
  end

  defp parse_watch_opts(["--after-seq", seq | rest], opts) do
    case parse_non_negative_integer(seq) do
      {:ok, seq} ->
        parse_watch_opts(rest, Keyword.put(opts, :after_seq, seq))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--after-seq must be >= 0")}
    end
  end

  defp parse_watch_opts(["--limit", limit | rest], opts) do
    case parse_positive_integer(limit) do
      {:ok, limit} ->
        parse_watch_opts(rest, Keyword.put(opts, :limit, limit))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--limit must be > 0")}
    end
  end

  defp parse_watch_opts(["--follow" | rest], opts) do
    parse_watch_opts(rest, Keyword.put(opts, :follow?, true))
  end

  defp parse_watch_opts(["--until-terminal" | rest], opts) do
    opts =
      opts
      |> Keyword.put(:follow?, true)
      |> Keyword.put(:until_terminal?, true)

    parse_watch_opts(rest, opts)
  end

  defp parse_watch_opts(["--timeout-ms", timeout_ms | rest], opts) do
    case parse_non_negative_integer(timeout_ms) do
      {:ok, timeout_ms} ->
        parse_watch_opts(rest, Keyword.put(opts, :timeout_ms, timeout_ms))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--timeout-ms must be >= 0")}
    end
  end

  defp parse_watch_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp audit_round(round_id, args) do
    with {:ok, opts} <- parse_audit_opts(args) do
      case Twelvgaige.list_audit_events(round_id, Keyword.take(opts, [:after_seq, :limit])) do
        {:ok, events} ->
          {:ok, format_audit_events(events, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_audit_opts(args),
    do: parse_audit_opts(args, format: :human, after_seq: 0, limit: 100)

  defp parse_audit_opts([], opts), do: {:ok, opts}

  defp parse_audit_opts(["--format", format | rest], opts) do
    parse_audit_opts(rest, Keyword.put(opts, :format, parse_audit_format(format)))
  end

  defp parse_audit_opts(["--after-seq", seq | rest], opts) do
    case parse_non_negative_integer(seq) do
      {:ok, seq} ->
        parse_audit_opts(rest, Keyword.put(opts, :after_seq, seq))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--after-seq must be >= 0")}
    end
  end

  defp parse_audit_opts(["--limit", limit | rest], opts) do
    case parse_positive_integer(limit) do
      {:ok, limit} ->
        parse_audit_opts(rest, Keyword.put(opts, :limit, limit))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--limit must be > 0")}
    end
  end

  defp parse_audit_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp safety_decision(decision, round_id, args) do
    with {:ok, opts} <- parse_safety_opts(args),
         {:ok, shot_id} <- required_safety_shot(opts) do
      result =
        case decision do
          :approve ->
            Twelvgaige.approve_safety(round_id, shot_id,
              reason: opts[:reason],
              actor: "human:cli"
            )

          :reject ->
            Twelvgaige.reject_safety(round_id, shot_id,
              reason: opts[:reason],
              actor: "human:cli"
            )
        end

      case result do
        :ok ->
          {:ok, format_safety_decision(decision, round_id, shot_id, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_safety_opts(args), do: parse_safety_opts(args, format: :human)

  defp parse_safety_opts([], opts), do: {:ok, opts}

  defp parse_safety_opts(["--shot", shot_id | rest], opts) do
    parse_safety_opts(rest, Keyword.put(opts, :shot_id, shot_id))
  end

  defp parse_safety_opts(["--reason", reason | rest], opts) do
    parse_safety_opts(rest, Keyword.put(opts, :reason, reason))
  end

  defp parse_safety_opts(["--format", format | rest], opts) do
    parse_safety_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_safety_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp required_safety_shot(opts) do
    case Keyword.get(opts, :shot_id) do
      shot_id when is_binary(shot_id) and shot_id != "" ->
        {:ok, shot_id}

      _missing ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--shot is required")}
    end
  end

  defp cancel_round(round_id, args) do
    with {:ok, opts} <- parse_cancel_opts(args) do
      case Twelvgaige.cancel_round(round_id, reason: opts[:reason], actor: "human:cli") do
        :ok ->
          {:ok, format_cancel(round_id, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_cancel_opts(args), do: parse_cancel_opts(args, format: :human)

  defp parse_cancel_opts([], opts), do: {:ok, opts}

  defp parse_cancel_opts(["--reason", reason | rest], opts) do
    parse_cancel_opts(rest, Keyword.put(opts, :reason, reason))
  end

  defp parse_cancel_opts(["--format", format | rest], opts) do
    parse_cancel_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_cancel_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp read_input("-") do
    :stdio
    |> IO.read(:eof)
    |> decode_json("stdin")
  end

  defp read_input(input) when is_binary(input) do
    trimmed = String.trim_leading(input)

    if String.starts_with?(trimmed, ["{", "["]) do
      decode_json(input, "inline JSON")
    else
      case File.read(input) do
        {:ok, contents} ->
          decode_json(contents, input)

        {:error, reason} ->
          {:error,
           Twelvgaige.Error.new(:input_error, :invalid_shell, "unable to read input file",
             details: %{path: input, reason: inspect(reason)}
           )}
      end
    end
  end

  defp decode_json(contents, source) do
    case Jason.decode(contents) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "round input must be a JSON object",
           details: %{source: source}
         )}

      {:error, error} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "invalid JSON input",
           details: %{source: source, reason: Exception.message(error)}
         )}
    end
  end

  defp format_shell(%Shell.Workflow{} = shell, :human) do
    "valid workflow shell: #{shell.id} #{shell.version}\n"
  end

  defp format_shell(%Shell.Agent{} = shell, :human) do
    "valid agent shell: #{shell.id} #{shell.version || "unversioned"}\n"
  end

  defp format_shell(shell, :json) do
    shell
    |> shell_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_detail(%Shell.Workflow{} = shell, :human) do
    shots =
      shell.shots
      |> Enum.map(&"  - #{&1.id} [#{&1.kind}]")
      |> Enum.join("\n")

    """
    Workflow shell: #{shell.id} #{shell.version}
    Name: #{shell.name || ""}
    Shots:
    #{shots}
    """
  end

  defp format_shell_detail(%Shell.Agent{} = shell, :human) do
    """
    Agent shell: #{shell.id} #{shell.version || "unversioned"}
    Name: #{shell.name || ""}
    Provider: #{shell.provider}
    Model: #{shell.model}
    """
  end

  defp format_shell_detail(shell, :json), do: format_shell(shell, :json)

  defp format_shell_list([], :human), do: "No shells.\n"

  defp format_shell_list(shells, :human) do
    shells
    |> Enum.map(fn shell ->
      "#{shell_kind(shell)}  #{shell.id}  #{shell.version || "unversioned"}"
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_shell_list(shells, :json) do
    shells
    |> Enum.map(&shell_map/1)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_reload(summary, :json) do
    summary
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_shell_reload(summary, :human) do
    paths = value(summary, :paths, [])
    workflows = value(summary, :workflows, [])
    agents = value(summary, :agents, [])

    """
    Shell cache reloaded
    Paths: #{length(paths)}
    Workflows: #{format_id_list(workflows)}
    Agents: #{format_id_list(agents)}
    """
  end

  defp shell_map(%Shell.Workflow{} = shell) do
    %{
      kind: "workflow",
      id: shell.id,
      name: shell.name,
      version: shell.version,
      shots: Enum.map(shell.shots, & &1.id)
    }
  end

  defp shell_map(%Shell.Agent{} = shell) do
    %{
      kind: "agent",
      id: shell.id,
      name: shell.name,
      version: shell.version,
      provider: shell.provider,
      model: shell.model
    }
  end

  defp shell_kind(%Shell.Workflow{}), do: "workflow"
  defp shell_kind(%Shell.Agent{}), do: "agent"

  defp format_id_list([]), do: "none"
  defp format_id_list(ids), do: Enum.join(ids, ", ")

  defp format_snapshot(%Snapshot{} = snapshot, :json) do
    snapshot
    |> Snapshot.to_map()
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_snapshot(%Snapshot{} = snapshot, :human) do
    shot_lines =
      snapshot.shots
      |> Enum.map(fn %Shot.State{} = shot -> "  - #{shot.id} [#{shot.status}]" end)
      |> Enum.join("\n")

    """
    Round:  #{snapshot.id}
    Shell:  #{snapshot.shell_id} #{snapshot.shell_version}
    Status: #{snapshot.status}
    Shots:
    #{shot_lines}
    """
  end

  defp format_detached_round(round_id, :json) do
    %{id: round_id, status: "queued"}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_detached_round(round_id, :human), do: "Round queued: #{round_id}\n"

  defp format_round_list(rounds, :json) do
    rounds
    |> Enum.map(&Snapshot.to_map/1)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_round_list([], :human), do: "No rounds.\n"

  defp format_round_list(rounds, :human) do
    rows =
      rounds
      |> Enum.map(fn %Snapshot{} = snapshot ->
        "#{snapshot.id}  #{snapshot.shell_id}  #{snapshot.status}"
      end)
      |> Enum.join("\n")

    rows <> "\n"
  end

  defp format_events([], :human), do: "No events.\n"
  defp format_events([], :ndjson), do: ""

  defp format_events(events, :ndjson) do
    events
    |> Enum.map(fn %Event{} = event -> event |> Event.to_map() |> Jason.encode!() end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_events(events, :human) do
    events
    |> Enum.map(fn %Event{} = event ->
      status = value(event.payload, :status)
      detail = if status, do: " status=#{status}", else: ""
      "##{event.seq} #{event.event_type}#{detail}"
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_audit_events([], :human), do: "No audit events.\n"
  defp format_audit_events([], :ndjson), do: ""

  defp format_audit_events(events, :json) do
    events
    |> Enum.map(&AuditEvent.to_map/1)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_audit_events(events, :checkpoint) do
    events
    |> Twelvgaige.Audit.Checkpoint.export(scope: :audit)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_audit_events(events, :ndjson) do
    events
    |> Enum.map(fn event -> event |> AuditEvent.to_map() |> Jason.encode!() end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_audit_events(events, :human) do
    events
    |> Enum.map(fn event ->
      event = AuditEvent.to_map(event)
      seq = value(event, :seq, "?")
      event_type = value(event, :event_type, "unknown")
      actor = value(event, :actor)
      shot_id = value(event, :shot_id)

      detail =
        [
          if(actor, do: "actor=#{actor}"),
          if(shot_id, do: "shot=#{shot_id}")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")

      ["##{seq}", event_type, detail]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_safety_decision(decision, round_id, shot_id, :json) do
    %{
      status: "accepted",
      decision: Atom.to_string(decision),
      round_id: round_id,
      shot_id: shot_id
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_safety_decision(decision, round_id, shot_id, :human) do
    "Safety #{decision} accepted for #{round_id} #{shot_id}\n"
  end

  defp format_cancel(round_id, :json) do
    %{status: "accepted", decision: "cancel", round_id: round_id}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_cancel(round_id, :human), do: "Cancel accepted for #{round_id}\n"

  defp format_status(status, :json) do
    status
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_status(status, :human) do
    resources = value(status, :resources, %{})
    used = value(resources, :used, %{})
    limits = value(resources, :limits, %{})
    store = value(status, :store, %{})

    """
    Breech: running
    Version: #{value(status, :version)}
    Daemon ID: #{value(status, :daemon_id)}
    Profile: #{value(status, :profile)}
    IPC: #{value(status, :ipc)}
    Uptime: #{value(status, :uptime_ms)}ms
    Store: #{value(store, :status)}
    Incomplete rounds: #{value(store, :incomplete_rounds, 0) || 0}
    LLM calls: #{used["llm_call"] || 0}/#{limits["llm_call"] || 0}
    Tool exec: #{used["tool_exec"] || 0}/#{limits["tool_exec"] || 0}
    """
  end

  defp format_daemon_started(address, :json) do
    %{status: "running", address: Endpoint.address_to_string(address)}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_daemon_started(address, :human) do
    "Breech daemon listening on #{Endpoint.address_to_string(address)}\n"
  end

  defp format_daemon_paths(paths, :json) do
    paths
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_daemon_paths(paths, :human) do
    """
    Runtime dir: #{paths.runtime_dir}
    Endpoint: #{paths.endpoint_path}
    Lock: #{paths.lock_path}
    Transport: #{paths.transport}
    Socket: #{paths.socket_path}
    Named pipe: #{paths.pipe_path}
    """
  end

  defp format_daemon_stop(:json) do
    %{status: "stopping"}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_daemon_stop(:human), do: "Breech daemon stopping\n"

  defp format_error(error, :json) do
    %{error: Twelvgaige.Error.to_map(error)}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_error(error, :human), do: "error: #{error.message}\n"

  defp format_command_error(%Twelvgaige.Error{} = error, format), do: format_error(error, format)

  defp format_command_error(:daemon_unavailable, :json) do
    %{error: %{reason: "daemon_unavailable", message: "daemon unavailable"}}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_command_error(:daemon_unavailable, :human), do: "daemon unavailable\n"

  defp format_command_error(:not_found, :json) do
    %{error: %{reason: "round_not_found", message: "round not found"}}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_command_error(:not_found, :human), do: "error: round not found\n"

  defp format_command_error(error, :json) do
    %{error: %{reason: "unknown", message: inspect(error)}}
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_command_error(error, :human), do: "error: #{inspect(error)}\n"

  defp parse_non_negative_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> :error
    end
  end

  defp parse_positive_integer(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> :error
    end
  end

  defp value(map, key, default \\ nil)

  defp value(%{} = map, key, default) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_map, _key, default), do: default
end
