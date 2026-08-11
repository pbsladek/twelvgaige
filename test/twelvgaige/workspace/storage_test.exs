defmodule Twelvgaige.Workspace.StorageTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.Storage

  test "parses the POSIX df available-block field without depending on mount path spacing" do
    output = """
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/disk3 1000000 250000 750000 25% /Volumes/Application Support
    """

    expected = 750_000 * 1_024
    assert {:ok, ^expected} = Storage.parse_df(output)
  end

  test "reports available bytes for the managed filesystem" do
    assert {:ok, bytes} = Storage.available_bytes(System.tmp_dir!())
    assert bytes > 0
  end
end
