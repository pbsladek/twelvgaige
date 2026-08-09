defmodule Twelvgaige.PerfReview do
  @moduledoc false

  alias Twelvgaige.Output.Parser
  alias Twelvgaige.Pattern.Compiler
  alias Twelvgaige.Pattern.Condition
  alias Twelvgaige.Schema.ValueValidator
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Store.Retention

  @schema_version 1
  @default_regression_percent 50.0

  def run(args \\ System.argv()) do
    cases = [
      {"duplicate_scan_old_quadratic", 3, fn -> old_duplicate(duplicate_values()) end},
      {"duplicate_scan_mapset", 30, fn -> mapset_duplicate(duplicate_values()) end},
      {"condition_shot_references", 30, fn -> Condition.shot_references(condition()) end},
      {"pattern_compile_chain", 10, fn -> Compiler.compile(workflow()) end},
      {"value_validator_wide_object", 20,
       fn -> ValueValidator.validate(value(), schema(), error_opts()) end},
      {"retention_stats_many_rounds", 30, fn -> Retention.stats(retention_state()) end},
      {"output_parser_candidates", 100, fn -> Parser.parse(output_content(), output_schema()) end}
    ]

    result = %{
      schema_version: @schema_version,
      suite: "phase0-core",
      host: host_metadata(),
      cases:
        Enum.map(cases, fn {name, iterations, fun} ->
          Map.merge(%{name: name, iterations: iterations}, benchmark(fun, iterations))
        end)
    }

    case check_baseline(result, args) do
      :ok -> print_result(result, args)
      {:error, regressions} ->
        print_result(Map.put(result, :regressions, regressions), args)
        System.halt(1)
    end
  end

  defp benchmark(fun, iterations) do
    fun.()
    :erlang.garbage_collect()

    times =
      for _ <- 1..7 do
        {elapsed, _result} =
          :timer.tc(fn ->
            for _ <- 1..iterations do
              fun.()
            end
          end)

        div(elapsed, iterations)
      end
      |> Enum.sort()

    %{
      best_us: hd(times),
      median_us: Enum.at(times, div(length(times), 2)),
      worst_us: List.last(times),
      samples_us: times
    }
  end

  defp print_result(result, args) do
    if option(args, "--format", "csv") == "json" do
      IO.puts(Jason.encode!(result, pretty: true))
    else
      IO.puts("name,iterations,best_us,median_us,worst_us")

      Enum.each(result.cases, fn item ->
        IO.puts(
          "#{item.name},#{item.iterations},#{item.best_us},#{item.median_us},#{item.worst_us}"
        )
      end)
    end
  end

  defp check_baseline(result, args) do
    case option(args, "--check", nil) do
      nil ->
        :ok

      path ->
        with {:ok, contents} <- File.read(path),
             {:ok, baseline} <- Jason.decode(contents) do
          allowed_percent =
            args
            |> option("--max-regression-percent", Float.to_string(@default_regression_percent))
            |> parse_percent!()

          regressions = regressions(result, baseline, allowed_percent)
          if regressions == [], do: :ok, else: {:error, regressions}
        else
          {:error, reason} ->
            {:error, [%{case: "baseline", reason: inspect(reason), path: path}]}
        end
    end
  end

  defp regressions(result, baseline, allowed_percent) do
    baseline_cases = Map.new(Map.get(baseline, "cases", []), &{&1["name"], &1})

    Enum.flat_map(result.cases, fn item ->
      case Map.get(baseline_cases, item.name) do
        %{"median_us" => baseline_median} when is_number(baseline_median) ->
          allowed_median = baseline_median * (1.0 + allowed_percent / 100.0)

          if item.median_us <= allowed_median do
            []
          else
            [
              %{
                case: item.name,
                baseline_median_us: baseline_median,
                observed_median_us: item.median_us,
                allowed_regression_percent: allowed_percent
              }
            ]
          end

        _missing ->
          [%{case: item.name, reason: "missing baseline case"}]
      end
    end)
  end

  defp host_metadata do
    %{
      os: :os.type() |> inspect(),
      os_version: :os.version() |> Tuple.to_list() |> Enum.join("."),
      architecture: :erlang.system_info(:system_architecture) |> to_string(),
      erlang: :erlang.system_info(:otp_release) |> to_string(),
      elixir: System.version(),
      schedulers: System.schedulers_online(),
      model: host_value("TWELVGAIGE_BENCH_HOST_MODEL", "hw.model"),
      memory_bytes: host_value("TWELVGAIGE_BENCH_HOST_MEMORY_BYTES", "hw.memsize")
    }
  end

  defp host_value(env_name, sysctl_name) do
    case System.get_env(env_name) do
      value when is_binary(value) and value != "" -> value
      _missing -> sysctl_value(sysctl_name)
    end
  end

  defp sysctl_value(name) do
    case System.cmd("sysctl", ["-n", name], stderr_to_stdout: true) do
      {value, 0} -> String.trim(value)
      _other -> "unknown"
    end
  rescue
    _error -> "unknown"
  end

  defp option(args, name, default) do
    case Enum.find_index(args, &(&1 == name)) do
      nil -> default
      index -> Enum.at(args, index + 1, default)
    end
  end

  defp parse_percent!(value) do
    case Float.parse(value) do
      {percent, ""} when percent >= 0 -> percent
      _other -> raise ArgumentError, "invalid --max-regression-percent"
    end
  end

  defp old_duplicate(values) do
    Enum.find(values, fn value -> Enum.count(values, &(&1 == value)) > 1 end)
  end

  defp mapset_duplicate(values) do
    Enum.reduce_while(values, MapSet.new(), fn value, seen ->
      if MapSet.member?(seen, value) do
        {:halt, value}
      else
        {:cont, MapSet.put(seen, value)}
      end
    end)
  end

  defp duplicate_values, do: Enum.to_list(1..5_000) ++ [4_999]

  defp condition do
    1..250
    |> Enum.map(fn index -> "shots.s#{index}.output.value == #{index}" end)
    |> Enum.join(" or ")
  end

  defp workflow do
    shots =
      Enum.map(1..1_000, fn index ->
        %Workflow.Shot{
          id: "s#{index}",
          kind: :slug,
          agent: "agent",
          depends_on: if(index == 1, do: [], else: ["s#{index - 1}"]),
          condition: true,
          tools: []
        }
      end)

    %Workflow{id: "perf", version: "1.0.0", shots: shots}
  end

  defp schema do
    properties =
      Map.new(1..300, fn index ->
        {"field_#{index}", %{"type" => "integer"}}
      end)

    %{
      "type" => "object",
      "required" => Map.keys(properties),
      "additionalProperties" => false,
      "properties" => properties
    }
  end

  defp value do
    Map.new(1..300, fn index -> {"field_#{index}", index} end)
  end

  defp error_opts do
    [
      error_class: :output_error,
      error_reason: :output_schema_violation,
      schema_error_class: :internal_error
    ]
  end

  defp retention_state do
    rounds =
      Map.new(1..5_000, fn index ->
        status = if rem(index, 3) == 0, do: :running, else: :complete
        {"round_#{index}", %{id: "round_#{index}", status: status}}
      end)

    %{rounds: rounds, events: %{}, audit_events: %{}, attempts: %{}, tool_intents: %{}}
  end

  defp output_content do
    """
    final answer:

    ```json
    {"ok":true,"count":42}
    ```
    """
  end

  defp output_schema do
    %{
      "type" => "object",
      "required" => ["ok", "count"],
      "additionalProperties" => false,
      "properties" => %{
        "ok" => %{"type" => "boolean"},
        "count" => %{"type" => "integer"}
      }
    }
  end
end

Twelvgaige.PerfReview.run()
