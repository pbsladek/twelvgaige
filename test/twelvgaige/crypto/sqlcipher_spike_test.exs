defmodule Twelvgaige.Crypto.SQLCipherSpikeTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Crypto.SQLCipherSpike

  test "reports bundled sqlite as unavailable without creating a target store" do
    dir =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_sqlcipher_spike_#{System.unique_integer([:positive])}"
      )

    path = Path.join(dir, "encrypted.db")

    on_exit(fn -> File.rm_rf(dir) end)

    assert {:ok, report} = SQLCipherSpike.run(path: path, key: "test-key")

    assert %{
             "status" => "unavailable",
             "available" => false,
             "cipher_version" => nil,
             "migrations" => "skipped",
             "reopen_with_key" => false,
             "open_without_key_rejected" => false,
             "warnings" => warnings
           } = report

    assert Enum.any?(warnings, &String.contains?(&1, "not built against SQLCipher"))
    refute File.exists?(path)
  end
end
