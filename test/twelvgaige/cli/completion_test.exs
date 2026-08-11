defmodule Twelvgaige.CLI.CompletionTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.CommandSpec
  alias Twelvgaige.CLI.Dispatcher
  alias Twelvgaige.Operations.Store

  test "generates offline completion for supported shells" do
    assert {:ok, bash, 0} = Dispatcher.run(["completion", "bash"])
    assert bash =~ "complete -o default -F _twelvgaige_complete twelvgaige"
    assert bash =~ "completion candidates command"
    assert bash =~ ~s|query+=(--word "${COMP_WORDS[i]}")|

    assert {:ok, zsh, 0} = Dispatcher.run(["completion", "zsh"])
    assert zsh =~ "#compdef twelvgaige"
    assert zsh =~ "local -a query candidates"
    assert zsh =~ "completion candidates command"

    assert {:ok, fish, 0} = Dispatcher.run(["completion", "fish"])
    assert fish =~ "complete -c twelvgaige"
    assert fish =~ "function __twelvgaige_complete"
    assert fish =~ "completion candidates command"
  end

  test "command completion derives every path, option, and enum from the typed model" do
    specs = CommandSpec.public()

    parent_paths =
      specs
      |> Enum.flat_map(fn spec ->
        for depth <- 0..(length(spec.path) - 1), do: Enum.take(spec.path, depth)
      end)
      |> Enum.uniq()

    Enum.each(parent_paths, fn parent ->
      assert command_candidates(parent, "") == CommandSpec.children(parent)
    end)

    global_names = Enum.map(CommandSpec.global_options(), & &1.name)

    Enum.each(specs, fn spec ->
      candidates = command_candidates(spec.path, "--")

      assert Enum.sort(candidates) ==
               Enum.sort(Enum.map(spec.options, & &1.name) ++ global_names),
             Enum.join(spec.path, " ")

      Enum.each(spec.options, fn
        %{type: {:enum, values}, name: name} ->
          assert command_candidates(spec.path ++ [name], "") == Enum.sort(values),
                 Enum.join(spec.path ++ [name], " ")

        _option ->
          :ok
      end)
    end)
  end

  test "command completion respects prefixes, global placement, and option conflicts" do
    assert command_candidates(["session"], "st") == ["start"]
    assert command_candidates(["workspace", "set"], "") == ["list", "show"]

    assert command_candidates(["session", "start", "--source"], "w") == [
             "working-tree"
           ]

    assert command_candidates(["round", "run", "--profile"], "l") == ["laptop"]

    candidates = command_candidates(["--verbose", "session", "start"], "--so")
    assert candidates == ["--source"]

    candidates =
      command_candidates(["session", "start", "--network", "none"], "--")

    refute "--network" in candidates
    refute "--unrestricted-network" in candidates
  end

  test "generated completion passes each available shell parser" do
    Enum.each(["bash", "zsh", "fish"], fn shell ->
      case System.find_executable(shell) do
        nil ->
          :ok

        executable ->
          assert {:ok, script, 0} = Dispatcher.run(["completion", shell])
          path = temp_path("completion.#{shell}")
          File.write!(path, script)

          assert {_output, 0} =
                   System.cmd(executable, ["-n", path], stderr_to_stdout: true)
      end
    end)
  end

  test "candidate lookup reads profiles and record keys without a daemon" do
    root =
      Path.join(System.tmp_dir!(), "completion-candidates-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(root, ".twelvgaige"))
    on_exit(fn -> File.rm_rf(root) end)

    File.write!(Path.join([root, ".twelvgaige", "config.yaml"]), """
    version: 1
    default_profile: local
    profiles:
      local:
        runtime: codex
    """)

    assert {:ok, profiles, 0} =
             Dispatcher.run(["completion", "candidates", "profile", "--root", root])

    assert profiles == "local\n"

    database = Path.join([root, "databases", "operations.sqlite3"])
    store = start_supervised!({Store, name: nil, path: database})
    :ok = Store.put(:session, "sess_one", %{}, server: store)
    :ok = Store.put(:workspace_record, "ws_one", %{}, server: store)

    assert {:ok, "sess_one\n", 0} =
             Dispatcher.run([
               "completion",
               "candidates",
               "session",
               "--data-root",
               root,
               "--color",
               "never"
             ])

    assert {:ok, "ws_one\n", 0} =
             Dispatcher.run([
               "completion",
               "candidates",
               "workspace",
               "--data-root",
               root
             ])
  end

  test "rejects missing or unsupported shell names" do
    assert {:ok, missing, 4} = Dispatcher.run(["completion"])
    assert missing =~ "completion_shell_required"

    assert {:ok, unsupported, 4} = Dispatcher.run(["completion", "powershell"])
    assert unsupported =~ "completion_shell_unsupported"
  end

  defp temp_path(name) do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-#{name}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm(path) end)
    path
  end

  defp command_candidates(words, current) do
    args =
      ["completion", "candidates", "command", "--current", current] ++
        Enum.flat_map(words, &["--word", &1])

    assert {:ok, output, 0} = Dispatcher.run(args)
    String.split(output, "\n", trim: true)
  end
end
