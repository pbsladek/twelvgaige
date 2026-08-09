defmodule Twelvgaige.Qualification.CoverageGate do
  @moduledoc false

  @critical_modules [
    Twelvgaige.DelegatedSession.Codex.Approval,
    Twelvgaige.DelegatedSession.Codex.AuthProfile,
    Twelvgaige.DelegatedSession.Codex.EventCodec,
    Twelvgaige.DelegatedSession.Codex.Schema,
    Twelvgaige.Integration.Codex,
    Twelvgaige.Manager.Executor.Codex
  ]

  @boundary_modules [
    Twelvgaige.DelegatedSession.Adapter.CodexAppServer,
    Twelvgaige.DelegatedSession.Codex.AppServerClient
  ]

  def run(files) do
    threshold = threshold!("TWELVGAIGE_COVERAGE_THRESHOLD", 75.0)
    critical_threshold = threshold!("TWELVGAIGE_CRITICAL_COVERAGE_THRESHOLD", 85.0)
    boundary_threshold = threshold!("TWELVGAIGE_BOUNDARY_COVERAGE_THRESHOLD", 55.0)
    load_cover!()
    {:ok, _pid} = :cover.start()
    Enum.each(files, &import!/1)

    modules = :cover.imported_modules()

    results =
      case :cover.analyse(modules, :coverage, :module) do
        {:result, covered, []} -> Map.new(covered)
        {:result, _covered, failures} -> raise "coverage analysis failed: #{inspect(failures)}"
      end

    measured_results =
      Map.filter(results, fn {module, _coverage} ->
        application_module?(module) and not ignored_module?(module)
      end)

    total_percent = aggregate_percent!(measured_results)

    line_results = line_coverage!(@critical_modules ++ @boundary_modules)

    critical = module_results(@critical_modules, line_results)
    boundary = module_results(@boundary_modules, line_results)

    critical_failures =
      Enum.flat_map(critical, fn result ->
        if result.percent < critical_threshold, do: [result], else: []
      end)

    boundary_failures =
      Enum.flat_map(boundary, fn result ->
        if result.percent < boundary_threshold, do: [result], else: []
      end)

    failures = critical_failures ++ boundary_failures

    evidence = %{
      schema_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      result: if(total_percent >= threshold and failures == [], do: "pass", else: "fail"),
      aggregate: %{percent: total_percent, threshold: threshold},
      critical_threshold: critical_threshold,
      critical_modules: critical,
      boundary_threshold: boundary_threshold,
      boundary_modules: boundary,
      inputs: Enum.map(files, &Path.relative_to_cwd/1)
    }

    destination = Path.join(File.cwd!(), "artifacts/coverage-gate.json")
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, Jason.encode_to_iodata!(evidence, pretty: true))

    cond do
      total_percent < threshold ->
        raise "aggregate coverage #{total_percent}% is below #{threshold}%"

      critical_failures != [] ->
        names = Enum.map_join(critical_failures, ", ", &"#{&1.module}=#{&1.percent}%")
        raise "critical module coverage is below #{critical_threshold}%: #{names}"

      boundary_failures != [] ->
        names = Enum.map_join(boundary_failures, ", ", &"#{&1.module}=#{&1.percent}%")
        raise "boundary module coverage is below #{boundary_threshold}%: #{names}"

      true ->
        IO.puts(
          "Coverage qualification passed: aggregate=#{total_percent}% critical>=#{critical_threshold}% boundary>=#{boundary_threshold}%"
        )
    end
  after
    if Code.ensure_loaded?(:cover), do: :cover.stop()
  end

  defp load_cover! do
    root = :code.root_dir() |> List.to_string()

    case Path.wildcard(Path.join([root, "lib", "tools-*", "ebin"])) do
      [tools | _] ->
        _ = Code.append_path(String.to_charlist(tools))
        {:ok, _applications} = Application.ensure_all_started(:tools)

      [] ->
        raise "OTP tools application is unavailable"
    end
  end

  defp import!(path) do
    case :cover.import(String.to_charlist(path)) do
      :ok -> :ok
      {:error, reason} -> raise "could not import #{path}: #{inspect(reason)}"
    end
  end

  defp percent(covered, missed) when covered + missed > 0,
    do: Float.round(covered * 100.0 / (covered + missed), 2)

  defp percent(_covered, _missed), do: 100.0

  defp module_results(modules, line_results) do
    Enum.map(modules, fn module ->
      case Map.fetch(line_results, module) do
        {:ok, {module_covered, module_missed}} ->
          %{module: inspect(module), percent: percent(module_covered, module_missed)}

        :error ->
          %{module: inspect(module), percent: 0.0, missing: true}
      end
    end)
  end

  defp line_coverage!(modules) do
    case :cover.analyse(modules, :coverage, :line) do
      {:result, rows, []} ->
        initial = Map.new(modules, &{&1, {0, 0}})

        Enum.reduce(rows, initial, fn
          {{_module, 0}, _counts}, results ->
            results

          {{module, _line}, {line_covered, line_missed}}, results ->
            Map.update!(results, module, fn {covered, missed} ->
              {covered + line_covered, missed + line_missed}
            end)
        end)

      {:result, _rows, failures} ->
        raise "line coverage analysis failed: #{inspect(failures)}"
    end
  end

  defp aggregate_percent!(results) do
    case System.get_env("TWELVGAIGE_AGGREGATE_COVERAGE") do
      nil ->
        {covered, missed} =
          Enum.reduce(results, {0, 0}, fn
            {_module, {module_covered, module_missed}}, {covered, missed} ->
              {covered + module_covered, missed + module_missed}
          end)

        percent(covered, missed)

      reported ->
        case Float.parse(reported) do
          {value, ""} when value >= 0.0 and value <= 100.0 -> Float.round(value, 2)
          _other -> raise "TWELVGAIGE_AGGREGATE_COVERAGE must be a percentage"
        end
    end
  end

  defp application_module?(module) do
    with {:module, ^module} <- Code.ensure_loaded(module),
         source when is_list(source) <- module.module_info(:compile)[:source] do
      source = source |> List.to_string() |> Path.expand()
      String.starts_with?(source, Path.join(File.cwd!(), "lib") <> "/")
    else
      _other -> false
    end
  end

  # Keep this in lockstep with mix.exs. These modules are generated or
  # declarative wrappers; application behavior remains in the measured set.
  defp ignored_module?(module) do
    name = inspect(module)

    String.starts_with?(name, "Twelvgaige.TestSupport.") or
      String.starts_with?(name, "Twelvgaige.Store.SQLite.Schema.") or
      module in [
        Twelvgaige.Store.SQLite.Repo,
        Twelvgaige.Store.SQLite.Migration.Repo,
        Twelvgaige.Crypto.SQLCipherSpike.Repo
      ]
  end

  defp threshold!(name, default) do
    case Float.parse(System.get_env(name, Float.to_string(default))) do
      {value, ""} when value >= 0.0 and value <= 100.0 -> value
      _ -> raise "#{name} must be a percentage between 0 and 100"
    end
  end
end

Twelvgaige.Qualification.CoverageGate.run(System.argv())
