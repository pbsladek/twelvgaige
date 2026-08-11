defmodule Twelvgaige.CLI.CommandSpecTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.CommandSpec
  alias Twelvgaige.CLI.Dispatcher
  alias Twelvgaige.CLI.Usage

  test "the public command tree has unique exact paths and complete metadata" do
    specs = CommandSpec.public()
    paths = Enum.map(specs, & &1.path)

    assert paths == Enum.uniq(paths)
    refute [] in paths

    assert Enum.all?(specs, fn spec ->
             spec.authority in [
               :read_only,
               :conditional_write,
               :managed_write,
               :runtime_control
             ] and spec.daemon in [:none, :required, :starts_daemon] and spec.usages != [] and
               is_list(spec.options) and is_list(spec.constraints) and
               is_list(spec.output.formats)
           end)
  end

  test "every public option has a type, explicit default, and symmetric conflicts" do
    Enum.each(CommandSpec.public(), fn spec ->
      names = Enum.map(spec.options, & &1.name)
      assert names == Enum.uniq(names), Enum.join(spec.path, " ")

      Enum.each(spec.options, fn option ->
        assert String.starts_with?(option.name, "--")
        refute is_nil(option.type)
        refute is_nil(option.default)

        Enum.each(option.conflicts, fn conflict ->
          assert {:ok, other} = CommandSpec.option(spec, conflict)
          assert option.name in other.conflicts
        end)
      end)
    end)
  end

  test "session options publish material types and defaults" do
    assert {:ok, spec} = CommandSpec.resolve(~w(session start task.md))

    assert {:ok, source} = CommandSpec.option(spec, "--source")
    assert source.type == {:enum, ~w(committed staged working-tree)}
    assert source.default == "committed"

    assert {:ok, runtime} = CommandSpec.option(spec, "--runtime")
    assert runtime.type == {:enum, ["codex"]}
    assert runtime.default == "codex"

    assert {:ok, task_file} = CommandSpec.option(spec, "--task-file")
    assert task_file.type == :path

    assert {:ok, saved_plan} = CommandSpec.option(spec, "--plan")
    assert saved_plan.type == :path
    assert "--sandbox" in saved_plan.conflicts
    assert "--request-id" in saved_plan.conflicts

    assert {:ok, include_untracked} = CommandSpec.option(spec, "--include-untracked")
    assert include_untracked.type == :boolean
    refute include_untracked.default

    for path <- [~w(session plan task.md), ~w(task validate task.yaml)] do
      assert {:ok, inherited} = CommandSpec.resolve(path)
      assert {:ok, inherited_source} = CommandSpec.option(inherited, "--source")
      assert inherited_source.type == source.type
      assert inherited_source.default == source.default
      assert :ok = CommandSpec.validate_shape(inherited, path ++ ~w(--source staged))
    end

    assert {:ok, plan_spec} = CommandSpec.resolve(~w(session plan task.md))
    assert {:ok, plan_output} = CommandSpec.option(plan_spec, "--output")
    assert plan_output.type == :path
    assert {:ok, _request_id} = CommandSpec.option(plan_spec, "--request-id")
    assert plan_spec.authority == :conditional_write
  end

  test "full validation enforces option values, required options, and conflicts" do
    assert {:ok, start} = CommandSpec.resolve(~w(session start task.md))

    assert {:error,
            {:invalid_option_value, "--source", "floating", ~w(committed staged working-tree)}} =
             CommandSpec.validate(start, ~w(session start task.md --source floating))

    assert {:error, {:option_conflict, "--network", "--unrestricted-network"}} =
             CommandSpec.validate(
               start,
               ~w(session start task.md --network none --unrestricted-network)
             )

    assert {:error, {:option_conflict, "--plan", "--sandbox"}} =
             CommandSpec.validate(
               start,
               ~w(session start --plan reviewed.json --sandbox podman)
             )

    assert {:ok, migrate} = CommandSpec.resolve(~w(store migrate-sqlcipher))

    assert {:error, {:required_option_missing, "--destination"}} =
             CommandSpec.validate(
               migrate,
               ~w(store migrate-sqlcipher --source plain.db --key-env TEST_KEY)
             )

    assert {:ok, impact} = CommandSpec.resolve(~w(shell impact workflows))

    assert {:error, {:exactly_one_option_required, ~w(--agent --template --tool)}} =
             CommandSpec.validate(impact, ~w(shell impact workflows))

    assert :ok = CommandSpec.validate(impact, ~w(shell impact workflows --agent writer))
  end

  test "typed defaults can be materialized without changing explicit authority" do
    assert {:ok, start} = CommandSpec.resolve(~w(session start task.md))

    normalized = CommandSpec.apply_defaults(start, ~w(session start task.md))

    for {option, value} <- [
          {"--runtime", "codex"},
          {"--repo", "."},
          {"--base-ref", "HEAD"},
          {"--source", "committed"},
          {"--sandbox", "podman"},
          {"--network", "broker-only"},
          {"--timeout", "45m"},
          {"--format", "human"}
        ] do
      assert option_value(normalized, option) == value
    end

    refute "--include-untracked" in normalized
    refute "--request-id" in normalized

    saved = CommandSpec.apply_defaults(start, ~w(session start --plan reviewed.json))
    assert option_value(saved, "--plan") == "reviewed.json"
    refute "--runtime" in saved
    refute "--repo" in saved
    refute "--network" in saved
    assert option_value(saved, "--format") == "human"
  end

  test "every concrete public default can be materialized without duplication" do
    Enum.each(CommandSpec.public(), fn spec ->
      args = CommandSpec.apply_defaults(spec, spec.path)

      Enum.each(spec.options, fn option ->
        case option.default do
          default when default in [:unset, :generated, false, nil] ->
            refute option.name in args

          true ->
            assert Enum.count(args, &(&1 == option.name)) == 1

          default ->
            assert option_value(args, option.name) == to_string(default)
        end
      end)
    end)
  end

  test "dispatch enforces every command's declared semantic option type" do
    invalid_values = %{
      integer: "not-an-integer",
      duration: "tomorrow",
      timestamp: "not-a-timestamp",
      environment_name: "not-an-env-name!",
      json: "{",
      digest: "sha256:not-a-digest"
    }

    Enum.each(CommandSpec.public(), fn spec ->
      Enum.each(spec.options, fn option ->
        invalid =
          case option.type do
            {:enum, values} -> {"__twelvgaige_invalid_enum__", values}
            type when is_map_key(invalid_values, type) -> {invalid_values[type], type}
            _unconstrained -> nil
          end

        if invalid do
          {value, expected} = invalid
          args = spec.path ++ [option.name, value]

          assert {:error, {:invalid_option_value, name, ^value, ^expected}} =
                   CommandSpec.validate(spec, args),
                 Enum.join(args, " ")

          assert name == option.name
          assert {:ok, output, 4} = Dispatcher.run(args), Enum.join(args, " ")

          assert output =~ "invalid_option_value" or output =~ "must be" or
                   output =~ "unsupported resource profile",
                 Enum.join(args, " ")
        end
      end)
    end)
  end

  test "dispatcher shape validation rejects unknown options without replacing compatibility errors" do
    assert {:ok, output, 4} = Dispatcher.run(~w(session plan task.md --mystery))
    assert output =~ "unknown option --mystery"

    assert {:ok, output, 4} = Dispatcher.run(~w(shell graph missing.yaml --format dot))
    assert output =~ "format must be text, json, or mermaid"
  end

  test "machine output declarations bind JSON and NDJSON to the shared schemas" do
    assert {:ok, inspect_spec} = CommandSpec.resolve(~w(repo inspect))
    assert inspect_spec.output.formats == [:human, :json]
    assert inspect_spec.output.result_schema == Twelvgaige.CLI.ResultEnvelope.result_schema()
    assert inspect_spec.output.schema_version == Twelvgaige.CLI.ResultEnvelope.schema_version()

    assert {:ok, watch_spec} = CommandSpec.resolve(~w(round watch round_one))
    assert watch_spec.output.formats == [:human, :ndjson]
    assert watch_spec.output.event_schema == Twelvgaige.CLI.ResultEnvelope.event_schema()
    assert watch_spec.output.schema_version == Twelvgaige.CLI.ResultEnvelope.schema_version()

    assert {:ok, completion_spec} = CommandSpec.resolve(~w(completion bash))
    assert completion_spec.output.formats == [:text]
    assert is_nil(completion_spec.output.schema_version)
  end

  test "every public help invocation resolves through the typed model" do
    Usage.command_usages()
    |> Enum.reject(
      &(&1 in ["twelvgaige - deterministic agent orchestration", "twelvgaige --help"])
    )
    |> Enum.each(fn usage ->
      args = usage |> CommandSpec.path_from_usage()
      assert {:ok, spec} = CommandSpec.resolve(args), usage
      assert spec.path == args
    end)
  end

  test "dispatch rejects implicit command abbreviations" do
    assert {:error, :unknown_command} = CommandSpec.resolve(["sess", "start"])
    assert {:error, :unknown_command} = CommandSpec.resolve(["session", "sta"])

    assert {:ok, output, 4} = Dispatcher.run(["session", "sta"])
    assert output =~ "unknown command: session"
  end

  test "completion children come from the public command tree" do
    assert "session" in CommandSpec.children()
    assert "workspace" in CommandSpec.children()

    assert CommandSpec.children(["session"]) ==
             ~w(apply attach cancel export list plan retry review revoke show start takeover watch)

    assert CommandSpec.children(["workspace", "set"]) == ~w(list show)
  end

  test "local planning commands cannot acquire a hidden daemon dependency" do
    for path <- [~w(completion), ~w(repo inspect), ~w(session plan), ~w(task validate)] do
      assert {:ok, spec} = CommandSpec.resolve(path)
      assert spec.daemon == :none
    end

    assert {:ok, stateful} = CommandSpec.resolve(~w(session start))
    assert stateful.daemon == :required
    assert stateful.authority == :managed_write
  end

  test "compatibility aliases state whether and when they are removed" do
    aliases = CommandSpec.option_aliases()

    assert %{deprecated?: false, remove_in: nil} =
             Enum.find(aliases, &(&1.alias == "--no-color"))

    assert %{deprecated?: true, remove_in: "1.0.0"} =
             Enum.find(aliases, &(&1.alias == "--task-file"))

    assert [%{canonical: "positional task file"}] =
             CommandSpec.deprecations(["session", "plan", "--task-file", "task.md"])
  end

  test "global options use the same typed metadata" do
    assert {:ok, color} = CommandSpec.global_option("--color")
    assert color.type == {:enum, ~w(auto always never)}
    assert color.default == "auto"

    assert {:ok, quiet} = CommandSpec.global_option("--quiet")
    assert quiet.type == :boolean
    assert quiet.default == false
    assert quiet.conflicts == ["--verbose"]

    assert {:ok, verbose} = CommandSpec.global_option("--verbose")
    assert verbose.conflicts == ["--quiet"]
  end

  test "operation lookup is a typed stateful command with machine-safe unavailable output" do
    endpoint =
      Path.join(
        System.tmp_dir!(),
        "missing-twelvgaige-endpoint-#{System.unique_integer([:positive])}.json"
      )

    assert {:ok, spec} = CommandSpec.resolve(~w(operation show req_one))
    assert spec.path == ~w(operation show)
    assert spec.authority == :read_only
    assert spec.daemon == :required

    assert {:ok, output, 5} =
             Dispatcher.run([
               "operation",
               "show",
               "req_one",
               "--endpoint",
               endpoint,
               "--format",
               "json"
             ])

    envelope = Jason.decode!(output)
    assert envelope["error"]["reason"] == "daemon_unavailable"
    assert envelope["error"]["remediation"] == ["twelvgaige daemon serve"]
  end

  test "each stateful command family fails closed when its selected daemon is absent" do
    endpoint =
      Path.join(
        System.tmp_dir!(),
        "missing-twelvgaige-control-plane-#{System.unique_integer([:positive])}.json"
      )

    invocations = [
      ["workspace", "list", "--endpoint", endpoint],
      ["session", "list", "--endpoint", endpoint],
      ["session", "show", "sess_missing", "--endpoint", endpoint],
      ["sandbox", "health", "--endpoint", endpoint],
      ["operation", "show", "req_missing", "--endpoint", endpoint],
      ["operations", "dashboard", "--endpoint", endpoint]
    ]

    refute File.exists?(endpoint)

    Enum.each(invocations, fn args ->
      assert {:ok, output, 5} = Dispatcher.run(args), Enum.join(args, " ")
      assert output =~ "daemon unavailable"
      assert output =~ "Next: twelvgaige daemon serve"
      refute File.exists?(endpoint)

      assert {:ok, json, 5} = Dispatcher.run(args ++ ["--format", "json"])
      envelope = Jason.decode!(json)
      assert envelope["disposition"] == "failed"
      assert envelope["error"]["reason"] == "daemon_unavailable"
      assert envelope["error"]["remediation"] == ["twelvgaige daemon serve"]
      refute File.exists?(endpoint)
    end)
  end

  test "local discovery commands remain daemon independent" do
    runtime_dir =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-local-command-#{System.unique_integer([:positive])}"
      )

    endpoint = Twelvgaige.Breech.IPC.Endpoint.default_path(runtime_dir: runtime_dir)
    refute File.exists?(endpoint)

    assert {:ok, completion, 0} = Dispatcher.run(~w(completion bash))
    assert completion =~ "complete -o default -F _twelvgaige_complete"

    assert {:ok, paths, 0} =
             Dispatcher.run(["daemon", "paths", "--runtime-dir", runtime_dir])

    assert paths =~ runtime_dir
    refute File.exists?(endpoint)

    for path <- [~w(completion), ~w(repo inspect), ~w(session plan), ~w(task validate)] do
      assert {:ok, spec} = CommandSpec.resolve(path)
      assert spec.daemon == :none
    end
  end

  defp option_value(args, name) do
    case Enum.find_index(args, &(&1 == name)) do
      nil -> nil
      index -> Enum.at(args, index + 1)
    end
  end
end
