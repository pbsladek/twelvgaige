defmodule Twelvgaige.Developer.CLIQualification do
  @moduledoc "Measures the public, no-mutation developer command path."

  alias Twelvgaige.CLI.CommandSpec
  alias Twelvgaige.CLI.Commands.SessionStart
  alias Twelvgaige.CLI.CompletionCandidates
  alias Twelvgaige.CLI.Dispatcher
  alias Twelvgaige.CLI.ResultEnvelope
  alias Twelvgaige.Manager.SavedPlan

  @schema_version 1
  @limits %{
    help_ms: 1_000,
    bash_completion_ms: 1_000,
    zsh_completion_ms: 1_000,
    fish_completion_ms: 1_000,
    repository_inspection_ms: 10_000,
    task_validation_ms: 2_000,
    session_plan_ms: 10_000,
    saved_plan_handoff_ms: 10_000
  }

  @spec default_limits() :: map()
  def default_limits, do: @limits

  @spec evaluate(map(), map()) :: map()
  def evaluate(measurements, limits \\ @limits) do
    checks =
      Enum.map(limits, fn {metric, limit} ->
        observed = value(measurements, metric)

        %{
          metric: metric,
          observed: observed,
          limit: limit,
          status:
            if(is_integer(observed) and observed >= 0 and observed <= limit,
              do: "pass",
              else: if(is_integer(observed), do: "fail", else: "missing")
            )
        }
      end)
      |> Enum.sort_by(& &1.metric)

    %{
      status: if(Enum.all?(checks, &(&1.status == "pass")), do: "pass", else: "fail"),
      checks: checks
    }
  end

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    destination =
      Keyword.get(
        opts,
        :evidence_path,
        Path.expand("qualification/evidence/cli/developer-workflow.json")
      )

    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-cli-qualification-#{System.unique_integer([:positive])}"
      )

    File.mkdir!(root)
    File.chmod!(root, 0o700)

    result =
      try do
        qualify(root)
      rescue
        error -> {:error, {:qualification_crashed, error.__struct__}}
      catch
        kind, _reason -> {:error, {:qualification_stopped, kind}}
      end

    evidence = evidence(result)

    try do
      with :ok <- write_evidence(destination, evidence) do
        if evidence.status == "pass",
          do: {:ok, evidence},
          else: {:error, {:developer_cli_qualification_failed, failure_code_from_result(result)}}
      end
    after
      File.rm_rf!(root)
    end
  end

  defp qualify(root) do
    repository = Path.join(root, "repository")
    task = Path.join(repository, "task.yaml")

    with :ok <- create_fixture(repository, task),
         {:ok, help_ms} <-
           command(["--help"], fn output ->
             contains_all?(output, [
               "twelvgaige session plan",
               "twelvgaige session start",
               "twelvgaige session review",
               "twelvgaige support bundle"
             ])
           end),
         {:ok, bash_ms} <- completion("bash", "_twelvgaige_complete"),
         {:ok, zsh_ms} <- completion("zsh", "#compdef twelvgaige"),
         {:ok, fish_ms} <- completion("fish", "complete -c twelvgaige"),
         {:ok, repository_ms} <-
           command(["repo", "inspect", "--repo", repository, "--format", "json"], &json?/1),
         {:ok, validation_ms} <-
           command(["task", "validate", task, "--format", "json"], &json?/1),
         {:ok, plan_ms} <-
           command(
             ["session", "plan", task, "--network", "none", "--format", "json"],
             &planned?/1
           ),
         {:ok, saved_plan_ms} <- saved_plan_contract(root, task),
         :ok <- typed_command_contract(),
         :ok <- missing_daemon_contract(root),
         :ok <- clean_repository(repository) do
      measurements = %{
        help_ms: help_ms,
        bash_completion_ms: bash_ms,
        zsh_completion_ms: zsh_ms,
        fish_completion_ms: fish_ms,
        repository_inspection_ms: repository_ms,
        task_validation_ms: validation_ms,
        session_plan_ms: plan_ms,
        saved_plan_handoff_ms: saved_plan_ms
      }

      {:ok, %{measurements: measurements, evaluation: evaluate(measurements)}}
    end
  end

  defp create_fixture(repository, task) do
    config = Path.join([repository, ".twelvgaige", "config.yaml"])

    with :ok <- File.mkdir_p(Path.dirname(config)),
         :ok <- git(repository, ["init", "--quiet"]),
         :ok <- git(repository, ["config", "user.name", "Qualification"]),
         :ok <- git(repository, ["config", "user.email", "qualification@localhost"]),
         :ok <- File.write(Path.join(repository, "README.md"), "qualification\n"),
         :ok <-
           File.write(
             config,
             "version: 1\ndefault_profile: local\nprofiles:\n  local:\n    runtime: codex\n    auth_profile: qualification-auth\n    sandbox: podman\n    network: none\n"
           ),
         :ok <-
           File.write(
             task,
             "version: 1\nobjective: Validate the no-mutation planning path.\nrepository: .\nauth_profile: qualification-auth\nsandbox: podman\nnetwork: none\n"
           ),
         :ok <- git(repository, ["add", "--all"]),
         :ok <- git(repository, ["commit", "--quiet", "-m", "qualification fixture"]) do
      :ok
    end
  end

  defp completion(shell, marker),
    do: command(["completion", shell], &String.contains?(&1, marker))

  defp command(args, validator) do
    started = System.monotonic_time(:microsecond)

    case Dispatcher.run(args) do
      {:ok, output, 0} ->
        if validator.(output) do
          elapsed = System.monotonic_time(:microsecond) - started
          {:ok, max(div(elapsed + 999, 1_000), 1)}
        else
          {:error, {:developer_cli_output_contract_failed, command_identity(args)}}
        end

      {:ok, _output, code} ->
        {:error, {:developer_cli_command_failed, %{command: command_identity(args), exit: code}}}
    end
  end

  defp json?(output) do
    with {:ok, envelope} <- Jason.decode(output),
         true <- envelope["schema"] == ResultEnvelope.result_schema(),
         true <- envelope["schema_version"] == ResultEnvelope.schema_version(),
         {:ok, _result} <- ResultEnvelope.result(envelope) do
      true
    else
      _invalid -> false
    end
  end

  defp planned?(output) do
    with {:ok, envelope} <- Jason.decode(output),
         {:ok, result} <- ResultEnvelope.result(envelope),
         true <- value(result, :status) in ["planned", "ready"],
         plan_digest when is_binary(plan_digest) <- value(result, :plan_digest),
         true <- String.starts_with?(plan_digest, "sha256:"),
         request_id when is_binary(request_id) <- value(result, :request_id),
         provenance when is_map(provenance) <- value(result, :configuration_provenance),
         true <-
           Enum.all?(
             ~w(runtime repository base_ref sandbox network source_mode),
             &is_binary(value(provenance, &1))
           ) do
      true
    else
      _invalid -> false
    end
  end

  defp saved_plan_contract(root, task) do
    output = Path.join(root, "reviewed session plan.json")
    private_task = "Validate the no-mutation planning path."
    started = System.monotonic_time(:microsecond)

    with {:ok, encoded, 0} <-
           Dispatcher.run([
             "session",
             "plan",
             task,
             "--network",
             "none",
             "--output",
             output,
             "--format",
             "json"
           ]),
         false <- String.contains?(encoded, private_task),
         {:ok, envelope} <- Jason.decode(encoded),
         {:ok, result} <- ResultEnvelope.result(envelope),
         ^output <- value(result, :saved_plan_path),
         start_command when is_binary(start_command) <- value(result, :start_command),
         true <- String.contains?(start_command, "session start --plan"),
         {:ok, stat} <- File.lstat(output),
         true <- stat.type == :regular and Bitwise.band(stat.mode, 0o777) == 0o600,
         {:ok, saved_plan} <- SavedPlan.load(output),
         true <- saved_plan["plan_digest"] == value(result, :plan_digest),
         {:ok, opts} <- SessionStart.resolve(["--plan", output]),
         request = SessionStart.request(opts),
         true <- Map.delete(request, "saved_plan") == saved_plan["request"],
         true <- request["saved_plan"]["plan_digest"] == saved_plan["plan_digest"] do
      elapsed = System.monotonic_time(:microsecond) - started
      {:ok, max(div(elapsed + 999, 1_000), 1)}
    else
      _invalid -> {:error, :developer_cli_saved_plan_contract_failed}
    end
  end

  defp typed_command_contract do
    specs = CommandSpec.public()

    valid? =
      specs != [] and
        Enum.all?(specs, fn spec ->
          spec.usages != [] and
            spec.authority in [
              :read_only,
              :conditional_write,
              :managed_write,
              :runtime_control
            ] and
            spec.daemon in [:none, :required, :starts_daemon] and
            valid_options?(spec) and valid_output?(spec)
        end) and completion_contract?(specs)

    if valid?, do: :ok, else: {:error, :developer_cli_typed_command_contract_failed}
  end

  defp valid_options?(spec) do
    names = Enum.map(spec.options, & &1.name)

    names == Enum.uniq(names) and
      Enum.all?(spec.options, fn option ->
        is_binary(option.name) and not is_nil(option.type) and not is_nil(option.default) and
          CommandSpec.validate_shape(spec, spec.path ++ option_invocation(option)) == :ok and
          semantic_option_contract?(spec, option) and
          Enum.all?(option.conflicts, fn conflict ->
            case CommandSpec.option(spec, conflict) do
              {:ok, other} -> option.name in other.conflicts
              :error -> false
            end
          end)
      end) and default_contract?(spec) and constraint_contract?(spec)
  end

  defp semantic_option_contract?(spec, option) do
    case invalid_option_value(option.type) do
      nil ->
        true

      {value, expected} ->
        args = spec.path ++ [option.name, value]

        CommandSpec.validate(spec, args) ==
          {:error, {:invalid_option_value, option.name, value, expected}} and
          match?({:ok, _output, 4}, Dispatcher.run(args))
    end
  end

  defp invalid_option_value({:enum, values}),
    do: {"__twelvgaige_invalid_enum__", values}

  defp invalid_option_value(:integer), do: {"not-an-integer", :integer}
  defp invalid_option_value(:duration), do: {"tomorrow", :duration}
  defp invalid_option_value(:timestamp), do: {"not-a-timestamp", :timestamp}
  defp invalid_option_value(:environment_name), do: {"not-an-env-name!", :environment_name}
  defp invalid_option_value(:json), do: {"{", :json}
  defp invalid_option_value(:digest), do: {"sha256:not-a-digest", :digest}
  defp invalid_option_value(_unconstrained), do: nil

  defp default_contract?(spec) do
    normalized = CommandSpec.apply_defaults(spec, spec.path)

    Enum.all?(spec.options, fn option ->
      occurrences = Enum.count(normalized, &(&1 == option.name))

      case option.default do
        default when default in [:unset, :generated, false, nil] ->
          occurrences == 0

        true ->
          occurrences == 1

        default ->
          occurrences == 1 and option_value(normalized, option.name) == to_string(default)
      end
    end)
  end

  defp constraint_contract?(spec) do
    Enum.all?(spec.constraints, fn
      %{kind: :mutually_exclusive, options: [left, right]} ->
        args = spec.path ++ option_args(spec, left) ++ option_args(spec, right)

        match?({:error, {:option_conflict, _, _}}, CommandSpec.validate(spec, args)) or
          match?({:error, {:exactly_one_option_required, _}}, CommandSpec.validate(spec, args))

      %{kind: :exactly_one, options: options} ->
        CommandSpec.validate(spec, spec.path) ==
          {:error, {:exactly_one_option_required, options}}

      %{kind: :requires, option: option, required_option: required} ->
        args = spec.path ++ option_args(spec, option)
        CommandSpec.validate(spec, args) == {:error, {:option_requires, option, required}}

      _unknown ->
        false
    end)
  end

  defp option_args(spec, name) do
    {:ok, option} = CommandSpec.option(spec, name)
    option_invocation(option)
  end

  defp completion_contract?(specs) do
    global_names = Enum.map(CommandSpec.global_options(), & &1.name)

    options_complete? =
      Enum.all?(specs, fn spec ->
        {:ok, candidates} =
          CompletionCandidates.list(:command, words: spec.path, current: "--")

        expected = Enum.map(spec.options, & &1.name) ++ global_names

        Enum.sort(candidates) == Enum.sort(expected) and
          Enum.all?(spec.options, &enum_completion_matches?(spec.path, &1))
      end)

    parent_paths =
      specs
      |> Enum.flat_map(fn spec ->
        for depth <- 0..(length(spec.path) - 1), do: Enum.take(spec.path, depth)
      end)
      |> Enum.uniq()

    children_complete? =
      Enum.all?(parent_paths, fn parent ->
        {:ok, candidates} = CompletionCandidates.list(:command, words: parent, current: "")
        candidates == CommandSpec.children(parent)
      end)

    options_complete? and children_complete?
  end

  defp enum_completion_matches?(path, %{type: {:enum, values}, name: name}) do
    {:ok, candidates} =
      CompletionCandidates.list(:command, words: path ++ [name], current: "")

    candidates == Enum.sort(values)
  end

  defp enum_completion_matches?(_path, _option), do: true

  defp option_invocation(%{type: :boolean, name: name}), do: [name]
  defp option_invocation(%{type: {:enum, [value | _rest]}, name: name}), do: [name, value]
  defp option_invocation(%{type: :integer, name: name}), do: [name, "1"]
  defp option_invocation(%{type: :duration, name: name}), do: [name, "1m"]

  defp option_invocation(%{type: :timestamp, name: name}),
    do: [name, "2026-08-11T00:00:00Z"]

  defp option_invocation(%{type: :environment_name, name: name}), do: [name, "TEST_KEY"]

  defp option_invocation(%{type: :digest, name: name}),
    do: [name, "sha256:" <> String.duplicate("0", 64)]

  defp option_invocation(%{type: :json, name: name}), do: [name, "{}"]
  defp option_invocation(%{name: name}), do: [name, "value"]

  defp option_value(args, name) do
    case Enum.find_index(args, &(&1 == name)) do
      nil -> nil
      index -> Enum.at(args, index + 1)
    end
  end

  defp valid_output?(spec) do
    cond do
      :json in spec.output.formats ->
        spec.output.result_schema == ResultEnvelope.result_schema() and
          spec.output.schema_version == ResultEnvelope.schema_version()

      :ndjson in spec.output.formats ->
        spec.output.event_schema == ResultEnvelope.event_schema() and
          spec.output.schema_version == ResultEnvelope.schema_version()

      true ->
        is_nil(spec.output.schema_version)
    end
  end

  defp missing_daemon_contract(root) do
    endpoint = Path.join(root, "missing-daemon.endpoint.json")

    invocations = [
      ["workspace", "list", "--endpoint", endpoint, "--format", "json"],
      ["session", "list", "--endpoint", endpoint, "--format", "json"],
      ["sandbox", "health", "--endpoint", endpoint, "--format", "json"],
      ["operation", "show", "req_missing", "--endpoint", endpoint, "--format", "json"],
      ["operations", "dashboard", "--endpoint", endpoint, "--format", "json"]
    ]

    Enum.reduce_while(invocations, :ok, fn args, :ok ->
      case Dispatcher.run(args) do
        {:ok, output, 5} ->
          with {:ok, envelope} <- Jason.decode(output),
               %{"reason" => "daemon_unavailable", "remediation" => remediation} <-
                 envelope["error"],
               true <- remediation == ["twelvgaige daemon serve"],
               false <- File.exists?(endpoint) do
            {:cont, :ok}
          else
            _invalid -> {:halt, {:error, :developer_cli_missing_daemon_contract_failed}}
          end

        _result ->
          {:halt, {:error, :developer_cli_missing_daemon_contract_failed}}
      end
    end)
  end

  defp contains_all?(output, values), do: Enum.all?(values, &String.contains?(output, &1))

  defp command_identity(args) do
    case CommandSpec.resolve(args) do
      {:ok, %CommandSpec{path: path}} -> Enum.join(path, " ")
      {:ok, :root} -> "root"
      {:error, :unknown_command} -> "unknown"
    end
  end

  defp clean_repository(repository) do
    case System.cmd("git", ["-C", repository, "status", "--porcelain=v2"], stderr_to_stdout: true) do
      {"", 0} -> :ok
      {_output, _status} -> {:error, :developer_cli_source_mutated}
    end
  end

  defp git(repository, args) do
    case System.cmd("git", ["-C", repository | args], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :developer_cli_fixture_git_failed}
    end
  end

  defp evidence({:ok, result}) do
    %{
      schema_version: @schema_version,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: result.evaluation.status,
      scope: "public no-mutation developer CLI",
      host: %{
        operating_system: operating_system(),
        architecture: :erlang.system_info(:system_architecture) |> to_string(),
        cli_version: Twelvgaige.version()
      },
      measurements: result.measurements,
      limits: @limits,
      evaluation: result.evaluation,
      contracts: %{
        help_common_path: "pass",
        completion_generation: "pass",
        repository_inspection_json: "pass",
        task_validation_json: "pass",
        session_plan_no_mutation: "pass",
        saved_plan_exact_handoff: "pass",
        saved_plan_owner_only: "pass",
        session_plan_task_redaction: "pass",
        configuration_provenance: "pass",
        typed_command_model: "pass",
        exhaustive_command_shape_completion_parity: "pass",
        exhaustive_command_semantic_parser_parity: "pass",
        complete_typed_default_inventory: "pass",
        missing_daemon_fail_closed: "pass",
        versioned_result_envelope: "pass"
      }
    }
  end

  defp evidence({:error, reason}) do
    %{
      schema_version: @schema_version,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      status: "fail",
      scope: "public no-mutation developer CLI",
      failure: %{code: failure_code(reason), check: failure_check(reason)}
    }
  end

  defp write_evidence(destination, evidence) do
    destination = Path.expand(destination)
    staging = destination <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <-
           File.write(staging, [Jason.encode_to_iodata!(evidence, pretty: true), "\n"], [
             :exclusive
           ]),
         :ok <- File.chmod(staging, 0o600),
         :ok <- File.rename(staging, destination) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(staging)
        {:error, {:developer_cli_evidence_write_failed, reason}}
    end
  end

  defp operating_system do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, name} -> to_string(name)
      {family, name} -> "#{family}-#{name}"
    end
  end

  defp failure_code({:ok, _result}), do: "threshold_exceeded"
  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code(_reason), do: "qualification_failed"

  defp failure_check({_reason, %{command: command}}) when is_binary(command), do: command
  defp failure_check({_reason, command}) when is_binary(command), do: command
  defp failure_check(_reason), do: "qualification"

  defp failure_code_from_result({:error, reason}), do: failure_code(reason)
  defp failure_code_from_result(result), do: failure_code(result)

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, to_string(key), default))
end
