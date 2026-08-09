defmodule Twelvgaige.Audit.ChainTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Audit.Chain

  test "chains batches and detects tampering" do
    first = Chain.append([], [%{event_type: :round_started, round_id: "round_1"}])
    events = first ++ Chain.append(first, [%{event_type: :round_completed, round_id: "round_1"}])

    assert :ok = Chain.verify(events)
    assert hd(events).audit_previous_hash == String.duplicate("0", 64)
    assert List.last(events).audit_previous_hash == hd(events).audit_chain_hash

    tampered = put_in(events, [Access.at(1), :round_id], "round_other")
    assert {:error, :chain_hash_mismatch} = Chain.verify(tampered)
  end

  test "verifies a retained suffix from an anchored prior hash" do
    [first] = Chain.append([], [%{event_type: :one}])
    retained = Chain.extend(first.audit_chain_hash, [%{event_type: :two}])

    assert :ok = Chain.verify_from(first.audit_chain_hash, retained)
    assert {:error, :previous_hash_mismatch} = Chain.verify(retained)
  end
end
