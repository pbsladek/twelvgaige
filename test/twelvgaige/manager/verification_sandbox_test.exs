defmodule Twelvgaige.Manager.VerificationSandboxTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Manager.VerificationSandbox

  test "accepts only digest-bound, credential-free, networkless sandbox evidence" do
    workspace = %{id: "ws_verify", path: System.tmp_dir!()}
    parent = self()

    executor = fn request ->
      send(parent, {:verification_request, request})

      {:ok,
       %{
         request_digest: request.request_digest,
         backend: :podman,
         network_mode: :none,
         credentials_present: false,
         provider_environment_present: false,
         workspace_copy: true,
         commands: [%{argv: ["mix", "test"], exit_status: 0}],
         started_at: ~U[2026-08-11 12:00:00Z],
         finished_at: ~U[2026-08-11 12:01:00Z]
       }}
    end

    assert {:ok, evidence} =
             VerificationSandbox.verify(workspace, [["mix", "test"]],
               verification_executor: executor
             )

    assert evidence.status == :passed
    assert evidence.backend == :podman

    assert_receive {:verification_request, request}
    assert request.network_mode == :none
    assert request.credential_lease_id == nil
    refute request.provider_environment
    assert request.workspace_copy
  end

  test "rejects provider environment names and failed command evidence" do
    workspace = %{id: "ws_verify_failure", path: System.tmp_dir!()}

    assert {:error, :verification_environment_unsafe} =
             VerificationSandbox.verify(workspace, [["mix", "test"]],
               verification_environment_names: ["OPENAI_API_KEY"],
               verification_executor: fn _request -> flunk("unsafe request must not execute") end
             )

    executor = fn request ->
      {:ok,
       %{
         request_digest: request.request_digest,
         backend: :podman,
         network_mode: :none,
         credentials_present: false,
         provider_environment_present: false,
         workspace_copy: true,
         commands: [%{exit_status: 1}]
       }}
    end

    assert {:error, {:verification_commands_failed, [%{exit_status: 1}]}} =
             VerificationSandbox.verify(workspace, [["mix", "test"]],
               verification_executor: executor
             )
  end
end
