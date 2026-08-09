defmodule Twelvgaige.Sandbox.AdmissionTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Sandbox.Admission

  test "atomically prevents concurrent sandbox resource oversubscription" do
    admission =
      start_supervised!(
        {Admission,
         name: nil,
         limits: %{
           sandboxes: 1,
           cpu: 2,
           memory_bytes: 1024,
           pids: 100,
           workspace_bytes: 1000,
           artifact_bytes: 1000,
           provider_tokens: 100
         }}
      )

    request = %{
      sandboxes: 1,
      cpu: 2,
      memory_bytes: 1024,
      pids: 100,
      workspace_bytes: 500,
      artifact_bytes: 500,
      provider_tokens: 50
    }

    assert {:ok, lease} = Admission.reserve(request, server: admission)

    assert {:error, {:sandbox_capacity_exceeded, resources}} =
             Admission.reserve(request, server: admission)

    assert :sandboxes in resources
    assert :ok = Admission.release(lease, server: admission)
    assert {:ok, _lease} = Admission.reserve(request, server: admission)
  end
end
