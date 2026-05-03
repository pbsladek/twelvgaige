defmodule Twelvgaige.IDTest do
  use ExUnit.Case, async: true

  test "generates prefixed ids" do
    assert "round_" <> suffix = Twelvgaige.ID.new(:round)
    assert byte_size(suffix) > 0
  end

  test "transition helper uses transition prefix" do
    assert "tr_" <> _ = Twelvgaige.ID.transition_id()
  end

  test "daemon ids have a stable prefix" do
    assert "daemon_" <> _ = Twelvgaige.ID.new(:daemon)
  end
end
