defmodule Twelvgaige.PerfReview do
  @moduledoc false

  alias Twelvgaige.Output.Parser
  alias Twelvgaige.Pattern.Compiler
  alias Twelvgaige.Pattern.Condition
  alias Twelvgaige.Schema.ValueValidator
  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Store.Retention

  def run do
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

    IO.puts("name,iterations,best_us,median_us,worst_us")

    Enum.each(cases, fn {name, iterations, fun} ->
      result = benchmark(fun, iterations)
      IO.puts("#{name},#{iterations},#{result.best},#{result.median},#{result.worst}")
    end)
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
      best: hd(times),
      median: Enum.at(times, div(length(times), 2)),
      worst: List.last(times)
    }
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
