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

  test "caller-bound lease identity makes reservation retry idempotent" do
    admission =
      start_supervised!(
        {Admission,
         name: nil,
         limits: %{
           sandboxes: 2,
           cpu: 4,
           memory_bytes: 2048,
           pids: 200,
           workspace_bytes: 2000,
           artifact_bytes: 2000,
           provider_tokens: 200
         }}
      )

    request = %{sandboxes: 1, cpu: 1, workspace_bytes: 100}
    lease_id = "reservation_0123456789abcdef"

    assert {:ok, ^lease_id} =
             Admission.reserve(request, server: admission, lease_id: lease_id)

    assert {:ok, ^lease_id} =
             Admission.reserve(request, server: admission, lease_id: lease_id)

    assert %{used: %{sandboxes: 1, cpu: 1, workspace_bytes: 100}} =
             Admission.snapshot(server: admission)

    assert {:error, :sandbox_admission_lease_conflict} =
             Admission.reserve(%{sandboxes: 2}, server: admission, lease_id: lease_id)

    assert :ok = Admission.release(lease_id, server: admission)
    assert :already_released = Admission.release(lease_id, server: admission)
  end
end
