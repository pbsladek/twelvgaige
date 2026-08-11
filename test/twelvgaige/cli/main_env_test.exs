defmodule Twelvgaige.CLI.MainEnvTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.CLI.Main

  test "status maps IPC errors to deterministic exit codes" do
    previous_addr = System.get_env("TWELVGAIGE_BREECH_ADDR")

    on_exit(fn ->
      restore_env("TWELVGAIGE_BREECH_ADDR", previous_addr)
    end)

    System.put_env("TWELVGAIGE_BREECH_ADDR", "not-an-address")

    assert {:ok, output, 4} = Main.run(["status", "--format", "json"])

    assert %{
             "schema" => "twelvgaige.cli.result",
             "schema_version" => 1,
             "error" => %{"message" => ":invalid_ipc_address"}
           } = Jason.decode!(output)
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
