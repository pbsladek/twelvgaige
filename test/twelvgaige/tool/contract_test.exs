defmodule Twelvgaige.Tool.ContractTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.TestSupport.ToolContract

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige_tool_contract_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)
    File.write!(Path.join(root, "sample.txt"), "tool contract file\n")

    on_exit(fn -> File.rm_rf(root) end)

    %{root: root}
  end

  test "all built-in tools expose stable metadata" do
    ToolContract.assert_metadata_contract()
  end

  test "all built-in tools reject schema-invalid input before execution" do
    ToolContract.assert_invalid_input_contract()
  end

  test "all built-in read-only tools execute with local fixtures", %{root: root} do
    ToolContract.assert_success_contract(root)
  end
end
