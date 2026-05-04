defmodule Twelvgaige.Crypto.BackupPolicyTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Crypto.BackupPolicy

  test "defaults to encrypted backup mode" do
    assert {:ok,
            %{
              mode: :encrypted,
              plaintext?: false,
              requires_restore_verification?: true,
              warnings: []
            }} = BackupPolicy.plan()
  end

  test "redacted export is allowed but marked non-restorable" do
    assert {:ok, %{mode: :redacted, plaintext?: false, warnings: warnings}} =
             BackupPolicy.plan(mode: :redacted)

    assert Enum.any?(warnings, &String.contains?(&1, "not a restorable encrypted backup"))
  end

  test "plaintext export requires explicit opt in" do
    assert {:error, :plaintext_export_not_allowed} = BackupPolicy.plan(mode: :plaintext)

    assert {:ok, %{mode: :plaintext, plaintext?: true, warnings: warnings}} =
             BackupPolicy.plan(mode: :plaintext, allow_plaintext_export?: true)

    assert Enum.any?(warnings, &String.contains?(&1, "plaintext export contains sensitive"))
  end
end
