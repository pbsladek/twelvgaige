defmodule Twelvgaige.Operations.ProtocolConformanceTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Operations.ProtocolConformance

  test "pinned Codex fixture covers stable exact resume and digest-bound approval" do
    assert :ok = ProtocolConformance.verify_codex()
  end
end
