alias ExCoveralls.{Cobertura, ConfServer, Cover, Json, Lcov, Stats}

coverage_dir = Path.expand("cover", File.cwd!())
coverdata_files = Path.wildcard(Path.join(coverage_dir, "*.coverdata"))

if coverdata_files == [] do
  Mix.raise("no .coverdata files found in #{coverage_dir}")
end

Cover.compile(Mix.Project.compile_path())

Enum.each(coverdata_files, fn path ->
  case :cover.import(String.to_charlist(path)) do
    :ok -> :ok
    {:error, reason} -> Mix.raise("could not import #{path}: #{inspect(reason)}")
  end
end)

ignored = Twelvgaige.MixProject.coverage_ignore_modules()

modules =
  Cover.modules()
  |> Enum.reject(fn module ->
    module_name = inspect(module)

    Enum.any?(ignored, fn
      %Regex{} = pattern -> Regex.match?(pattern, module_name)
      ignored_module -> ignored_module == module
    end)
  end)

:ok = ConfServer.start()
stats = Stats.report(modules)

Lcov.execute(stats, output_dir: coverage_dir)
Json.execute(stats, output_dir: coverage_dir)
Cobertura.execute(stats, output_dir: coverage_dir)

IO.puts("Standard coverage reports written to cover/lcov.info, cover/excoveralls.json, and cover/cobertura.xml")
