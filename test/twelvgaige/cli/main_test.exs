defmodule Twelvgaige.CLI.MainTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Main
  alias Twelvgaige.CLI.ResultEnvelope

  test "prints help" do
    assert {:ok, output, 0} = Main.run(["--help"])
    assert output =~ "twelvgaige"
    assert output =~ "round run"
  end

  test "prints version" do
    assert Main.run(["version"]) == {:ok, "#{Twelvgaige.version()}\n", 0}
  end

  test "prints local daemon status" do
    assert {:ok, output, 0} = Main.run(["status"])

    assert output =~ "Breech: running"
    assert output =~ "Version: #{Twelvgaige.version()}"
    assert output =~ "Profile: laptop"
  end

  test "prints local daemon status as JSON" do
    assert {:ok, output, 0} = Main.run(["status", "--format", "json"])

    assert {:ok, decoded} = output |> Jason.decode!() |> ResultEnvelope.result()
    assert decoded["status"] == "running"
    assert decoded["version"] == Twelvgaige.version()
    assert decoded["profile"] == "laptop"
    assert decoded["resources"]["status"] in ["ok", "unavailable"]
  end

  test "unknown command returns invalid input exit code" do
    assert {:ok, output, 4} = Main.run(["nope"])
    assert output =~ "unknown command: nope"
  end

  test "global output controls work in any position without changing JSON" do
    assert {:ok, "", 0} = Main.run(["--quiet", "version"])
    assert {:ok, "", 0} = Main.run(["version", "--color", "never", "--quiet"])

    assert {:ok, json, 0} = Main.run(["--quiet", "status", "--format", "json"])
    assert {:ok, result} = json |> Jason.decode!() |> ResultEnvelope.result()
    assert result["status"] == "running"

    assert {:ok, output, 0} = Main.run(["--verbose", "status"])
    assert output =~ "Breech: running"

    assert Twelvgaige.CLI.CommandHelpers.global_options() == %{
             color: :auto,
             quiet?: false,
             verbose?: false
           }
  end

  test "global output controls reject ambiguous or invalid combinations" do
    assert {:ok, output, 4} = Main.run(["--quiet", "--verbose", "status"])
    assert output =~ "cannot be used together"

    assert {:ok, output, 4} = Main.run(["status", "--color=rainbow"])
    assert output =~ "auto, always, or never"
  end
end
