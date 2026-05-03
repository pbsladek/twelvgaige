defmodule Twelvgaige.CLI.MainTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.CLI.Main

  test "prints help" do
    assert {:ok, output, 0} = Main.run(["--help"])
    assert output =~ "twelvgaige"
    assert output =~ "round run"
  end

  test "prints version" do
    assert Main.run(["version"]) == {:ok, "0.1.0\n", 0}
  end

  test "prints local daemon status" do
    assert {:ok, output, 0} = Main.run(["status"])

    assert output =~ "Breech: running"
    assert output =~ "Version: 0.1.0"
    assert output =~ "Profile: laptop"
  end

  test "prints local daemon status as JSON" do
    assert {:ok, output, 0} = Main.run(["status", "--format", "json"])

    decoded = Jason.decode!(output)
    assert decoded["status"] == "running"
    assert decoded["version"] == "0.1.0"
    assert decoded["profile"] == "laptop"
    assert decoded["resources"]["status"] in ["ok", "unavailable"]
  end

  test "unknown command returns invalid input exit code" do
    assert {:ok, output, 4} = Main.run(["nope"])
    assert output =~ "unknown command: nope"
  end
end
