defmodule Twelvgaige.CLI.Commands.ShellCacheTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Commands.ShellCache

  test "validate can be exercised directly without routing through CLI.Main" do
    path =
      System.tmp_dir!()
      |> Path.join("twelvgaige-shell-cache-direct-#{System.unique_integer([:positive])}.yaml")

    File.write!(path, """
    kind: workflow
    id: direct_cache_test
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: mock_agent
        prompt: inspect
    """)

    on_exit(fn -> File.rm(path) end)

    assert {:ok, output, 0} = ShellCache.validate(path, format: :human)
    assert output == "valid workflow shell: direct_cache_test 1.0.0\n"
  end
end
