defmodule Twelvgaige.LLM.ProviderContractTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.TestSupport.ProviderContract

  for case_spec <- ProviderContract.cases() do
    provider_id = case_spec.provider_id

    describe "#{provider_id} provider contract" do
      @case_spec case_spec

      test "reports stable capabilities" do
        ProviderContract.assert_capabilities_contract(@case_spec)
      end

      test "normalizes successful responses without leaking secrets" do
        ProviderContract.assert_success_contract(@case_spec)
      end

      test "classifies retryable provider errors and redacts details" do
        ProviderContract.assert_error_contract(@case_spec)
      end
    end
  end
end
